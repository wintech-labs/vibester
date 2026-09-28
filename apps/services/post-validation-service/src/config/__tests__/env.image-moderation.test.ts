import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

/**
 * O módulo real — `tests/setup/vitest.setup.ts` mocka `src/config/env` para o
 * resto da suíte. O que se prova aqui é a rede de segurança do Secret, que é
 * criado à mão: modo ligado com a chave ou o endereço faltando desliga a
 * moderação de imagem (com motivo), em vez de derrubar o worker.
 */
vi.unmock("../env");
vi.mock("dotenv", () => ({ default: { config: () => ({}) } }));

const BASE_ENV = {
    JWT_SECRET: "s",
    KAFKA_BROKERS: "localhost:9092",
    REDIS_URL: "redis://localhost:6379",
};

async function loadEnv(extra: Record<string, string>) {
    vi.resetModules();
    const saved = { ...process.env };
    process.env = { ...BASE_ENV, ...extra } as NodeJS.ProcessEnv;
    try {
        return (await import("../env")).env;
    } finally {
        process.env = saved;
    }
}

describe("env — moderação de imagem efetiva", () => {
    beforeEach(() => {
        vi.spyOn(console, "error").mockImplementation(() => undefined);
    });

    afterEach(() => {
        vi.restoreAllMocks();
    });

    it("fica desligada por padrão", async () => {
        const env = await loadEnv({});

        expect(env.image_moderation_effective).toEqual({ mode: "off" });
    });

    it("liga quando tem modo, chave e endereço do bucket", async () => {
        const env = await loadEnv({
            IMAGE_MODERATION_MODE: "enforce",
            OPENAI_API_KEY: "sk-x",
            MEDIA_PUBLIC_URL: "https://media.vibester.test/",
        });

        expect(env.image_moderation_effective).toEqual({ mode: "enforce" });
        // Sem barra final: a checagem de prefixo compara com `${base}/`.
        expect(env.media_public_url).toBe("https://media.vibester.test");
    });

    it.each([
        [{ MEDIA_PUBLIC_URL: "https://media.test" }, "OPENAI_API_KEY"],
        [{ OPENAI_API_KEY: "sk-x" }, "MEDIA_PUBLIC_URL"],
    ])("desliga, com motivo, quando falta configuração (%o)", async (extra, missing) => {
        const env = await loadEnv({ IMAGE_MODERATION_MODE: "observe", ...extra });

        expect(env.image_moderation_effective.mode).toBe("off");
        expect(env.image_moderation_effective.reason).toContain(missing);
    });
});
