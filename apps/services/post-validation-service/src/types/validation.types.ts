/**
 * Código da rejeição. É o contrato público do serviço: o cliente decide a
 * mensagem que mostra ao usuário a partir daqui, não do texto em `message`.
 *
 * Nenhum código revela QUAL termo/domínio casou — isso vai só para o log de
 * auditoria. Devolver "a palavra X é proibida" entrega a blocklist inteira a
 * quem sondar o endpoint em loop, e é exatamente o que o requisito de segurança
 * ("mensagens de erro não devem expor detalhes da implementação") impede.
 */
export enum ValidationCode {
    CONTENT_EMPTY = "CONTENT_EMPTY",
    CONTENT_TOO_LONG = "CONTENT_TOO_LONG",
    FORBIDDEN_LANGUAGE = "FORBIDDEN_LANGUAGE",
    HATE_SPEECH = "HATE_SPEECH",
    MALFORMED_LINK = "MALFORMED_LINK",
    BLOCKED_LINK = "BLOCKED_LINK",
    SHORTENED_LINK = "SHORTENED_LINK",
    TOO_MANY_LINKS = "TOO_MANY_LINKS",
    SPAM_SUSPECTED = "SPAM_SUSPECTED",
    TOO_MANY_TAGS = "TOO_MANY_TAGS",

    // Imagem (só no caminho assíncrono — ver src/moderation/). A rota síncrona
    // nunca vê mídia, então estes códigos só aparecem em post.validation.rejected.
    IMAGE_SEXUAL = "IMAGE_SEXUAL",
    IMAGE_GRAPHIC_VIOLENCE = "IMAGE_GRAPHIC_VIOLENCE",
    IMAGE_VIOLENCE = "IMAGE_VIOLENCE",
    IMAGE_SELF_HARM = "IMAGE_SELF_HARM",
}

export interface ValidationIssue {
    code: ValidationCode;
    /** Campo que motivou a rejeição: legenda, tags ou uma das mídias do post. */
    field: "content" | "tags" | "media";
    /** Mensagem pronta para exibição, em pt-BR. Genérica por design. */
    message: string;
    /** Só quando `field` é `media`: posição da mídia no post (0 = primeira). */
    mediaIndex?: number;
}

/**
 * Detalhe que NUNCA sai na resposta HTTP — só no log de auditoria e nas
 * métricas. Separar os dois tipos é o que impede um `...issue` distraído de
 * vazar o termo casado para o cliente.
 */
export interface AuditDetail {
    code: ValidationCode;
    /** Ex.: o termo da blocklist que casou, ou o domínio bloqueado. */
    matched: string;
}

export interface RuleResult {
    issues: ValidationIssue[];
    auditDetails: AuditDetail[];
}

export interface ValidationInput {
    content: string;
    tags: string[];
    /**
     * Quantidade de mídias do post. Não é validada aqui (o post-service já
     * limita a 10 e confere o dono da URL) — serve para uma coisa só: decidir
     * se legenda vazia é post vazio. Post só de foto é legítimo no Vibester,
     * post sem nada nenhum não é.
     */
    mediaCount: number;
}

export interface ValidationVerdict {
    valid: boolean;
    issues: ValidationIssue[];
}

/** O que é gravado no cache do Redis. Ver `contentHash` em src/utils/content-hash.ts. */
export interface CachedVerdict extends ValidationVerdict {
    /** Auditoria continua acontecendo no hit; o detalhe vem junto para não se perder. */
    auditDetails: AuditDetail[];
}

export interface ValidationResponse extends ValidationVerdict {
    contentHash: string;
    cached: boolean;
}

/** Uma regra é uma função pura: mesmo texto, mesmo veredito, sem I/O. */
export type Rule = (input: ValidationInput) => RuleResult;

export const EMPTY_RULE_RESULT: RuleResult = { issues: [], auditDetails: [] };
