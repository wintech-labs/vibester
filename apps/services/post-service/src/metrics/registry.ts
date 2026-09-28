import client from "prom-client";

export const registry = new client.Registry();

client.collectDefaultMetrics({ register: registry });

// ---------------------------------------------------------------------------
// HTTP — sinais dourados (latência, tráfego, erro) por rota. Label `route` usa
// o padrão da rota (`/posts/:postId`), nunca a URL crua, para não explodir
// cardinalidade com UUIDs reais.
// ---------------------------------------------------------------------------
export const httpRequestDuration = new client.Histogram({
    name: "http_request_duration_seconds",
    help: "Duração das requisições HTTP em segundos",
    labelNames: ["method", "route", "status_code"] as const,
    buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
    registers: [registry],
});

export const httpRequestsTotal = new client.Counter({
    name: "http_requests_total",
    help: "Total de requisições HTTP",
    labelNames: ["method", "route", "status_code"] as const,
    registers: [registry],
});

// ---------------------------------------------------------------------------
// Cassandra — latência por tabela (extraída da query, sem precisar anotar
// cada método do repository) e falha parcial de fan-out entre tabelas
// denormalizadas (o risco central apontado no audit: sem BATCH/LWT, um
// Promise.all pode deixar posts_by_id e posts_by_user divergentes).
// ---------------------------------------------------------------------------
export const cassandraQueryDuration = new client.Histogram({
    name: "cassandra_query_duration_seconds",
    help: "Duração das queries ao Cassandra em segundos",
    labelNames: ["table", "outcome"] as const,
    buckets: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5],
    registers: [registry],
});

export const cassandraFanoutPartialFailureTotal = new client.Counter({
    name: "cassandra_fanout_partial_failure_total",
    help: "Fan-out entre tabelas denormalizadas onde só parte das escritas teve sucesso",
    labelNames: ["operation"] as const,
    registers: [registry],
});

// ---------------------------------------------------------------------------
// Cache-aside (Redis) — hit/miss/error dá o sinal mais acionável de
// performance (TTL bom ou não); invalidation_failure avisa quando o
// redis.del(...) best-effort de post.service.ts está falhando de verdade.
// ---------------------------------------------------------------------------
export const cacheResultTotal = new client.Counter({
    name: "cache_result_total",
    help: "Resultado de leituras no cache-aside",
    labelNames: ["result", "key_prefix"] as const,
    registers: [registry],
});

export const cacheInvalidationFailureTotal = new client.Counter({
    name: "cache_invalidation_failure_total",
    help: "Falhas ao invalidar chaves de cache após uma escrita",
    registers: [registry],
});

// ---------------------------------------------------------------------------
// Kafka — publish é fire-and-forget hoje; sem essa métrica, uma falha de
// publish vira um evento perdido silencioso (só apareceria como sintoma em
// outro serviço, ex. feed-service, dias depois).
// ---------------------------------------------------------------------------
export const kafkaPublishTotal = new client.Counter({
    name: "kafka_publish_total",
    help: "Total de publicações no Kafka",
    labelNames: ["topic", "result"] as const,
    registers: [registry],
});

// ---------------------------------------------------------------------------
// Rate limit (Redis, ver src/plugins.ts) — mostra se os limites configurados
// (RATE_LIMIT_MAX/WRITE_MAX/LIKE_MAX) estão calibrados certo.
// ---------------------------------------------------------------------------
export const rateLimitExceededTotal = new client.Counter({
    name: "rate_limit_exceeded_total",
    help: "Total de requisições rejeitadas por rate limit",
    labelNames: ["route"] as const,
    registers: [registry],
});

// ---------------------------------------------------------------------------
// Negócio — sinal de atividade de baixo custo, sem precisar de data warehouse.
// ---------------------------------------------------------------------------
export const postsCreatedTotal = new client.Counter({
    name: "posts_created_total",
    help: "Total de posts criados",
    registers: [registry],
});

export const likesTotal = new client.Counter({
    name: "likes_total",
    help: "Total de curtidas/descurtidas",
    labelNames: ["action"] as const,
    registers: [registry],
});

export const commentsTotal = new client.Counter({
    name: "comments_total",
    help: "Total de comentários criados/removidos",
    labelNames: ["action"] as const,
    registers: [registry],
});

export const presignedUrlGeneratedTotal = new client.Counter({
    name: "presigned_url_generated_total",
    help: "Total de URLs pré-assinadas geradas para upload",
    labelNames: ["media_type"] as const,
    registers: [registry],
});

/**
 * Resultado da consulta ao post-validation-service, por criação/edição de post.
 *
 * `result`: valid | invalid | unavailable | skipped.
 *
 * É a métrica que governa o rollout do `POST_VALIDATION_MODE`: só vale virar
 * `warn` -> `block` depois de olhar a taxa de `invalid` e se convencer de que
 * não é falso positivo da blocklist. E `unavailable` em alta é o sinal de que a
 * validação está deixando tudo passar sem ninguém perceber.
 */
export const postValidationTotal = new client.Counter({
    name: "post_validation_total",
    help: "Consultas ao post-validation-service, por resultado",
    labelNames: ["result"] as const,
    registers: [registry],
});

/**
 * Posts ocultados pela moderação de imagem, por desfecho.
 *
 * `result`: hidden | already_deleted | not_found | disabled. `disabled` sobe
 * quando o validador pede ocultação com POST_MODERATION_HIDE=off — é o sinal de
 * que o freio de emergência está puxado.
 */
export const postsModerationHiddenTotal = new client.Counter({
    name: "posts_moderation_hidden_total",
    help: "Pedidos de ocultação de post pela moderação, por desfecho",
    labelNames: ["result"] as const,
    registers: [registry],
});
