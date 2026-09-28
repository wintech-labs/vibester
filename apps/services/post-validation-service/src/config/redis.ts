import { createHash } from "crypto";
import Redis from "ioredis";
import { env } from "./env";
import { cacheResultTotal } from "../metrics/registry";
import type { CachedVerdict } from "../types/validation.types";
import type { CategoryScores } from "../moderation/types";

/**
 * Cliente Redis do cache de veredito.
 *
 * `enableOfflineQueue: false` + timeouts curtos são deliberados: numa rota com
 * orçamento de 200ms, um Redis lento é pior do que um Redis ausente. Sem isso,
 * o ioredis enfileira o comando esperando reconexão e a requisição fica pendurada
 * muito além do orçamento. Mesma configuração do post-service.
 */
export const redis = new Redis(env.redis_url, {
    lazyConnect: true,
    maxRetriesPerRequest: 1,
    enableOfflineQueue: false,
    connectTimeout: 1000,
    commandTimeout: 150,
});

redis.on("error", (err: Error) => {
    // `err.message` vem vazio em erro de socket do ioredis (ECONNREFUSED chega
    // como AggregateError sem texto), e uma linha de log só com `msg: ""`
    // desperdiça o plantão de quem for investigar. O `code`/`name` é o que de
    // fato identifica a falha.
    const code = (err as NodeJS.ErrnoException).code;
    console.error(JSON.stringify({
        level: "error",
        service: "redis",
        msg: err.message || code || err.name || "erro desconhecido",
    }));
});

let ready = false;
redis.on("ready", () => { ready = true; });
redis.on("end", () => { ready = false; });

export function isRedisReady(): boolean {
    return ready;
}

/**
 * Lê um veredito do cache. **Nunca lança**: falha de Redis é `null`, e o
 * chamador simplesmente recalcula. O cache existe para latência, não para
 * correção — as regras são puras, então recalcular dá sempre o mesmo resultado.
 */
export async function getCachedVerdict(key: string): Promise<CachedVerdict | null> {
    try {
        const cached = await redis.get(key);

        if (cached === null) {
            cacheResultTotal.inc({ result: "miss" });
            return null;
        }

        cacheResultTotal.inc({ result: "hit" });
        return JSON.parse(cached) as CachedVerdict;
    } catch (err) {
        cacheResultTotal.inc({ result: "error" });
        const msg = err instanceof Error ? err.message : String(err);
        console.error(JSON.stringify({ level: "warn", service: "redis", op: "get", msg }));
        return null;
    }
}

/** Grava o veredito. Também best-effort: falha aqui só custa um recálculo depois. */
export async function setCachedVerdict(key: string, verdict: CachedVerdict): Promise<void> {
    try {
        await redis.set(key, JSON.stringify(verdict), "EX", env.validation_cache_ttl_seconds);
    } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(JSON.stringify({ level: "warn", service: "redis", op: "set", msg }));
    }
}

export async function connectRedis(): Promise<void> {
    // `lazyConnect` deixa a conexão para cá; um Redis fora do ar no boot não
    // pode impedir o serviço de subir, porque o cache é opcional por design.
    try {
        await redis.connect();
    } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(JSON.stringify({ level: "warn", service: "redis", op: "connect", msg }));
    }
}

export async function disconnectRedis(): Promise<void> {
    try {
        await redis.quit();
    } catch {
        redis.disconnect();
    }
}

/**
 * Cache dos scores de moderação de imagem, por URL.
 *
 * Guarda o score bruto da API, não a decisão. Assim, mudar os limites em
 * `src/moderation/policy.ts` vale na hora para imagens já vistas, sem esperar o
 * TTL e sem pagar outra chamada — a política é reaplicada sobre o score
 * guardado. As URLs de mídia são UUID e nunca mudam de conteúdo, o que torna a
 * URL uma chave segura. Best-effort, como o resto: falha de Redis vira chamada
 * à API, nunca erro.
 */
function imageScoresKey(url: string): string {
    return `pv:imgscores:v1:${createHash("sha256").update(url).digest("hex")}`;
}

export async function getCachedImageScores(url: string): Promise<CategoryScores | null> {
    try {
        const cached = await redis.get(imageScoresKey(url));
        return cached === null ? null : (JSON.parse(cached) as CategoryScores);
    } catch {
        return null;
    }
}

export async function setCachedImageScores(url: string, scores: CategoryScores): Promise<void> {
    try {
        await redis.set(imageScoresKey(url), JSON.stringify(scores), "EX", env.image_moderation_cache_ttl_seconds);
    } catch {
        // Sem cache, a próxima reentrega chama a API de novo. Nada quebra.
    }
}
