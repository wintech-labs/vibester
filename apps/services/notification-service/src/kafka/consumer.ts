import { Kafka, logLevel, Consumer } from "kafkajs";
import { env } from "../config/env";
import { handleVerificationEvent } from "./handlers/verification.handler";
import { handleRegistrationEvent } from "./handlers/registration.handler";
import { handleFollowEvent } from "./handlers/follow.handler";
import { handlePostLikedEvent } from "./handlers/postLiked.handler";
import { handlePostCommentedEvent } from "./handlers/postCommented.handler";
import { handleUserDeletedEvent } from "./handlers/userDeleted.handler";
import { handleExcessiveAttemptsEvent } from "./handlers/excessiveAttempts.handler";
import { handlePasswordResetEvent } from "./handlers/passwordReset.handler";
import { handleContentReportedEvent } from "./handlers/contentReported.handler";
import { handlePostValidationRejectedEvent } from "./handlers/postValidationRejected.handler";
import { handlePostModerationHiddenEvent } from "./handlers/postModerationHidden.handler";

export const kafka = new Kafka({
  clientId: "notification-service",
  brokers: env.kafkaBrokers,
  logLevel: logLevel.WARN,
  retry: {
    initialRetryTime: 300,
    retries: 10,
  },
});

let consumer: Consumer | null = null;

const TOPICS = [
  "auth.email.verification",
  "user.registered",
  "user.followed",
  "post.liked",
  "post.commented",
  "user.deleted",
  "auth.attempts.exceeded",
  "auth.password.reset",
  "content.reported",
  // Publicado pelo post-validation-service (modo worker) quando a revalidacao
  // reprova um post que ja esta no ar.
  "post.validation.rejected",
  // Publicado pelo post-service depois de ocultar um post por moderacao de
  // imagem. E daqui, e nao da recomendacao do validador, que sai o aviso
  // "sua publicacao foi removida".
  "post.moderation.hidden",
];

export async function startKafkaConsumers(): Promise<void> {
  try {
    consumer = kafka.consumer({
      groupId: "notification-service-group",
      sessionTimeout: 30000,
      heartbeatInterval: 10000,
    });

    await consumer.connect();
    console.log("[Kafka] Consumer connected");

    await consumer.subscribe({
      topics: TOPICS,
      fromBeginning: false,
    });

    await consumer.run({
      eachMessage: async ({ topic, message }) => {
        const value = message.value?.toString() || "{}";

        switch (topic) {
          case "auth.email.verification":
            await handleVerificationEvent(value);
            break;
          case "user.registered":
            await handleRegistrationEvent(value);
            break;
          case "user.followed":
            await handleFollowEvent(value);
            break;
          case "post.liked":
            await handlePostLikedEvent(value);
            break;
          case "post.commented":
            await handlePostCommentedEvent(value);
            break;
          case "auth.password.reset":
            await handlePasswordResetEvent(value);
            break;
          case "content.reported":
            await handleContentReportedEvent(value);
            break;
          case "post.validation.rejected":
            await handlePostValidationRejectedEvent(value);
            break;
          case "post.moderation.hidden":
            await handlePostModerationHiddenEvent(value);
            break;
          case "user.deleted":
            await handleUserDeletedEvent(value);
            break;
          case "auth.attempts.exceeded":
            await handleExcessiveAttemptsEvent(value);
            break;
          default:
            console.warn(`[Kafka] Unhandled topic: ${topic}`);
        }
      },
    });

    console.log("[Kafka] Consumers listening to topics:", TOPICS);
  } catch (err) {
    console.error("[Kafka] Failed to start Kafka consumers:", err);
  }
}

export async function stopKafkaConsumer(): Promise<void> {
  if (consumer) {
    await consumer.disconnect();
    console.log("[Kafka] Consumer disconnected");
  }
}
