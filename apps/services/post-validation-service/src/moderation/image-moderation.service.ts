import { runWithConcurrency } from "../utils/concurrency";
import { getCachedImageScores, setCachedImageScores } from "../config/redis";
import { recordImageAudit } from "../services/audit.service";
import {
    imageModerationDuration,
    imageModerationScore,
    imageModerationSkippedTotal,
    imageModerationTotal,
} from "../metrics/registry";
import { collectModerationTargets, type ModerationTarget } from "./media";
import { evaluateImage, type ImageEvaluation } from "./policy";
import {
    ModerationError,
    mostSevere,
    type CategoryScores,
    type ImageModerator,
    type ModerationAction,
} from "./types";
import type { ValidationIssue } from "../types/validation.types";

/**
 * Tempo máximo gasto com as imagens de UM post, somando novas tentativas.
 *
 * O tópico `posts` tem uma partição no cluster, e o worker processa uma
 * mensagem por vez: um post travado numa API fora do ar segura todos os que vêm
 * atrás. Passou do orçamento, as imagens que faltam ficam sem classificação —
 * o post segue, como no resto do serviço (disponibilidade acima de filtro).
 */
const POST_BUDGET_MS = 45_000;

/** 1 tentativa + 2 novas. Os intervalos crescem; o `Retry-After` do 429 tem precedência. */
const RETRY_DELAYS_MS = [1_000, 3_000];
const MAX_RETRY_AFTER_MS = 10_000;

export interface ImageModerationOutcome {
    /** A ação mais grave entre todas as imagens do post. */
    action: ModerationAction;
    /** Uma issue por achado, com `field: "media"` e `mediaIndex`. */
    issues: ValidationIssue[];
    classified: number;
    failed: number;
    skipped: number;
}

export interface ModeratePostInput {
    postId: string;
    authorId: string;
    data: { media?: unknown; imageUrls?: unknown };
    /**
     * `heartbeat` do kafkajs. Classificar 10 imagens com novas tentativas pode
     * passar dos 30s do `sessionTimeout`; sem heartbeat no meio, o Kafka tiraria
     * o worker do grupo e reentregaria a mesma mensagem — um laço. O kafkajs só
     * envia de fato quando o intervalo venceu, então chamar com frequência é
     * barato.
     */
    heartbeat?: () => Promise<void>;
}

export interface ImageModerationDeps {
    moderator: ImageModerator;
    mediaPublicUrl: string;
    mode: "observe" | "enforce";
    concurrency: number;
    postBudgetMs?: number;
    getCached?: (url: string) => Promise<CategoryScores | null>;
    setCached?: (url: string, scores: CategoryScores) => Promise<void>;
    sleep?: (ms: number) => Promise<void>;
    now?: () => number;
}

interface ImageResult {
    target: ModerationTarget;
    evaluation: ImageEvaluation;
}

export class ImageModerationService {
    private readonly getCached: NonNullable<ImageModerationDeps["getCached"]>;
    private readonly setCached: NonNullable<ImageModerationDeps["setCached"]>;
    private readonly sleep: NonNullable<ImageModerationDeps["sleep"]>;
    private readonly now: NonNullable<ImageModerationDeps["now"]>;
    private readonly postBudgetMs: number;

    constructor(private readonly deps: ImageModerationDeps) {
        this.getCached = deps.getCached ?? getCachedImageScores;
        this.setCached = deps.setCached ?? setCachedImageScores;
        this.sleep = deps.sleep ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
        this.now = deps.now ?? Date.now;
        this.postBudgetMs = deps.postBudgetMs ?? POST_BUDGET_MS;
    }

