import { randomUUID } from "crypto";
import { PostRepository } from "../repository/post.repository";
import { LikeRepository } from "../repository/like.repository";
import {
    CreatePostInput,
    Post,
    UpdatePostInput
} from "../types/post.types";
import { redis, cacheAside } from "../config/redis";
import { HttpError } from "../errors/http.error";
import { publishEvent, POSTS_TOPIC, POST_MODERATION_HIDDEN_TOPIC } from "../kafka/events";
import { decodeCursor } from "../utils/cursor";
import { toLegacyImageUrls } from "../utils/media";
import { cacheInvalidationFailureTotal, postsCreatedTotal } from "../metrics/registry";
import { env } from "../config/env";
import { ValidationClient, type ValidationOutcome } from "../clients/validation.client";

/**
 * Contexto da requisição HTTP que originou a operação. Separado de
 * `CreatePostInput`/`UpdatePostInput` de propósito: o header `Authorization`
 * é detalhe de transporte e não pertence ao tipo de domínio do post.
 *
 * Opcional para que chamador interno (o `AccountContentDeletionService`, e
 * qualquer teste existente) continue funcionando sem passar nada.
 */
export interface RequestContext {
    authorization?: string;
}

const GENERIC_REJECTION = "Conteúdo recusado pelas diretrizes da comunidade.";

/**
 * `message` do 422: os motivos, em texto pronto para a tela.
 *
 * O app exibe o `message` de qualquer 4xx (`apiErrorMessage` em
 * `apps/mobile/lib/service/api_error.dart`) e ignora campos extras. Com uma
 * frase genérica aqui, o autor ouvia "recusado" sem saber o que corrigir — e o
 * requisito é justamente a mensagem indicar o motivo. As mensagens vêm do
 * post-validation-service já em pt-BR e já genéricas quanto ao termo casado,
 * então podem ir direto.
 *
 * Resolver no servidor, e não no app, faz a correção valer para toda versão do
 * app já instalada, sem esperar publicação na loja. `issues` continua no corpo
 * para quem quiser tratar código a código.
 */
function rejectionMessage(issues: { message?: string }[]): string {
    const reasons = issues
        .map((issue) => issue.message?.trim())
        .filter((message): message is string => Boolean(message));

    return reasons.length > 0 ? reasons.join(" ") : GENERIC_REJECTION;
}

export class PostService {

    constructor(
        private readonly postRepository: PostRepository,
        private readonly likeRepository: LikeRepository,
        // Injetado com padrão para não quebrar quem já constrói o service com
        // dois argumentos (routes.ts e os testes existentes).
        private readonly validationClient: ValidationClient = new ValidationClient(),
    ) {}

    /**
     * Aplica o veredito do post-validation-service.
     *
     * **Indisponibilidade deixa passar, sempre.** Não é descuido, é a escolha
     * entre dois modos de falhar: barrar publicação quando o filtro está fora
     * do ar transformaria um serviço auxiliar em ponto único de falha do
     * Vibester inteiro — o oposto do que a raiz do monorepo pede ("evitar
     * pontos únicos de falha", "alta disponibilidade"). O que segura o outro
     * lado é o worker do post-validation-service, que revalida tudo que foi
     * publicado e notifica o autor: conteúdo que escapa durante uma queda é
     * pego depois, enquanto uma plataforma que não aceita post não tem
     * conserto retroativo.
     *
     * Quem quiser o comportamento oposto muda aqui, com os olhos abertos: é
     * uma decisão de produto, não uma constante de configuração.
     */
    private enforceValidation(outcome: ValidationOutcome): void {
        if (outcome.status !== "checked" || outcome.verdict.valid) { return; }

        if (env.post_validation_mode !== "block") { return; }

        throw new HttpError(
            rejectionMessage(outcome.verdict.issues),
            422,
            { issues: outcome.verdict.issues },
        );
    }

