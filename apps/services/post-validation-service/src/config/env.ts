import dotenv from "dotenv";
import { z } from "zod";

dotenv.config();

const envSchema = z.object({
    // Uma imagem, dois modos: "api" sobe o endpoint síncrono de validação,
    // "worker" sobe o consumidor que revalida o que já foi publicado. São dois
    // Deployments no k8s — mesmo padrão do interaction-service.
    //
    // NÃO renomeie para `MODE`: o Vitest injeta `process.env.MODE=test`, o que
    // quebraria o boot em qualquer contexto com ferramental Vite.
    SERVICE_MODE: z.enum(["api", "worker"]).default("api"),
    PORT: z.coerce.number().default(3008),

    // Token emitido pelo auth-service (HS256). O payload traz { userId, accountId };
    // só o accountId é identidade pública — ver src/plugins/auth.ts.
    JWT_SECRET: z.string().min(1, "JWT_SECRET é obrigatório"),

    KAFKA_BROKERS: z.string().min(1, "KAFKA_BROKERS é obrigatório"),

    // Cache de veredito. Best-effort: queda do Redis degrada latência, nunca
    // derruba a validação (src/config/redis.ts).
    REDIS_URL: z.string().min(1, "REDIS_URL é obrigatório"),
    VALIDATION_CACHE_TTL_SECONDS: z.coerce.number().int().positive().default(600),

    // --- Limites de conteúdo ---
    //
    // 500 é o limite desta especificação. Convive com outros dois: o app corta
    // a legenda em 280 (`_captionLimit` no composer) e o `createPostSchema` do
    // post-service aceita até 2000 — ver "Três limites de legenda" no CLAUDE.md.
    // É env var para alinhar os três sem deploy de código.
    MAX_CONTENT_LENGTH: z.coerce.number().int().positive().max(10000).default(500),

    // Teto de bytes do corpo da requisição. Independe de MAX_CONTENT_LENGTH:
    // protege o parser antes de qualquer regra rodar.
    MAX_BODY_BYTES: z.coerce.number().int().positive().default(64 * 1024),

    MAX_TAGS: z.coerce.number().int().positive().default(30),

    // Acima disso o post é tratado como spam. 2 links já cobre "ingresso + mapa".
    MAX_LINKS: z.coerce.number().int().nonnegative().default(2),

    // Palavrão forte rejeita o post? Discurso de ódio SEMPRE rejeita e não é
    // afetado por esta flag. Existe porque "impróprio" num app de vida noturna
    // é calibragem de moderação, não decisão de engenharia — e mudar de ideia
    // não deve exigir deploy.
    PROFANITY_BLOCKS: z
        .enum(["true", "false"])
        .default("true")
        .transform((value) => value === "true"),

    // Domínios extras bloqueados, separados por vírgula. Somados à lista
    // embutida em src/rules/data/link-policy.ts, nunca a substituem.
    BLOCKED_DOMAINS: z.string().optional(),

    RATE_LIMIT_MAX: z.coerce.number().default(120),

    // --- Moderação de imagem (só o worker usa) ---
    //
    // off:     não classifica imagem.
    // observe: classifica e mede (métricas + auditoria), mas não publica nada.
    //          É o modo de calibragem: roda em posts reais sem afetar ninguém.
    // enforce: publica post.validation.rejected com `action` — "hide" para o
    //          post-service ocultar o post, "notify" para só avisar o autor.
    IMAGE_MODERATION_MODE: z.enum(["off", "observe", "enforce"]).default("off"),

    // API de moderação da OpenAI (gratuita). Sem chave, a moderação de imagem
    // fica desligada mesmo com o modo ligado — ver `image_moderation_effective`.
    OPENAI_API_KEY: z.string().optional(),
    OPENAI_MODERATION_URL: z.string().url().default("https://api.openai.com/v1/moderations"),
    OPENAI_MODERATION_MODEL: z.string().default("omni-moderation-latest"),

    // Endereço público do bucket de mídia (o mesmo R2_PUBLIC_URL do post-service).
    // Só URL que começa por aqui é enviada para classificação: um post nunca
    // deveria ter mídia de outro lugar, e mandar URL arbitrária para um terceiro
    // não é algo que este serviço deva fazer.
    MEDIA_PUBLIC_URL: z.string().url().optional(),

    // O worker não tem orçamento de 200ms: a OpenAI baixa a imagem antes de
    // classificar, e isso pode levar alguns segundos.
    IMAGE_MODERATION_TIMEOUT_MS: z.coerce.number().int().positive().default(15000),
    IMAGE_MODERATION_CONCURRENCY: z.coerce.number().int().positive().max(10).default(3),

    // Scores ficam em cache por URL. As URLs de mídia são UUID e nunca mudam de
    // conteúdo, então uma mensagem reentregue pelo Kafka não chama a API de novo.
    IMAGE_MODERATION_CACHE_TTL_SECONDS: z.coerce.number().int().positive().default(7 * 24 * 60 * 60),
});

