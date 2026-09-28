import { randomUUID } from "crypto";
import { producer } from "./producer";
import { kafkaPublishTotal } from "../metrics/registry";

export const POSTS_TOPIC = "posts";

/**
 * Publicado DEPOIS que um post é ocultado pela moderação. O notification-service
 * avisa o autor a partir daqui — e não da recomendação do validador —, para que
 * "sua publicação foi removida" só seja dito quando a remoção aconteceu.
 */
export const POST_MODERATION_HIDDEN_TOPIC = "post.moderation.hidden";

/**
 * Único ponto de montagem do envelope de evento do serviço — todo publish deve
 * passar por aqui, nunca montar `{ eventId, eventType, occurredAt, data }` (ou
 * um payload plano, sem envelope) na mão dentro de um service.
 */
export async function publishEvent(topic: string, key: string, eventType: string, data: unknown) {
    try {
        const result = await producer.send({
            topic,
            messages: [{
                key,
                value: JSON.stringify({
                    eventId: randomUUID(),
                    eventType,
                    occurredAt: new Date().toISOString(),
                    data,
                }),
            }],
        });
        kafkaPublishTotal.inc({ topic, result: "success" });
        return result;
    } catch (err) {
        kafkaPublishTotal.inc({ topic, result: "failure" });
        throw err;
    }
}
