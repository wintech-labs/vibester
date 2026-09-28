/** Score por categoria, de 0 a 1 (quanto maior, mais confiança de violação). */
export type CategoryScores = Record<string, number>;

/**
 * Quem classifica uma imagem. Hoje só existe a implementação da OpenAI
 * (`openai.moderator.ts`); trocar de provedor é escrever outra classe que
 * cumpra este contrato — a política, o cache e o handler não mudam.
 */
export interface ImageModerator {
    /**
     * Classifica UMA imagem pela URL pública. Uma por chamada, de propósito:
     * a API da OpenAI devolve um resultado combinado quando recebe várias
     * entradas, e aí não daria para saber qual das fotos foi reprovada.
     *
     * Lança `ModerationError` em falha.
     */
    classify(imageUrl: string): Promise<CategoryScores>;
}

export class ModerationError extends Error {
    constructor(
        message: string,
        /** Vale tentar de novo? 429, 5xx, timeout e rede sim; 4xx de requisição não. */
        public readonly retryable: boolean,
        /** Quanto esperar antes da próxima tentativa, quando o provedor disse (429). */
        public readonly retryAfterMs?: number,
    ) {
        super(message);
        this.name = "ModerationError";
    }
}

/**
 * O que fazer com o post, em ordem crescente de gravidade:
 * - allow:  nada.
 * - notify: avisar o autor, o post continua no ar.
 * - hide:   o post-service oculta o post (ver "Moderação de imagem" no CLAUDE.md).
 */
export type ModerationAction = "allow" | "notify" | "hide";

export const ACTION_SEVERITY: Record<ModerationAction, number> = { allow: 0, notify: 1, hide: 2 };

export function mostSevere(actions: ModerationAction[]): ModerationAction {
    return actions.reduce<ModerationAction>(
        (current, next) => (ACTION_SEVERITY[next] > ACTION_SEVERITY[current] ? next : current),
        "allow",
    );
}
