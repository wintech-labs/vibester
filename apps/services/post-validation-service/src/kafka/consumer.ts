import { Consumer } from "kafkajs";
import { kafka, POSTS_TOPIC } from "./client";
import { handlePostContentEvent, type ImageModerationDeps } from "./handlers/postContent.handler";
import { ValidationService } from "../services/validation.service";
import { kafkaConsumedTotal } from "../metrics/registry";

/**
 * `groupId` fixo: é o que permite subir réplicas do worker sem reprocessar o
 * mesmo post em dois pods. Não derive do hostname nem do modo.
 */
const GROUP_ID = "post-validation-service-group";

let consumer: Consumer | null = null;
let running = false;

export function isConsumerRunning(): boolean {
    return running;
}

export async function startConsumer(
    validationService: ValidationService,
    imageModeration?: ImageModerationDeps,
): Promise<void> {
    consumer = kafka.consumer({
        groupId: GROUP_ID,
        sessionTimeout: 30000,
        heartbeatInterval: 10000,
    });

    await consumer.connect();

    // `fromBeginning: false`: na primeira subida, revalidar o histórico inteiro
    // de posts notificaria em massa gente cujo post está no ar há meses. Um
    // backfill, se for desejado, é uma decisão de moderação com janela
    // escolhida — não um efeito colateral do primeiro deploy.
    await consumer.subscribe({ topics: [POSTS_TOPIC], fromBeginning: false });

    await consumer.run({
        eachMessage: async ({ topic, message, heartbeat }) => {
            const value = message.value?.toString();

            if (!value) {
                kafkaConsumedTotal.inc({ topic, result: "skipped" });
                return;
            }

            try {
                const result = await handlePostContentEvent(value, validationService, {
                    imageModeration,
                    heartbeat,
                });
                kafkaConsumedTotal.inc({
                    topic,
                    result: result.processed ? (result.valid ? "valid" : "rejected") : "skipped",
                });
            } catch (err) {
                // Só falha de publicação chega aqui — o handler já absorve erro
                // de parse. Propagar é o certo: o Kafka reentrega, e a
                // alternativa seria perder a notificação em silêncio.
                kafkaConsumedTotal.inc({ topic, result: "error" });
                console.error(JSON.stringify({
                    level: "error",
                    service: "post-validation-worker",
                    msg: err instanceof Error ? err.message : String(err),
                }));
                throw err;
            }
        },
    });

    running = true;
}

export async function stopConsumer(): Promise<void> {
    if (consumer) {
        await consumer.disconnect();
        consumer = null;
        running = false;
    }
}
