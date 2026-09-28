export interface ModerationIssue {
  code: string;
  field?: string;
  mediaIndex?: number;
}

/**
 * Mensagem por motivo. Os eventos carregam só o código — o
 * post-validation-service nunca manda o termo casado nem o score, para a
 * notificação não virar oráculo do filtro. Aqui o código vira texto para o
 * usuário, em minúscula para compor uma frase.
 *
 * `IMAGE_SELF_HARM` não está aqui de propósito: ver `SELF_HARM_SUPPORT`.
 */
const MESSAGE_BY_CODE: Record<string, string> = {
  CONTENT_EMPTY: "a publicação está sem texto e sem mídia",
  CONTENT_TOO_LONG: "o texto excede o limite de caracteres",
  FORBIDDEN_LANGUAGE: "o texto contém linguagem imprópria",
  HATE_SPEECH: "o conteúdo viola as diretrizes da comunidade",
  MALFORMED_LINK: "há um link em formato inválido",
  BLOCKED_LINK: "há um link que não pode ser compartilhado",
  SHORTENED_LINK: "links encurtados não são permitidos",
  TOO_MANY_LINKS: "há links demais na publicação",
  SPAM_SUSPECTED: "a publicação foi identificada como spam",
  TOO_MANY_TAGS: "há tags demais na publicação",
  IMAGE_SEXUAL: "uma das imagens parece conter conteúdo sexual",
  IMAGE_GRAPHIC_VIOLENCE: "uma das imagens parece conter violência explícita",
  IMAGE_VIOLENCE: "uma das imagens parece conter violência",
};

/**
 * Automutilação não é tratada como infração. Quem posta uma imagem assim pode
 * estar em crise, e "sua publicação viola as diretrizes" é a pior resposta
 * possível para essa pessoa. A mensagem substitui qualquer outro motivo e
 * aponta ajuda: o CVV atende 24h, de graça, pelo 188.
 */
export const SELF_HARM_SUPPORT =
  "Percebemos que uma imagem da sua publicação pode tratar de automutilação. " +
  "Se você estiver passando por um momento difícil, não precisa enfrentar isso sozinho: " +
  "o CVV atende 24h, de graça, pelo telefone 188 ou em cvv.org.br.";

export function hasSelfHarm(issues: ModerationIssue[]): boolean {
  return issues.some((issue) => issue.code === "IMAGE_SELF_HARM");
}

/**
 * Motivos em texto, sem repetir: várias fotos com o mesmo problema viram um
 * motivo só. Código desconhecido é ignorado (quem chama cai numa frase
 * genérica) — um código novo no validador não pode quebrar a notificação.
 */
export function reasonsFor(issues: ModerationIssue[]): string[] {
  const seen = new Set<string>();
  const reasons: string[] = [];

  for (const issue of issues) {
    const reason = MESSAGE_BY_CODE[issue.code];
    if (reason && !seen.has(reason)) {
      seen.add(reason);
      reasons.push(reason);
    }
  }

  return reasons;
}