    async create(input: CreatePostInput, context: RequestContext = {}): Promise<Post> {
        // Antes de gerar id e de qualquer escrita: post recusado não deve
        // deixar rastro nem consumir contador.
        this.enforceValidation(await this.validationClient.validatePost({
            content: input.caption ?? "",
            tags: input.tags,
            mediaCount: input.media?.length ?? 0,
            authorization: context.authorization,
        }));

        const postId = randomUUID();

        const post: Post = {
            postId,
            userId: input.userId,
            userUsername: input.userUsername,
            userProfilePicture: input.userProfilePicture,
            userVerified: input.userVerified,
            establishmentId: input.establishmentId,
            establishmentName: input.establishmentName,
            establishmentLogo: input.establishmentLogo,
            establishmentCategory: input.establishmentCategory,
            media: input.media,
            imageUrls: toLegacyImageUrls(input.media),
            caption: input.caption,
            tags: input.tags,
            totalLikes: 0,
            totalComments: 0,
            isDeleted: false,
            createdAt: new Date(),
        };

        await this.postRepository.createInAllViews(post);
        postsCreatedTotal.inc();

        await this.invalidatePostCaches(post.userId, post.establishmentId, post.postId);

        await publishEvent(POSTS_TOPIC, post.postId, "post.created", {
            itemId: post.postId,
            itemType: post.establishmentId ? "ESTABLISHMENT_POST" : "USER_POST",
            authorId: post.userId,
            authorUsername: post.userUsername,
            authorProfilePicture: post.userProfilePicture,
            authorVerified: post.userVerified ?? false,
            establishmentId: post.establishmentId,
            establishmentName: post.establishmentName,
            establishmentLogo: post.establishmentLogo,
            establishmentCategory: post.establishmentCategory,
            content: post.caption,
            media: post.media,
            imageUrls: post.imageUrls,
            tags: post.tags,
            totalLikes: 0,
            totalComments: 0,
            isLiked: false,
            isSponsored: false,
            isDeleted: false,
            createdAt: post.createdAt.toISOString(),
        });

        return post;
    }

    async findById(postId: string) {
        return cacheAside(`post:id:${postId}`, 300, () =>
            this.postRepository.findById(postId)
        );
    }

    async findByUser(userId: string, limit = 50, rawCursor?: string, viewerId?: string) {
        const cursor = decodeCursor(rawCursor);
        const cacheKey = `post:user:${userId}:${limit}` + (rawCursor ? `:${rawCursor}` : "");
        const result = await cacheAside(cacheKey, 120, () =>
            this.postRepository.findByUser(userId, limit, cursor)
        );

        return { ...result, posts: await this.attachIsLiked(result.posts, viewerId) };
    }

    async findByEstablishment(establishmentId: string, limit = 50, rawCursor?: string, viewerId?: string) {
        const cursor = decodeCursor(rawCursor);
        const cacheKey = `post:establishment:${establishmentId}:${limit}` + (rawCursor ? `:${rawCursor}` : "");
        const result = await cacheAside(cacheKey, 120, () =>
            this.postRepository.findByEstablishment(establishmentId, limit, cursor)
        );

        return { ...result, posts: await this.attachIsLiked(result.posts, viewerId) };
    }

    // Feito fora do cacheAside de propósito: o cache de posts é por autor
    // (compartilhado entre todos os viewers), então isLiked precisa ser
    // calculado a cada request pro viewerId específico, nunca cacheado junto.
    private async attachIsLiked(posts: Post[], viewerId?: string): Promise<Post[]> {
        if (!viewerId || posts.length === 0) {
            return posts.map((post) => ({ ...post, isLiked: false }));
        }

        const likedPostIds = await this.likeRepository.findLikedPostIds(
            posts.map((post) => post.postId),
            viewerId
        );

        return posts.map((post) => ({ ...post, isLiked: likedPostIds.has(post.postId) }));
    }

