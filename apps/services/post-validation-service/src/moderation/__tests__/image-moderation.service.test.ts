import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { ImageModerationService, type ImageModerationDeps } from "../image-moderation.service";
import { ModerationError, type CategoryScores, type ImageModerator } from "../types";
import { ValidationCode } from "../../types/validation.types";

const BASE = "https://media.test";
const url = (name: string) => `${BASE}/posts/autor/${name}`;

function moderatorWith(impl: (imageUrl: string) => Promise<CategoryScores>): ImageModerator & { classify: ReturnType<typeof vi.fn> } {
    return { classify: vi.fn(impl) };
}

function build(overrides: Partial<ImageModerationDeps> & { moderator: ImageModerator }) {
    return new ImageModerationService({
        mediaPublicUrl: BASE,
        mode: "enforce",
        concurrency: 3,
        getCached: vi.fn(async () => null),
        setCached: vi.fn(async () => undefined),
        sleep: vi.fn(async () => undefined),
        ...overrides,
    });
}

const post = (media: unknown[]) => ({ postId: "post-1", authorId: "autor-1", data: { media } });

describe("ImageModerationService", () => {
    let logSpy: ReturnType<typeof vi.spyOn>;

    beforeEach(() => {
        logSpy = vi.spyOn(console, "log").mockImplementation(() => undefined);
    });

    afterEach(() => {
        logSpy.mockRestore();
    });

    it("aprova post com fotos limpas", async () => {
        const service = build({ moderator: moderatorWith(async () => ({ sexual: 0.02 })) });

        const outcome = await service.moderatePost(post([{ url: url("a.jpg"), type: "IMAGE" }]));

        expect(outcome).toMatchObject({ action: "allow", issues: [], classified: 1, failed: 0 });
    });

    it("aponta qual das fotos foi reprovada e devolve a acao mais grave", async () => {
        const service = build({
            moderator: moderatorWith(async (imageUrl) =>
                imageUrl.endsWith("b.jpg") ? { sexual: 0.95 } : { sexual: 0.01 }),
        });

        const outcome = await service.moderatePost(post([
            { url: url("a.jpg"), type: "IMAGE" },
            { url: url("b.jpg"), type: "IMAGE" },
        ]));

        expect(outcome.action).toBe("hide");
        expect(outcome.issues).toEqual([
            expect.objectContaining({ code: ValidationCode.IMAGE_SEXUAL, field: "media", mediaIndex: 1 }),
        ]);
    });

    /**
     * URLs de mídia são UUID e não mudam. Mensagem reentregue pelo Kafka não
     * pode chamar a API de novo.
     */
    it("usa o score em cache sem chamar a API", async () => {
        const moderator = moderatorWith(async () => ({ sexual: 0.1 }));
        const service = build({ moderator, getCached: vi.fn(async () => ({ sexual: 0.9 })) });

        const outcome = await service.moderatePost(post([{ url: url("a.jpg"), type: "IMAGE" }]));

        expect(moderator.classify).not.toHaveBeenCalled();
        expect(outcome.action).toBe("hide");
    });

    /**
     * O cache guarda o score, não a decisão: mudar a política vale na hora para
     * imagens já vistas.
     */
    it("grava o score bruto no cache", async () => {
        const setCached = vi.fn(async () => undefined);
        const service = build({ moderator: moderatorWith(async () => ({ sexual: 0.42 })), setCached });

        await service.moderatePost(post([{ url: url("a.jpg"), type: "IMAGE" }]));

        expect(setCached).toHaveBeenCalledWith(url("a.jpg"), { sexual: 0.42 });
    });

    it("tenta de novo erro retentavel e segue quando a API volta", async () => {
        let calls = 0;
        const sleep = vi.fn(async () => undefined);
        const service = build({
            sleep,
            moderator: moderatorWith(async () => {
                calls += 1;
                if (calls === 1) { throw new ModerationError("http_503", true); }
                return { sexual: 0.01 };
            }),
        });

        const outcome = await service.moderatePost(post([{ url: url("a.jpg"), type: "IMAGE" }]));

        expect(calls).toBe(2);
        expect(sleep).toHaveBeenCalledWith(1000);
        expect(outcome.failed).toBe(0);
    });

    it("respeita o Retry-After do 429", async () => {
        let calls = 0;
        const sleep = vi.fn(async () => undefined);
        const service = build({
            sleep,
            moderator: moderatorWith(async () => {
                calls += 1;
                if (calls === 1) { throw new ModerationError("http_429", true, 4000); }
                return {};
            }),
        });

        await service.moderatePost(post([{ url: url("a.jpg"), type: "IMAGE" }]));

        expect(sleep).toHaveBeenCalledWith(4000);
    });

    /**
     * API fora do ar não pode travar o post nem a fila: depois das novas
     * tentativas a imagem fica sem classificação e o post segue.
     */
    it("desiste depois de 3 tentativas e deixa o post seguir", async () => {
        const moderator = moderatorWith(async () => { throw new ModerationError("http_503", true); });
        const service = build({ moderator });

        const outcome = await service.moderatePost(post([{ url: url("a.jpg"), type: "IMAGE" }]));

        expect(moderator.classify).toHaveBeenCalledTimes(3);
        expect(outcome).toMatchObject({ action: "allow", classified: 0, failed: 1 });
    });

    it("nao retenta erro definitivo (imagem inacessivel, chave invalida)", async () => {
        const moderator = moderatorWith(async () => { throw new ModerationError("http_400", false); });
        const service = build({ moderator });

        const outcome = await service.moderatePost(post([{ url: url("a.jpg"), type: "IMAGE" }]));

        expect(moderator.classify).toHaveBeenCalledTimes(1);
        expect(outcome.failed).toBe(1);
    });

    /**
     * A partição tem um consumidor só: um post preso numa API lenta segura
     * todos os de trás. Estourado o orçamento, o resto fica sem classificação.
     */
    it("para de tentar quando estoura o orcamento de tempo do post", async () => {
        let clock = 0;
        const moderator = moderatorWith(async () => {
            clock += 30_000;
            throw new ModerationError("timeout", true);
        });
        const service = build({ moderator, now: () => clock, postBudgetMs: 45_000 });

        const outcome = await service.moderatePost(post([{ url: url("a.jpg"), type: "IMAGE" }]));

        // 1ª tentativa leva o relógio a 30s; a 2ª a 60s; não há 3ª.
        expect(moderator.classify).toHaveBeenCalledTimes(2);
        expect(outcome.failed).toBe(1);
    });

    /**
     * Sem heartbeat no meio, um post com muitas imagens passaria dos 30s do
     * sessionTimeout e o Kafka reentregaria a mensagem num laço.
     */
    it("chama o heartbeat do Kafka entre imagens e antes de esperar para tentar de novo", async () => {
        let calls = 0;
        const heartbeat = vi.fn(async () => undefined);
        const service = build({
            moderator: moderatorWith(async () => {
                calls += 1;
                if (calls === 1) { throw new ModerationError("http_503", true); }
                return {};
            }),
        });

        await service.moderatePost({ ...post([{ url: url("a.jpg"), type: "IMAGE" }]), heartbeat });

        // Um antes da espera da nova tentativa, um ao terminar a imagem.
        expect(heartbeat).toHaveBeenCalledTimes(2);
    });

    it("limita as chamadas simultaneas", async () => {
        let inFlight = 0;
        let peak = 0;
        const service = build({
            concurrency: 2,
            moderator: moderatorWith(async () => {
                inFlight += 1;
                peak = Math.max(peak, inFlight);
                await new Promise((resolve) => setTimeout(resolve, 5));
                inFlight -= 1;
                return {};
            }),
        });

        await service.moderatePost(post(Array.from({ length: 6 }, (_, i) => ({ url: url(`${i}.jpg`), type: "IMAGE" }))));

        expect(peak).toBe(2);
    });

    it("registra auditoria por imagem, com a URL e os scores", async () => {
        const service = build({ moderator: moderatorWith(async () => ({ sexual: 0.6, violence: 0.001 })) });

        await service.moderatePost(post([{ url: url("a.jpg"), type: "IMAGE" }]));

        const audit = logSpy.mock.calls
            .map((call) => JSON.parse(String(call[0])))
            .find((entry) => entry.audit === "post-validation-image");

        expect(audit).toMatchObject({
            postId: "post-1",
            mediaIndex: 0,
            url: url("a.jpg"),
            action: "notify",
            scores: { sexual: 0.6 },
            cached: false,
        });
    });
});
