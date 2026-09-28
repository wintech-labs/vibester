import { randomUUID } from "crypto";
import { Producer } from "kafkajs";
import { kafka, POST_VALIDATION_REJECTED_TOPIC } from "./client";
import { kafkaPublishTotal } from "../metrics/registry";
import type { ValidationIssue } from "../types/validation.types";

let producer: Producer | null = null;
let connected = false;

export async function connectProducer(): Promise<void> {
    if (producer) { return; }

    producer = kafka.producer({ allowAutoTopicCreation: true });

    producer.on("producer.connect", () => { connected = true; });
    producer.on("producer.disconnect", () => { connected = false; });

    await producer.connect();
}

export function isProducerConnected(): boolean {
    return connected;
}

export async function disconnectProducer(): Promise<void> {
    if (producer) {
        await producer.disconnect();
        producer = null;
        connected = false;
    }
}

export interface PostValidationRejectedData {
    postId: string;
    authorId: string;
    /**
     * O que este serviço recomenda fazer com o post:
     * - "notify": só avisar o autor (todo achado de texto, e imagem menos grave);
     * - "hide":   ocultar o post (imagem grave). Quem executa é o post-service,
     *             dono do ciclo de vida do post; este serviço só julga conteúdo.
     */
    action: "notify" | "hide";
    /**
     * Só `code`, `field` e `mediaIndex`: o consumidor monta a mensagem que
     * mostra ao usuário, e nunca recebe o termo casado nem o score.
     */
    issues: Pick<ValidationIssue, "code" | "field" | "mediaIndex">[];
    validatedAt: string;
}

/**
 * Publica no mesmo envelope `{ eventId, eventType, occurredAt, data }` que o
 * post-service usa (`publishEvent` em `post-service/src/kafka/events.ts`).
 *
 * Isso não é estética: o notification-service desembrulha eventos com
 * `unwrapEventData`, que procura exatamente `eventType` + `data`. Publicar o
 * payload solto faria o handler não achar `postId` e descartar a notificação em
 * silêncio — foi o bug que o `envelope.ts` de lá existe para consertar.
 *
 * `key = postId` mantém a ordem por post e espalha a carga entre partições.
 */
export async function publishValidationRejected(data: PostValidationRejectedData): Promise<void> {
    if (!producer) {
        throw new Error("Produtor Kafka não conectado");
    }

    try {
        await producer.send({
            topic: POST_VALIDATION_REJECTED_TOPIC,
            messages: [{
                key: data.postId,
                value: JSON.stringify({
                    eventId: randomUUID(),
                    eventType: "post.validation.rejected",
                    occurredAt: new Date().toISOString(),
                    data,
                }),
            }],
        });
        kafkaPublishTotal.inc({ topic: POST_VALIDATION_REJECTED_TOPIC, result: "success" });
    } catch (err) {
        kafkaPublishTotal.inc({ topic: POST_VALIDATION_REJECTED_TOPIC, result: "failure" });
        throw err;
    }
}