const parsed = envSchema.safeParse(process.env);

if (!parsed.success) {
    console.error(
        "[ENV] Variáveis de ambiente inválidas:",
        JSON.stringify(parsed.error.flatten().fieldErrors, null, 2)
    );
    process.exit(1);
}

const _env = parsed.data;

export const env = {
    mode: _env.SERVICE_MODE,
    port: _env.PORT,
    jwt_secret: _env.JWT_SECRET,
    kafka_brokers: _env.KAFKA_BROKERS,
    redis_url: _env.REDIS_URL,
    validation_cache_ttl_seconds: _env.VALIDATION_CACHE_TTL_SECONDS,
    max_content_length: _env.MAX_CONTENT_LENGTH,
    max_body_bytes: _env.MAX_BODY_BYTES,
    max_tags: _env.MAX_TAGS,
    max_links: _env.MAX_LINKS,
    profanity_blocks: _env.PROFANITY_BLOCKS,
    blocked_domains: (_env.BLOCKED_DOMAINS ?? "")
        .split(",")
        .map((domain) => domain.trim().toLowerCase())
        .filter((domain) => domain.length > 0),
    rate_limit_max: _env.RATE_LIMIT_MAX,
    image_moderation_mode: _env.IMAGE_MODERATION_MODE,
    image_moderation_effective: imageModerationEffective(),
    openai_api_key: _env.OPENAI_API_KEY,
    openai_moderation_url: _env.OPENAI_MODERATION_URL,
    openai_moderation_model: _env.OPENAI_MODERATION_MODEL,
    // Sem barra final: a checagem de prefixo compara com `${base}/`.
    media_public_url: _env.MEDIA_PUBLIC_URL?.replace(/\/+$/, ""),
    image_moderation_timeout_ms: _env.IMAGE_MODERATION_TIMEOUT_MS,
    image_moderation_concurrency: _env.IMAGE_MODERATION_CONCURRENCY,
    image_moderation_cache_ttl_seconds: _env.IMAGE_MODERATION_CACHE_TTL_SECONDS,
};

/**
 * Modo que vale de fato. Ligar o modo sem a chave da OpenAI ou sem o endereço
 * do bucket não pode derrubar o worker — o Secret é criado à mão e pode chegar
 * incompleto. Nesse caso a moderação de imagem fica desligada, e o motivo sai
 * no log de boot (`src/worker.ts`) para ninguém achar que está funcionando.
 */
function imageModerationEffective(): { mode: "off" | "observe" | "enforce"; reason?: string } {
    if (_env.IMAGE_MODERATION_MODE === "off") {
        return { mode: "off" };
    }

    const missing = [
        !_env.OPENAI_API_KEY ? "OPENAI_API_KEY" : null,
        !_env.MEDIA_PUBLIC_URL ? "MEDIA_PUBLIC_URL" : null,
    ].filter(Boolean);

    if (missing.length > 0) {
        return { mode: "off", reason: `IMAGE_MODERATION_MODE=${_env.IMAGE_MODERATION_MODE}, mas falta ${missing.join(" e ")}` };
    }

    return { mode: _env.IMAGE_MODERATION_MODE };
}
