import { insertNotification } from "../../services/insertNotification.service";
import { unwrapEventData } from "../envelope";
import { hasSelfHarm, reasonsFor, SELF_HARM_SUPPORT, type ModerationIssue } from "./postModeration.messages";

interface PostValidationRejectedEvent {
  postId: string;
  authorId: string;
  /** "hide" = o post-service vai ocultar; "notify" = só aviso. Ausente em evento antigo (= aviso). */
  action?: "notify" | "hide";
  issues: ModerationIssue[];
  validatedAt: string;
}

/**
 * Avisa o autor quando a revalidação assíncrona reprova um post que já está no
 * ar (`post-validation-service`, modo worker) e o post **continua no ar**.
 *
 * `action: "hide"` é ignorado aqui: o validador só recomendou ocultar, quem
 * executa é o post-service. O aviso "foi removida" sai de
 * `postModerationHidden.handler.ts`, depois que a remoção aconteceu — avisar a
 * partir da recomendação poderia afirmar uma remoção que não ocorreu (freio
 * POST_MODERATION_HIDE desligado, post já apagado, falha).
 *
 * `actorId` é o próprio autor porque não existe outro ator: quem reprovou foi o
 * sistema, e o schema de `Notification` exige o campo.
 *
 * O evento pode chegar duplicado — o worker republica quando o Kafka reentrega
 * a mensagem de origem. O custo é uma notificação repetida, que o agrupamento
 * por `type:refId` junta na listagem.
 */
export async function handlePostValidationRejectedEvent(value: string): Promise<void> {
  try {
    const event = unwrapEventData<PostValidationRejectedEvent>(JSON.parse(value));

    if (!event.postId || !event.authorId) return;
    if (event.action === "hide") return;

    const issues = event.issues ?? [];

    // O texto NÃO pode dizer que o post foi ocultado: aqui ele continua no ar.
    // E a única ação disponível ao autor no app hoje é excluir — não há edição
    // de legenda —, então é essa a instrução que vai junto.
    const content = hasSelfHarm(issues)
      ? SELF_HARM_SUPPORT
      : noticeFor(reasonsFor(issues));

    await insertNotification(
      "post_rejected",
      event.authorId,
      event.authorId,
      event.postId,
      content,
    );

    console.log(`[Kafka] Validation rejection notified for post ${event.postId}`);
  } catch (err) {
    console.error("[Kafka] Error handling post.validation.rejected event:", err);
  }
}

function noticeFor(reasons: string[]): string {
  const motivo = reasons.length > 0 ? `: ${reasons.join("; ")}` : "";
  return (
    `Sua publicação não segue as diretrizes da comunidade${motivo}. ` +
    "Você pode excluí-la pelo menu da publicação."
  );
}
