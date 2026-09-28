import { insertNotification } from "../../services/insertNotification.service";
import { unwrapEventData } from "../envelope";
import { hasSelfHarm, reasonsFor, SELF_HARM_SUPPORT, type ModerationIssue } from "./postModeration.messages";

interface PostModerationHiddenEvent {
  postId: string;
  authorId: string;
  issues: ModerationIssue[];
  hiddenAt: string;
}

/**
 * Avisa o autor que a publicação foi **removida** pela moderação de imagem.
 *
 * Consome `post.moderation.hidden`, que o post-service só publica depois de
 * ocultar o post de fato. É por isso que aqui — e só aqui — a mensagem pode
 * dizer "foi removida".
 *
 * Usa o mesmo tipo `post_rejected` do aviso comum: o app já o desenha como
 * aviso do Vibester, e o agrupamento por `type:refId` junta este aviso com um
 * eventual aviso anterior do mesmo post numa linha só, mostrando o mais recente.
 */
export async function handlePostModerationHiddenEvent(value: string): Promise<void> {
  try {
    const event = unwrapEventData<PostModerationHiddenEvent>(JSON.parse(value));

    if (!event.postId || !event.authorId) return;

    const issues = event.issues ?? [];
    const reasons = reasonsFor(issues);
    const removal = reasons.length > 0
      ? `Sua publicação foi removida porque ${reasons.join("; ")}.`
      : "Sua publicação foi removida por não seguir as diretrizes da comunidade.";

    // Se entre os motivos havia automutilação, a mensagem de apoio vai junto:
    // a remoção aconteceu por outro motivo, mas a pessoa pode estar em crise.
    const content = hasSelfHarm(issues) ? `${removal} ${SELF_HARM_SUPPORT}` : removal;

    await insertNotification(
      "post_rejected",
      event.authorId,
      event.authorId,
      event.postId,
      content,
    );

    console.log(`[Kafka] Moderation removal notified for post ${event.postId}`);
  } catch (err) {
    console.error("[Kafka] Error handling post.moderation.hidden event:", err);
  }
}
