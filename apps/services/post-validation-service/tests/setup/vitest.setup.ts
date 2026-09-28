import { vi } from "vitest";

/**
 * Mocka `src/config/env` inteiro — evita exigir JWT_SECRET/KAFKA_BROKERS/REDIS_URL
 * reais só para rodar teste. Mesmo padrão do post-service e do interaction-service.
 *
 * Os valores aqui são os limites que os testes assumem. Mudar um número deste
 * objeto muda o que as asserções esperam.
 */
vi.mock("../../src/config/env", () => ({
    env: {
        mode: "api",
        port: 3008,
        jwt_secret: "test-jwt-secret",
        kafka_brokers: "localhost:9092",
        redis_url: "redis://localhost:6379",
        validation_cache_ttl_seconds: 600,
        max_content_length: 500,
        max_body_bytes: 64 * 1024,
        max_tags: 30,
        max_links: 2,
        profanity_blocks: true,
        blocked_domains: ["dominio-da-env.example"],
        rate_limit_max: 120,
        image_moderation_mode: "off",
        image_moderation_effective: { mode: "off" },
        openai_api_key: undefined,
        openai_moderation_url: "https://api.openai.test/v1/moderations",
        openai_moderation_model: "omni-moderation-latest",
        media_public_url: "https://media.test",
        image_moderation_timeout_ms: 15000,
        image_moderation_concurrency: 3,
        image_moderation_cache_ttl_seconds: 604800,
    },
}));

/**
 * O cache é mockado para NÃO acertar nada por padrão: cada teste de regra deve
 * exercitar as regras de verdade, não um veredito guardado de um teste anterior.
 * Os testes que se importam com cache sobrescrevem estes mocks.
 */
vi.mock("../../src/config/redis", () => ({
    redis: {},
    isRedisReady: () => true,
    getCachedVerdict: vi.fn(async () => null),
    setCachedVerdict: vi.fn(async () => undefined),
    getCachedImageScores: vi.fn(async () => null),
    setCachedImageScores: vi.fn(async () => undefined),
    connectRedis: vi.fn(async () => undefined),
    disconnectRedis: vi.fn(async () => undefined),
}));