    async updateCaption(
        input: UpdatePostInput,
        currentUserId: string,
        context: RequestContext = {},
    ): Promise<Post> {
        const post = await this.postRepository.findById(input.postId);

        if (!post) { throw new HttpError("Post not found", 404); }

        if (post.userId != currentUserId) { throw new HttpError("You cannot update this post.", 403); }

        if (post.isDeleted) { throw new HttpError("Post is deleted", 404); }

        // Depois da checagem de dono, não antes: quem nem pode editar o post
        // não deve descobrir nada sobre o filtro de conteúdo, e validar primeiro
        // gastaria uma chamada de rede para devolver 403 no fim.
        //
        // `mediaCount` vem da mídia já gravada — a edição só troca a legenda, e
        // sem isso apagar a legenda de um post com foto seria lido como post
        // vazio.
        this.enforceValidation(await this.validationClient.validatePost({
            content: input.caption,
            tags: post.tags,
            mediaCount: post.media?.length ?? 0,
            postId: input.postId,
            authorization: context.authorization,
        }));

        const updatedAt = new Date();

        await this.postRepository.updateCaptionInAllViews(post, input.caption, updatedAt);

        await this.invalidatePostCaches(post.userId, post.establishmentId, input.postId);

        await publishEvent(POSTS_TOPIC, input.postId, "post.content.updated", {
            authorId: post.userId,
            postId: input.postId,
            createdAt: post.createdAt.toISOString(),
            caption: input.caption,
        });

        return {
            ...post,
            caption: input.caption,
            updatedAt,
        };
    }

    /**
     * Oculta um post por decisão da moderação de imagem.
     *
     * Reaproveita o caminho do soft delete, e é isso que faz a ocultação chegar
     * a todo lugar sem código novo: `post.deleted` já tira o post das timelines
     * (feed-service) e desconta o contador do perfil (user-service). A linha
     * continua no Cassandra marcada `is_deleted`, então restaurar depois (numa
     * contestação) é possível.
     *
     * Diferente de `softDelete`: **sem checagem de dono** (quem pede é o
     * sistema, não uma pessoa) e **idempotente** — post já apagado ou
     * inexistente não é erro. O Kafka reentrega mensagens; lançar aqui criaria
     * retry infinito para um post que o próprio autor já apagou.
     *
     * Só depois de ocultar publica `post.moderation.hidden`, que é de onde o
     * notification-service tira o aviso "sua publicação foi removida".
     */
    async hideForModeration(
        postId: string,
        issues: { code: string; field?: string; mediaIndex?: number }[],
    ): Promise<"hidden" | "already_deleted" | "not_found"> {
        const post = await this.postRepository.findById(postId);

        if (!post) { return "not_found"; }
        if (post.isDeleted) { return "already_deleted"; }

        await this.postRepository.softDeleteInAllViews(post);

        await this.invalidatePostCaches(post.userId, post.establishmentId, postId);

        await publishEvent(POSTS_TOPIC, postId, "post.deleted", {
            authorId: post.userId,
            postId,
            createdAt: post.createdAt.toISOString(),
        });

        await publishEvent(POST_MODERATION_HIDDEN_TOPIC, postId, "post.moderation.hidden", {
            postId,
            authorId: post.userId,
            issues,
            hiddenAt: new Date().toISOString(),
        });

        return "hidden";
    }

    async softDelete(postId: string, currentUserId: string) {
        const post = await this.postRepository.findById(postId);

        if (!post) { throw new HttpError("Post not found", 404); }

        if (post.userId != currentUserId) { throw new HttpError("You cannot delete this post.", 403); }

        // Sem isso, apagar de novo republica post.deleted e desconta o post
        // duas vezes no contador do perfil (user-service).
        if (post.isDeleted) { throw new HttpError("Post not found", 404); }

        await this.postRepository.softDeleteInAllViews(post);

        await this.invalidatePostCaches(post.userId, post.establishmentId, postId);

        await publishEvent(POSTS_TOPIC, postId, "post.deleted", {
            authorId: post.userId,
            postId,
            createdAt: post.createdAt.toISOString(),
        });
    }

    private async invalidatePostCaches(userId: string, establishmentId: string | undefined, postId: string) {
        const keys = [
            `post:id:${postId}`,
            `post:user:${userId}:50`,
            `post:user:${userId}:100`,
        ];
        if (establishmentId) {
            keys.push(`post:establishment:${establishmentId}:50`);
            keys.push(`post:establishment:${establishmentId}:100`);
        }
        try {
            await redis.del(...keys);
        } catch (err) {
            cacheInvalidationFailureTotal.inc();
            const msg = err instanceof Error ? err.message : String(err);
            console.error(JSON.stringify({ level: "warn", service: "post-service", op: "cache-invalidate", msg }));
        }
    }
}
