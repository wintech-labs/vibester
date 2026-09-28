/** Uma mídia a classificar: a URL da imagem e a posição da mídia no post. */
export interface ModerationTarget {
    /** Posição no array `media` do post (0 = primeira). Vai no evento como `mediaIndex`. */
    mediaIndex: number;
    url: string;
}

export type SkipReason = "foreign_url" | "video_without_cover" | "over_limit";

export interface CollectedMedia {
    targets: ModerationTarget[];
    skipped: { mediaIndex: number; reason: SkipReason }[];
}

/** Mesmo teto do post-service (`MAX_MEDIA_PER_POST`) e do composer do app. */
export const MAX_MEDIA_PER_POST = 10;

interface RawMediaItem {
    url?: unknown;
    type?: unknown;
    thumbnailUrl?: unknown;
}

/**
 * Escolhe o que classificar a partir do `post.created`.
 *
 * - Foto: a própria imagem.
 * - Vídeo: só a **capa** (`thumbnailUrl`, gerada no aparelho). A API da OpenAI
 *   não aceita vídeo; classificar o vídeo inteiro exigiria extrair quadros com
 *   ffmpeg no worker. Vídeo com conteúdo impróprio no meio e capa inofensiva
 *   passa — limite conhecido, documentado no CLAUDE.md.
 * - Formato legado (`imageUrls`, só fotos): usado quando não há `media`.
 *
 * Só entra URL que começa pelo endereço público do bucket. O post-service já
 * exige isso no `createPostSchema`, então aqui é defesa em profundidade: o
 * serviço não deve mandar para um terceiro uma URL que não seja nossa.
 */
export function collectModerationTargets(
    data: { media?: unknown; imageUrls?: unknown },
    mediaPublicUrl: string,
): CollectedMedia {
    const allowedPrefix = `${mediaPublicUrl}/`;
    const targets: ModerationTarget[] = [];
    const skipped: CollectedMedia["skipped"] = [];

    const items: RawMediaItem[] = Array.isArray(data.media) && data.media.length > 0
        ? (data.media as RawMediaItem[])
        : Array.isArray(data.imageUrls)
            ? (data.imageUrls as unknown[]).map((url) => ({ url, type: "IMAGE" }))
            : [];

    items.forEach((item, mediaIndex) => {
        if (mediaIndex >= MAX_MEDIA_PER_POST) {
            skipped.push({ mediaIndex, reason: "over_limit" });
            return;
        }

        const isVideo = typeof item?.type === "string" && item.type.toUpperCase() === "VIDEO";
        const url = isVideo ? item.thumbnailUrl : item?.url;

        if (typeof url !== "string" || url.length === 0) {
            if (isVideo) { skipped.push({ mediaIndex, reason: "video_without_cover" }); }
            return;
        }

        if (!url.startsWith(allowedPrefix)) {
            skipped.push({ mediaIndex, reason: "foreign_url" });
            return;
        }

        targets.push({ mediaIndex, url });
    });

    return { targets, skipped };
}