    async moderatePost(input: ModeratePostInput): Promise<ImageModerationOutcome> {
        const { targets, skipped } = collectModerationTargets(input.data, this.deps.mediaPublicUrl);

        for (const skip of skipped) {
            imageModerationSkippedTotal.inc({ reason: skip.reason });
        }

        const deadline = this.now() + this.postBudgetMs;
        let failed = 0;

        const results = await runWithConcurrency(targets, this.deps.concurrency, async (target) => {
            const result = await this.moderateOne(input, target, deadline);
            if (!result) { failed += 1; }
            await input.heartbeat?.();
            return result;
        });

        const classified = results.filter((result): result is ImageResult => result !== null);

        const issues: ValidationIssue[] = classified.flatMap(({ target, evaluation }) =>
            evaluation.findings.map((finding) => ({
                code: finding.code,
                field: "media" as const,
                message: finding.message,
                mediaIndex: target.mediaIndex,
            })),
        );

        return {
            action: mostSevere(classified.map(({ evaluation }) => evaluation.action)),
            issues,
            classified: classified.length,
            failed,
            skipped: skipped.length,
        };
    }

    private async moderateOne(
        input: ModeratePostInput,
        target: ModerationTarget,
        deadline: number,
    ): Promise<ImageResult | null> {
        const startedAt = this.now();
        const base = {
            postId: input.postId,
            authorId: input.authorId,
            mediaIndex: target.mediaIndex,
            url: target.url,
            mode: this.deps.mode,
        };

        let scores = await this.getCached(target.url);
        const cached = scores !== null;

        if (!scores) {
            try {
                scores = await this.classifyWithRetry(target.url, deadline, input.heartbeat);
            } catch (err) {
                const reason = err instanceof Error ? err.message : String(err);
                const overBudget = reason === "over_budget";

                if (overBudget) {
                    imageModerationSkippedTotal.inc({ reason: "over_budget" });
                } else {
                    imageModerationTotal.inc({ result: "error", cached: "false" });
                }

                recordImageAudit({
                    ...base,
                    action: "error",
                    cached: false,
                    durationMs: this.now() - startedAt,
                    error: reason,
                });
                return null;
            }

            await this.setCached(target.url, scores);

            // Só score novo entra no histograma: reentrega do Kafka (score vindo
            // do cache) contaria a mesma foto duas vezes na calibragem.
            for (const [category, score] of Object.entries(scores)) {
                imageModerationScore.observe({ category }, score);
            }
        }

        const evaluation = evaluateImage(scores);
        imageModerationTotal.inc({ result: evaluation.action, cached: String(cached) });

        recordImageAudit({
            ...base,
            action: evaluation.action,
            scores: relevantScores(scores),
            findings: evaluation.findings.map((f) => `${f.code}:${f.category}:${f.score.toFixed(3)}:${f.action}`),
            cached,
            durationMs: this.now() - startedAt,
        });

        return { target, evaluation };
    }

    private async classifyWithRetry(
        url: string,
        deadline: number,
        heartbeat?: () => Promise<void>,
    ): Promise<CategoryScores> {
        for (let attempt = 0; ; attempt += 1) {
            if (this.now() >= deadline) {
                throw new Error("over_budget");
            }

            const stopTimer = imageModerationDuration.startTimer();
            try {
                return await this.deps.moderator.classify(url);
            } catch (err) {
                const retryable = err instanceof ModerationError && err.retryable;
                const delay = RETRY_DELAYS_MS[attempt];

                if (!retryable || delay === undefined) {
                    throw err;
                }

                const wait = Math.min(
                    (err as ModerationError).retryAfterMs ?? delay,
                    MAX_RETRY_AFTER_MS,
                );

                if (this.now() + wait >= deadline) {
                    throw new Error("over_budget");
                }

                await heartbeat?.();
                await this.sleep(wait);
            } finally {
                stopTimer();
            }
        }
    }
}

/** Scores relevantes para a auditoria: acima de 1%, com 3 casas. */
function relevantScores(scores: CategoryScores): Record<string, number> {
    return Object.fromEntries(
        Object.entries(scores)
            .filter(([, score]) => score >= 0.01)
            .map(([category, score]) => [category, Math.round(score * 1000) / 1000]),
    );
}
