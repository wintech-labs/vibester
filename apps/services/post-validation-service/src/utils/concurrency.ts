/**
 * Executa `task` sobre `items` com no máximo `limit` execuções simultâneas.
 *
 * Cópia do utilitário do interaction-service (`src/utils/concurrency.ts`).
 * Aqui limita as chamadas à API de moderação por post: um post pode ter até 10
 * mídias, e disparar todas de uma vez gastaria o limite por minuto da API num
 * post só.
 *
 * Falha rápido: se uma task rejeitar, a rejeição propaga.
 */
export async function runWithConcurrency<T, R>(
    items: readonly T[],
    limit: number,
    task: (item: T, index: number) => Promise<R>
): Promise<R[]> {
    if (items.length === 0) {
        return [];
    }

    const effectiveLimit = Math.max(1, Math.min(limit, items.length));
    const results = new Array<R>(items.length);
    let cursor = 0;

    const workers = Array.from({ length: effectiveLimit }, async () => {
        while (true) {
            const index = cursor++;

            if (index >= items.length) {
                return;
            }

            results[index] = await task(items[index]!, index);
        }
    });

    await Promise.all(workers);

    return results;
}
