import { ValidationService } from "../../services/validation.service";
import { publishValidationRejected } from "../producer";
import type { ValidationInput, ValidationIssue } from "../../types/validation.types";
import type { ImageModerationService } from "../../moderation/image-moderation.service";
import type { ModerationAction } from "../../moderation/types";

/**
 * Envelope do post-service: `{ eventId, eventType, occurredAt, data }`. Payload
 * solto (formato antigo) continua aceito — mesma tolerância do `envelope.ts` do
 * notification-service.
 */
function unwrap<T>(raw: unknown): { eventType: string | null; data: T } {
    if (raw !== null && typeof raw === "object" && "data" in raw && "eventType" in raw) {
        const envelope = raw as { eventType: unknown; data: T };
        return {
            eventType: typeof envelope.eventType === "string" ? envelope.eventType : null,
            data: envelope.data,
        };
    }

    return { eventType: null, data: raw as T };
}

/**
 * O tópico `posts` carrega vários tipos. Só estes trazem texto escrito por
 * pessoa; `post.deleted` e `post.stats.updated` não têm o que validar.
 */
const HANDLED_EVENT_TYPES = new Set(["post.created", "post.content.updated"]);

/**
 * As duas mensagens não têm o mesmo formato — `post.created` manda `itemId` e
 * `content`, `post.content.updated` manda `postId` e `caption`. A divergência é
 * do post-service (ver `post.service.ts`); normalizar aqui é mais barato do que
 * mudar um contrato que outros consumidores já leem.
 */
interface PostContentEvent {
    itemId?: string;
    postId?: string;
    authorId?: string;
    content?: string | null;
    caption?: string | null;
    tags?: string[] | null;
    media?: unknown[] | null;
    imageUrls?: string[] | null;
}

export interface HandlerResult {
    /** `false` quando a mensagem não é para este handler ou está malformada. */
    processed: boolean;
    valid?: boolean;
    /** Presente quando uma rejeição foi publicada. */
    action?: "notify" | "hide";
}

export interface ImageModerationDeps {
    service: ImageModerationService;
    /** Modo efetivo (`env.image_moderation_effective.mode`), já sem o "off". */
    mode: "observe" | "enforce";
}

export interface HandlerDeps {
    /** Ausente quando a moderação de imagem está desligada. */
    imageModeration?: ImageModerationDeps;
    /** `heartbeat` do kafkajs, repassado para o processamento longo de imagem. */
    heartbeat?: () => Promise<void>;
}

/**
 * Revalida conteúdo que **já foi publicado**.
 *
 * Por que existe, já que a rota síncrona valida antes: a rota só protege quem a
 * chama. O post-service aceita `POST /posts` sem passar por aqui, então a única
 * checagem que alcança 100% dos posts é a que escuta o que foi criado. É também
 * o caminho que pega conteúdo que passou sob uma blocklist antiga e o que foi
 * editado depois de publicado.
 *
 * Contrato de falha, igual ao worker do interaction-service: **erro de parse
 * não lança** (devolve `processed: false`, o worker dá ack e segue — mensagem
 * envenenada não pode travar a partição), **falha de publicação lança** (o
 * Kafka reentrega). Reentrega pode gerar notificação duplicada; o consumidor
 * precisa tolerar isso.
 */
export async function handlePostContentEvent(
    raw: string,
    validationService: ValidationService,
    deps: HandlerDeps = {},
): Promise<HandlerResult> {
    let parsed: unknown;

    try {
        parsed = JSON.parse(raw);
    } catch {
        return { processed: false };
    }

    const { eventType, data } = unwrap<PostContentEvent>(parsed);

    if (eventType !== null && !HANDLED_EVENT_TYPES.has(eventType)) {
        return { processed: false };
    }

    if (data === null || typeof data !== "object") {
        return { processed: false };
    }

    const postId = data.itemId ?? data.postId;
    const authorId = data.authorId;

    if (!postId || !authorId) {
        return { processed: false };
    }

    const input: ValidationInput = {
        content: data.content ?? data.caption ?? "",
        tags: Array.isArray(data.tags) ? data.tags : [],
        // `post.content.updated` não carrega mídia — só a legenda nova. O post
        // existe e já passou pelo `media` obrigatório do post-service, então
        // assumir "tem mídia" é o que evita marcar como vazio toda edição que
        // apaga a legenda. `post.created` traz a contagem de verdade.
        mediaCount:
            data.media?.length ??
            data.imageUrls?.length ??
            (eventType === "post.content.updated" ? 1 : 0),
    };

    const result = await validationService.validate(input, {
        userId: authorId,
        source: "async",
        postId,
    });

    // Imagem só no post novo: `post.content.updated` troca a legenda e não
    // carrega mídia. Em `observe`, a moderação classifica, mede e audita, mas o
    // resultado não entra na decisão — é o modo de calibrar sem afetar ninguém.
    let imageIssues: ValidationIssue[] = [];
    let imageAction: ModerationAction = "allow";

    if (deps.imageModeration && eventType !== "post.content.updated") {
        const outcome = await deps.imageModeration.service.moderatePost({
            postId,
            authorId,
            data,
            heartbeat: deps.heartbeat,
        });

        if (deps.imageModeration.mode === "enforce") {
            imageIssues = outcome.issues;
            imageAction = outcome.action;
        }
    }

    const issues = [...result.issues, ...imageIssues];

    if (issues.length === 0) {
        return { processed: true, valid: true };
    }

    // Só imagem grave pede ocultação. Achado de texto continua sendo aviso: o
    // caminho síncrono já barra texto antes de publicar (POST_VALIDATION_MODE).
    const action = imageAction === "hide" ? "hide" : "notify";

    await publishValidationRejected({
        postId,
        authorId,
        action,
        issues: issues.map((issue) => ({
            code: issue.code,
            field: issue.field,
            ...(issue.mediaIndex !== undefined ? { mediaIndex: issue.mediaIndex } : {}),
        })),
        validatedAt: new Date().toISOString(),
    });

    return { processed: true, valid: false, action };
}
