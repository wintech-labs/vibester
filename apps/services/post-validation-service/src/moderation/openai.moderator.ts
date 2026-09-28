import { CategoryScores, ImageModerator, ModerationError } from "./types";

interface OpenAIModerationResponse {
    results?: Array<{
        category_scores?: Record<string, number>;
        category_applied_input_types?: Record<string, string[]>;
    }>;
    error?: { code?: string; type?: string };
}

export interface OpenAIModeratorOptions {
    apiKey: string;
    url: string;
    model: string;
    timeoutMs: number;
}

/**
 * Adaptador da API de moderação da OpenAI (`POST /v1/moderations`, modelo
 * `omni-moderation-latest`). É gratuita, inclusive no plano sem pagamento.
 *
 * A imagem vai pela URL pública do R2 — a OpenAI baixa sozinha, e o worker não
 * precisa trafegar os bytes. Formato conferido na documentação oficial:
 * `input: [{ type: "image_url", image_url: { url } }]`.
 *
 * Sem SDK, com `fetch` nativo e `AbortController`, no mesmo molde do
 * `ValidationClient` do post-service: é uma chamada só, e uma dependência a
 * mais não se paga.
 */
export class OpenAIModerator implements ImageModerator {
    constructor(private readonly options: OpenAIModeratorOptions) {}

    async classify(imageUrl: string): Promise<CategoryScores> {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), this.options.timeoutMs);

        try {
            let response: Response;
            try {
                response = await fetch(this.options.url, {
                    method: "POST",
                    headers: {
                        "Content-Type": "application/json",
                        Authorization: `Bearer ${this.options.apiKey}`,
                    },
                    body: JSON.stringify({
                        model: this.options.model,
                        input: [{ type: "image_url", image_url: { url: imageUrl } }],
                    }),
                    signal: controller.signal,
                });
            } catch (err) {
                const timeout = err instanceof Error && err.name === "AbortError";
                throw new ModerationError(timeout ? "timeout" : "network", true);
            }

            const body = (await response.json().catch(() => ({}))) as OpenAIModerationResponse;

            if (!response.ok) {
                throw this.errorFor(response, body);
            }

            const result = body.results?.[0];
            if (!result?.category_scores) {
                throw new ModerationError("malformed_response", false);
            }

            return imageScoresOnly(result.category_scores, result.category_applied_input_types);
        } finally {
            clearTimeout(timer);
        }
    }

    private errorFor(response: Response, body: OpenAIModerationResponse): ModerationError {
        const detail = body.error?.code ?? body.error?.type;
        const message = `http_${response.status}${detail ? `:${detail}` : ""}`;

        if (response.status === 429) {
            const seconds = Number(response.headers.get("retry-after"));
            return new ModerationError(message, true, Number.isFinite(seconds) && seconds > 0 ? seconds * 1000 : undefined);
        }

        // 5xx é problema do lado deles e passa. 4xx não vai mudar tentando de
        // novo: imagem que a OpenAI não conseguiu baixar (400), chave inválida
        // (401) ou sem permissão (403). O 401/403 é erro de configuração — sai no
        // log e na métrica de erro, que é onde alguém vai olhar.
        return new ModerationError(message, response.status >= 500);
    }
}

/**
 * Mantém só as categorias que a API de fato avaliou na IMAGEM.
 *
 * Várias categorias são só de texto (ódio, assédio, ilícito, conteúdo sexual
 * com menores). Para uma entrada só de imagem elas voltam com score, mas o
 * score não diz nada sobre a foto — e deixá-las entrar na política seria agir
 * em cima de ruído. Quando a resposta não traz `category_applied_input_types`,
 * tudo passa e a política decide.
 */
function imageScoresOnly(
    scores: Record<string, number>,
    appliedTypes?: Record<string, string[]>,
): CategoryScores {
    if (!appliedTypes) {
        return { ...scores };
    }

    return Object.fromEntries(
        Object.entries(scores).filter(([category]) => appliedTypes[category]?.includes("image")),
    );
}
