import type { AuditDetail, ValidationIssue } from "../types/validation.types";

export interface AuditEntry {
    /** `sync` = rota HTTP; `async` = worker do Kafka. */
    source: "sync" | "async";
    /** `accountId` do token (sync) ou `authorId` do evento (async). */
    userId: string;
    /** Presente só no caminho assíncrono: o post já existe quando é revalidado. */
    postId?: string;
    contentHash: string;
    contentLength: number;
    valid: boolean;
    issues: ValidationIssue[];
    auditDetails: AuditDetail[];
    durationMs: number;
    cached: boolean;
}

/**
 * Trilha de auditoria de toda validação.
 *
 * Sai como uma linha JSON no stdout, no mesmo formato estruturado que o resto
 * do monorepo usa (Pino/console JSON), marcada com `audit: "post-validation"`
 * para ser filtrável.
 *
 * **Retenção: hoje não há nenhuma.** O cluster não tem coleta de logs (nem
 * Loki/Promtail, nem equivalente em `apps/services/monitoring` ou `k8s/`), então
 * esta linha vive só no stdout do pod: `kubectl logs` alcança o container atual
 * e o anterior, e a rotação do kubelet apaga o resto. Um pod reiniciado leva a
 * trilha junto. O formato já está pronto para qualquer coletor — o que falta é
 * o coletor, que é decisão de infraestrutura do cluster inteiro, não deste
 * serviço. Ver "Auditoria" no CLAUDE.md.
 *
 * **Por que log e não tabela.** O requisito é auditoria e monitoramento, e as
 * duas coisas são atendidas por log estruturado + as métricas de
 * `metrics/registry.ts`. Uma tabela significaria uma escrita no caminho
 * síncrono de uma rota com orçamento de 200ms, mais um banco para operar, mais
 * uma dependência capaz de derrubar o `/ready` — tudo isso para um dado que
 * ninguém consulta por chave primária. Se um dia aparecer a necessidade de
 * *consultar* a trilha (ex.: "mostre todas as rejeições deste usuário"), aí sim
 * vira tabela, e o caminho é o worker gravar, nunca a API.
 *
 * **O conteúdo do post não é logado.** Só o hash e o tamanho. A legenda é dado
 * pessoal do usuário, e derramá-la em log de aplicação a espalharia por toda a
 * retenção da coleta, inclusive a de posts que nunca foram publicados. Para
 * entender POR QUE algo foi rejeitado, `auditDetails` já traz o termo/domínio
 * que casou, que é o que a moderação precisa — sem carregar o texto junto.
 */
export function recordAudit(entry: AuditEntry): void {
    console.log(JSON.stringify({
        level: "info",
        audit: "post-validation",
        service: "post-validation-service",
        source: entry.source,
        userId: entry.userId,
        postId: entry.postId,
        contentHash: entry.contentHash,
        contentLength: entry.contentLength,
        valid: entry.valid,
        cached: entry.cached,
        durationMs: entry.durationMs,
        codes: entry.issues.map((issue) => issue.code),
        matched: entry.auditDetails.map((detail) => `${detail.code}:${detail.matched}`),
        at: new Date().toISOString(),
    }));
}

export interface ImageAuditEntry {
    postId: string;
    authorId: string;
    mediaIndex: number;
    /**
     * A URL entra no log, ao contrário da legenda: é o que a moderação precisa
     * para abrir a imagem e conferir a decisão, e não é texto escrito pela
     * pessoa (é `posts/<id do autor>/<uuid>.jpg`, de um post público).
     */
    url: string;
    mode: "observe" | "enforce";
    action: "allow" | "notify" | "hide" | "error";
    /** Categorias com score relevante, arredondadas — o suficiente para recalibrar. */
    scores?: Record<string, number>;
    findings?: string[];
    cached: boolean;
    durationMs: number;
    error?: string;
}

/**
 * Trilha de auditoria da moderação de imagem — uma linha por imagem. Mesma
 * ressalva de retenção de `recordAudit`: sem coletor de logs no cluster, a
 * linha vive só no stdout do pod.
 */
export function recordImageAudit(entry: ImageAuditEntry): void {
    console.log(JSON.stringify({
        level: entry.action === "error" ? "warn" : "info",
        audit: "post-validation-image",
        service: "post-validation-service",
        ...entry,
        at: new Date().toISOString(),
    }));
}

