import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { OpenAIModerator } from "../openai.moderator";
import { ModerationError } from "../types";

const OPTIONS = {
    apiKey: "sk-teste",
    url: "https://api.openai.test/v1/moderations",
    model: "omni-moderation-latest",
    timeoutMs: 1000,
};

const IMAGE = "https://media.test/posts/autor/foto.jpg";

function reply(status: number, body: unknown, headers: Record<string, string> = {}) {
    return {
        ok: status >= 200 && status < 300,
        status,
        headers: { get: (name: string) => headers[name.toLowerCase()] ?? null },
        json: async () => body,
    } as unknown as Response;
}

describe("OpenAIModerator", () => {
    let fetchMock: ReturnType<typeof vi.fn>;

    beforeEach(() => {
        fetchMock = vi.fn();
        vi.stubGlobal("fetch", fetchMock);
    });

    afterEach(() => {
        vi.unstubAllGlobals();
    });

    /**
     * Formato conferido na documentação da OpenAI. Uma imagem por chamada: com
     * várias entradas a API devolve um resultado combinado, e não daria para
     * saber qual foto foi reprovada.
     */
    it("manda uma imagem por chamada, pela URL, no formato da API", async () => {
        fetchMock.mockResolvedValue(reply(200, { results: [{ category_scores: { sexual: 0.1 } }] }));

        await new OpenAIModerator(OPTIONS).classify(IMAGE);

        const [url, init] = fetchMock.mock.calls[0];
        expect(url).toBe(OPTIONS.url);
        expect(init.headers.Authorization).toBe("Bearer sk-teste");
        expect(JSON.parse(init.body)).toEqual({
            model: "omni-moderation-latest",
            input: [{ type: "image_url", image_url: { url: IMAGE } }],
        });
    });

    /**
     * Categorias só de texto (ódio, assédio, menores) voltam com score mesmo
     * para entrada só de imagem. Esse score não diz nada sobre a foto.
     */
    it("descarta categorias que a API nao avaliou na imagem", async () => {
        fetchMock.mockResolvedValue(reply(200, {
            results: [{
                category_scores: { sexual: 0.9, hate: 0.7, violence: 0.2 },
                category_applied_input_types: { sexual: ["image"], hate: [], violence: ["image"] },
            }],
        }));

        const scores = await new OpenAIModerator(OPTIONS).classify(IMAGE);

        expect(scores).toEqual({ sexual: 0.9, violence: 0.2 });
    });

    it("usa todos os scores quando a resposta nao diz o tipo de entrada", async () => {
        fetchMock.mockResolvedValue(reply(200, { results: [{ category_scores: { sexual: 0.3 } }] }));

        expect(await new OpenAIModerator(OPTIONS).classify(IMAGE)).toEqual({ sexual: 0.3 });
    });

    it("trata 429 como retentavel e respeita o Retry-After", async () => {
        fetchMock.mockResolvedValue(reply(429, { error: { code: "rate_limit_exceeded" } }, { "retry-after": "2" }));

        const error = await new OpenAIModerator(OPTIONS).classify(IMAGE).catch((e) => e);

        expect(error).toBeInstanceOf(ModerationError);
        expect(error.retryable).toBe(true);
        expect(error.retryAfterMs).toBe(2000);
        expect(error.message).toBe("http_429:rate_limit_exceeded");
    });

    it("trata 5xx como retentavel", async () => {
        fetchMock.mockResolvedValue(reply(503, {}));

        const error = await new OpenAIModerator(OPTIONS).classify(IMAGE).catch((e) => e);

        expect(error.retryable).toBe(true);
    });

    /**
     * Imagem que a OpenAI não consegue baixar (400) ou chave inválida (401) não
     * mudam tentando de novo — e insistir só gastaria o limite por minuto.
     */
    it.each([400, 401, 403])("nao retenta %i", async (status) => {
        fetchMock.mockResolvedValue(reply(status, { error: { type: "invalid_request_error" } }));

        const error = await new OpenAIModerator(OPTIONS).classify(IMAGE).catch((e) => e);

        expect(error.retryable).toBe(false);
    });

    it("trata erro de rede como retentavel", async () => {
        fetchMock.mockRejectedValue(new Error("ECONNRESET"));

        const error = await new OpenAIModerator(OPTIONS).classify(IMAGE).catch((e) => e);

        expect(error).toMatchObject({ message: "network", retryable: true });
    });

    it("aborta pelo timeout", async () => {
        fetchMock.mockImplementation((_url: string, init: RequestInit) => new Promise((_resolve, reject) => {
            init.signal?.addEventListener("abort", () => {
                const abort = new Error("aborted");
                abort.name = "AbortError";
                reject(abort);
            });
        }));

        const error = await new OpenAIModerator({ ...OPTIONS, timeoutMs: 20 }).classify(IMAGE).catch((e) => e);

        expect(error).toMatchObject({ message: "timeout", retryable: true });
    });

    it("rejeita resposta sem scores", async () => {
        fetchMock.mockResolvedValue(reply(200, { results: [{}] }));

        const error = await new OpenAIModerator(OPTIONS).classify(IMAGE).catch((e) => e);

        expect(error).toMatchObject({ message: "malformed_response", retryable: false });
    });
});
