import dotenv from "dotenv";
import { z } from "zod";

dotenv.config();

const envSchema = z.object({
    PORT: z.string().default("3000"),
    R2_ACCOUNT_ID: z.string().min(1, "R2_ACCOUNT_ID é obrigatório"),
    R2_ACCESS_KEY_ID: z.string().min(1, "R2_ACCESS_KEY_ID é obrigatório"),
    R2_SECRET_ACCESS_KEY: z.string().min(1, "R2_SECRET_ACCESS_KEY é obrigatório"),
    R2_BUCKET_NAME: z.string().min(1, "R2_BUCKET_NAME é obrigatório"),
    R2_PUBLIC_URL: z.string().min(1, "R2_PUBLIC_URL é obrigatório"),
    // Em produção o Cassandra é o DataStax Astra (secure connect bundle obrigatório).
    // Em CI/local, CASSANDRA_CONTACT_POINTS aponta para um cluster OSS solto (docker-compose) e
    // dispensa as credenciais do Astra — ver src/config/cassandra.ts para a escolha do modo.
    ASTRA_SECURE_CONNECT_BUNDLE: z.string().optional(),
    ASTRA_CLIENT_ID: z.string().optional(),
    ASTRA_CLIENT_SECRET: z.string().optional(),
    ASTRA_TOKEN: z.string().optional(),
    ASTRA_KEYSPACE: z.string().min(1, "ASTRA_KEYSPACE é obrigatório"),
    CASSANDRA_CONTACT_POINTS: z.string().optional(),
    CASSANDRA_LOCAL_DATA_CENTER: z.string().default("datacenter1"),
    KAFKA_BROKERS: z.string().min(1, "KAFKA_BROKERS é obrigatório"),
    REDIS_URL: z.string().url("REDIS_URL deve ser uma URL válida").default("redis://localhost:6379"),
    RATE_LIMIT_MAX: z.coerce.number().default(200),
    RATE_LIMIT_WRITE_MAX: z.coerce.number().default(30),
    RATE_LIMIT_LIKE_MAX: z.coerce.number().default(60),
    // Lista separada por vírgula. Ausente/vazia = fallback para `origin: true`
    // (aceita qualquer origem, com aviso no log) — ver src/plugins.ts.
    CORS_ALLOWED_ORIGINS: z.string().optional(),

    // --- post-validation-service ---
    POST_VALIDATION_URL: z.string().url().default("http://post-validation-service:3008"),

    // Orçamento da chamada inteira. O serviço de validação responde em ~5ms e
    // promete p95 < 200ms; 1s é folga larga para rede de cluster e ainda assim
    // um teto que o autor não sente ao publicar.
    POST_VALIDATION_TIMEOUT_MS: z.coerce.number().int().positive().default(1000),

    // Como a criação de post reage ao veredito:
    //   block - conteúdo reprovado vira 422 e o post NÃO é criado.
    //   warn  - consulta e mede, mas nunca barra. É o modo de rollout: sobe
    //           assim, olha `post_validation_total{result="invalid"}` por
    //           alguns dias e só então vira `block`. Ligar direto em `block`
    //           faz todo falso positivo da blocklist virar publicação recusada
    //           no primeiro minuto de deploy.
    //   off   - nem chama. Interruptor de emergência, sem deploy.
    POST_VALIDATION_MODE: z.enum(["block", "warn", "off"]).default("block"),

    // Ocultar post quando a moderação de imagem do post-validation-service pede
    // (`post.validation.rejected` com `action: "hide"`). O validador só
    // recomenda; quem executa é este serviço, dono do ciclo de vida do post.
    // A alavanca de rollout é o IMAGE_MODERATION_MODE do worker de validação
    // (enquanto ele está em `observe`, nada chega aqui) — esta variável é o
    // freio de emergência, sem deploy.
    POST_MODERATION_HIDE: z.enum(["on", "off"]).default("on"),
});

const parsed = envSchema.safeParse(process.env);

if (!parsed.success) {
    console.error("[ENV] Variáveis de ambiente inválidas:", JSON.stringify(parsed.error.flatten().fieldErrors, null, 2));
    process.exit(1);
}

const _env = parsed.data;

export const env = {
    port: _env.PORT,
    r2_account_id: _env.R2_ACCOUNT_ID,
    r2_access_key_id: _env.R2_ACCESS_KEY_ID,
    r2_secret_access_key: _env.R2_SECRET_ACCESS_KEY,
    r2_bucket_name: _env.R2_BUCKET_NAME,
    // Sem barra final: post.schema.ts monta prefixos como `${r2_public_url}/posts/...`
    // — se a env var já viesse com barra, isso duplicaria a barra e rejeitaria
    // toda mídia válida (bucketUrlSchema/ownPrefix nunca bateriam).
    r2_public_url: _env.R2_PUBLIC_URL.replace(/\/+$/, ""),
    secure_connect_bundle: _env.ASTRA_SECURE_CONNECT_BUNDLE,
    astra_client_id: _env.ASTRA_CLIENT_ID,
    astra_client_secret: _env.ASTRA_CLIENT_SECRET,
    astra_token: _env.ASTRA_TOKEN,
    keyspace: _env.ASTRA_KEYSPACE,
    cassandra_contact_points: _env.CASSANDRA_CONTACT_POINTS,
    cassandra_local_data_center: _env.CASSANDRA_LOCAL_DATA_CENTER,
    kafka_brokers: _env.KAFKA_BROKERS,
    redis_url: _env.REDIS_URL,
    rate_limit_max: _env.RATE_LIMIT_MAX,
    rate_limit_write_max: _env.RATE_LIMIT_WRITE_MAX,
    rate_limit_like_max: _env.RATE_LIMIT_LIKE_MAX,
    cors_allowed_origins: _env.CORS_ALLOWED_ORIGINS
        ? _env.CORS_ALLOWED_ORIGINS.split(",").map((origin) => origin.trim()).filter(Boolean)
        : undefined,
    // Sem barra final: o cliente monta `${post_validation_url}/validations/post`.
    post_validation_url: _env.POST_VALIDATION_URL.replace(/\/+$/, ""),
    post_validation_timeout_ms: _env.POST_VALIDATION_TIMEOUT_MS,
    post_validation_mode: _env.POST_VALIDATION_MODE,
    post_moderation_hide: _env.POST_MODERATION_HIDE === "on",
};
