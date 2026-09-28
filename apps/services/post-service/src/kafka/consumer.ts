import { Kafka, Consumer } from "kafkajs";
import { z } from "zod";
import { env } from "../config/env";
import { postsModerationHiddenTotal } from "../metrics/registry";
import type { AccountContentDeletionService } from "../services/account-content-deletion.service";
import type { PostService } from "../services/post.service";

export const USER_DELETED_TOPIC = "user.deleted";

/** Publicado pelo worker do post-validation-service. */
export const POST_VALIDATION_REJECTED_TOPIC = "post.validation.rejected";

// Payload plano publicado pelo auth-service (DELETE /auth/account). O id vira
// prefixo de chave no R2, então só UUID passa.
const userDeletedSchema = z.object({
    userId: z.string().uuid().optional(),
    accountId: z.string().uuid().optional(),
}).refine((event) => event.accountId || event.userId, { message: "accountId ou userId obrigatório" });

type DeletionService = Pick<AccountContentDeletionService, "deleteAllContent">;
type ModerationService = Pick<PostService, "hideForModeration">;

export async function handleUserDeletedMessage(rawValue: string, service: DeletionService): Promise<void> {
    let event: z.infer<typeof userDeletedSchema>;
    try {
        event = userDeletedSchema.parse(JSON.parse(rawValue));
    } catch (error) {
        // Malformada nunca vai dar certo: descarta para não travar a partição.
        const msg = error instanceof Error ? error.message : String(error);
        console.error(JSON.stringify({ level: "error", service: "post-service", op: "user.deleted", msg: "invalid event, skipping", detail: msg }));
        return;
    }

    const userId = (event.accountId ?? event.userId)!;
    await service.deleteAllContent(userId);
    console.log(JSON.stringify({ level: "info", service: "post-service", op: "user.deleted", msg: "account content deleted", userId }));
}

// Envelope { eventId, eventType, occurredAt, data } do post-validation-service.
const validationRejectedSchema = z.object({
    data: z.object({
        postId: z.string().uuid(),
        authorId: z.string().min(1),
        // Ausente em evento publicado antes da moderação de imagem existir:
        // esses eram sempre aviso, nunca ocultação.
        action: z.enum(["notify", "hide"]).default("notify"),
        issues: z.array(z.object({
            code: z.string(),
            field: z.string().optional(),
            mediaIndex: z.number().int().nonnegative().optional(),
        })).default([]),
    }),
});

/**
 * `post.validation.rejected` com `action: "hide"`: a moderação de imagem
 * achou algo grave num post publicado. Este serviço decide executar — ele é o
 * dono do ciclo de vida do post; o validador só julga conteúdo.
 *
 * `action: "notify"` não é daqui (só o notification-service age), então é
 * ignorado. Evento malformado é descartado sem lançar, para não travar a
 * partição; erro de Cassandra/Kafka ao ocultar sobe, e o kafkajs reentrega —
 * `hideForModeration` é idempotente, então reentregar é seguro.
 */
export async function handleValidationRejectedMessage(rawValue: string, service: ModerationService): Promise<void> {
    let data: z.infer<typeof validationRejectedSchema>["data"];
    try {
        data = validationRejectedSchema.parse(JSON.parse(rawValue)).data;
    } catch (error) {
        const msg = error instanceof Error ? error.message : String(error);
        console.error(JSON.stringify({ level: "error", service: "post-service", op: "post.validation.rejected", msg: "invalid event, skipping", detail: msg }));
        return;
    }

    if (data.action !== "hide") { return; }

    if (!env.post_moderation_hide) {
        postsModerationHiddenTotal.inc({ result: "disabled" });
        console.warn(JSON.stringify({ level: "warn", service: "post-service", op: "post.validation.rejected", msg: "hide requested but POST_MODERATION_HIDE=off", postId: data.postId }));
        return;
    }

    const result = await service.hideForModeration(data.postId, data.issues);
    postsModerationHiddenTotal.inc({ result });
    console.log(JSON.stringify({
        level: "info",
        service: "post-service",
        op: "post.validation.rejected",
        msg: "moderation hide",
        postId: data.postId,
        result,
        codes: data.issues.map((issue) => issue.code),
    }));
}

let _consumer: Consumer | null = null;

export async function startConsumer(deletion: DeletionService, moderation: ModerationService): Promise<void> {
    const kafka = new Kafka({ clientId: "post-service", brokers: env.kafka_brokers.split(",") });
    _consumer = kafka.consumer({ groupId: "post-service-group" });

    await _consumer.connect();
    await _consumer.subscribe({ topics: [USER_DELETED_TOPIC, POST_VALIDATION_REJECTED_TOPIC], fromBeginning: false });

    await _consumer.run({
        eachMessage: async ({ topic, message }) => {
            const value = message.value?.toString() ?? "{}";

            // Erro de Cassandra/R2 sobe: o kafkajs tenta de novo com backoff.
            if (topic === POST_VALIDATION_REJECTED_TOPIC) {
                await handleValidationRejectedMessage(value, moderation);
                return;
            }

            await handleUserDeletedMessage(value, deletion);
        },
    });
}

export async function stopConsumer(): Promise<void> {
    await _consumer?.disconnect();
    _consumer = null;
}
