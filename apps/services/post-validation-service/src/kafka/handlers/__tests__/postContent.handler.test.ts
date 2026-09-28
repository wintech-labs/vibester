import { describe, it, expect, vi, beforeEach } from "vitest";
import { handlePostContentEvent } from "../postContent.handler";
import { ValidationCode } from "../../../types/validation.types";
import type { ValidationService } from "../../../services/validation.service";

vi.mock("../../producer", () => ({
    publishValidationRejected: vi.fn(async () => undefined),
}));

const { publishValidationRejected } = await import("../../producer");
const publishMock = vi.mocked(publishValidationRejected);

function serviceReturning(valid: boolean): ValidationService {
    return {
        validate: vi.fn(async () => ({
            valid,
            issues: valid
                ? []
                : [{
                    code: ValidationCode.HATE_SPEECH,
                    field: "content" as const,
                    message: "reprovado",
                }],
            contentHash: "hash",
            cached: false,
        })),
    } as unknown as ValidationService;
}

function envelope(eventType: string, data: unknown): string {
    return JSON.stringify({
        eventId: "evt-1",
        eventType,
        occurredAt: new Date().toISOString(),
        data,
    });
}

describe("handlePostContentEvent", () => {
    beforeEach(() => {
        publishMock.mockReset().mockResolvedValue(undefined);
    });

    it("valida post.created e nao publica nada quando aprova", async () => {
        const result = await handlePostContentEvent(
            envelope("post.created", {
                itemId: "post-1",
                authorId: "autor-1",
                content: "festa hoje",
                media: [{ url: "x" }],
            }),
            serviceReturning(true)
        );

        expect(result).toEqual({ processed: true, valid: true });
        expect(publishMock).not.toHaveBeenCalled();
    });

    it("publica a rejeicao quando reprova", async () => {
        const result = await handlePostContentEvent(
            envelope("post.created", {
                itemId: "post-1",
                authorId: "autor-1",
                content: "conteudo reprovado",
                media: [{ url: "x" }],
            }),
            serviceReturning(false)
        );

        expect(result).toEqual({ processed: true, valid: false, action: "notify" });
        expect(publishMock).toHaveBeenCalledTimes(1);

        const published = publishMock.mock.calls[0][0];
        expect(published.postId).toBe("post-1");
        expect(published.authorId).toBe("autor-1");
        expect(published.issues).toEqual([
            { code: ValidationCode.HATE_SPEECH, field: "content" },
        ]);
    });

    /**
     * Os dois eventos do post-service não têm o mesmo formato: `post.created`
     * manda `itemId`/`content`, `post.content.updated` manda `postId`/`caption`.
     */
    it("entende o formato diferente de post.content.updated", async () => {
        const service = serviceReturning(true);

        await handlePostContentEvent(
            envelope("post.content.updated", {
                postId: "post-2",
                authorId: "autor-2",
                caption: "legenda nova",
            }),
            service
        );

        expect(service.validate).toHaveBeenCalledWith(
            expect.objectContaining({ content: "legenda nova" }),
            expect.objectContaining({ postId: "post-2", source: "async" })
        );
    });

    /**
     * Edição que apaga a legenda não é post vazio: o post existe e já tem mídia.
     * Sem esta suposição, toda remoção de legenda viraria CONTENT_EMPTY.
     */
    it("assume que post editado tem midia, mesmo sem o campo no evento", async () => {
        const service = serviceReturning(true);

        await handlePostContentEvent(
            envelope("post.content.updated", {
                postId: "post-3",
                authorId: "autor-3",
                caption: "",
            }),
            service
        );

        expect(service.validate).toHaveBeenCalledWith(
            expect.objectContaining({ mediaCount: 1 }),
            expect.anything()
        );
    });

    it("conta a midia real em post.created", async () => {
        const service = serviceReturning(true);

        await handlePostContentEvent(
            envelope("post.created", {
                itemId: "post-4",
                authorId: "autor-4",
                content: "festa",
                media: [{ url: "a" }, { url: "b" }],
            }),
            service
        );

        expect(service.validate).toHaveBeenCalledWith(
            expect.objectContaining({ mediaCount: 2 }),
            expect.anything()
        );
    });

    it("ignora evento do topico que nao tem texto para validar", async () => {
        const service = serviceReturning(false);

        const result = await handlePostContentEvent(
            envelope("post.deleted", { itemId: "post-5", authorId: "autor-5" }),
            service
        );

        expect(result.processed).toBe(false);
        expect(service.validate).not.toHaveBeenCalled();
    });

    /**
     * Contrato de falha: mensagem malformada não pode travar a partição. O
     * handler devolve `processed: false` e o worker dá ack.
     */
    it.each([
        ["json invalido", "{ nao e json"],
        ["envelope sem postId", JSON.stringify({ eventType: "post.created", data: { authorId: "a" } })],
        ["envelope sem authorId", JSON.stringify({ eventType: "post.created", data: { itemId: "p" } })],
        ["data nulo", JSON.stringify({ eventType: "post.created", data: null })],
    ])("nao lanca com %s", async (_label, raw) => {
        await expect(handlePostContentEvent(raw, serviceReturning(false))).resolves.toEqual({
            processed: false,
        });
    });

    /**
     * Já falha de publicação PROPAGA: o Kafka reentrega, e a alternativa seria
     * perder a notificação em silêncio.
     */
    it("propaga falha de publicacao para o kafka reentregar", async () => {
        publishMock.mockRejectedValue(new Error("broker fora do ar"));

        await expect(
            handlePostContentEvent(
                envelope("post.created", {
                    itemId: "post-6",
                    authorId: "autor-6",
                    content: "reprovado",
                    media: [{ url: "x" }],
                }),
                serviceReturning(false)
            )
        ).rejects.toThrow("broker fora do ar");
    });

    it("aceita payload solto, sem envelope (formato antigo)", async () => {
        const service = serviceReturning(true);

        const result = await handlePostContentEvent(
            JSON.stringify({ itemId: "post-7", authorId: "autor-7", content: "festa" }),
            service
        );

        expect(result.processed).toBe(true);
    });
});

describe("handlePostContentEvent — moderação de imagem", () => {
    const media = [{ url: "https://media.test/posts/autor/a.jpg", type: "IMAGE" }];

    function imageServiceReturning(outcome: {
        action: "allow" | "notify" | "hide";
        issues: { code: ValidationCode; field: "media"; message: string; mediaIndex: number }[];
    }) {
        return {
            moderatePost: vi.fn(async () => ({ ...outcome, classified: 1, failed: 0, skipped: 0 })),
        };
    }

    const HIDE = {
        action: "hide" as const,
        issues: [{ code: ValidationCode.IMAGE_SEXUAL, field: "media" as const, message: "x", mediaIndex: 0 }],
    };

    beforeEach(() => {
        publishMock.mockReset().mockResolvedValue(undefined);
    });

    it("em enforce, publica ocultacao quando a imagem e grave", async () => {
        const image = imageServiceReturning(HIDE);

        const result = await handlePostContentEvent(
            envelope("post.created", { itemId: "post-1", authorId: "autor-1", content: "festa", media }),
            serviceReturning(true),
            { imageModeration: { service: image as never, mode: "enforce" } },
        );

        expect(result).toEqual({ processed: true, valid: false, action: "hide" });
        expect(publishMock.mock.calls[0][0]).toMatchObject({
            postId: "post-1",
            action: "hide",
            issues: [{ code: ValidationCode.IMAGE_SEXUAL, field: "media", mediaIndex: 0 }],
        });
    });

    /**
     * `observe` é o modo de calibragem: classifica em posts reais, mas nenhum
     * autor é avisado e nenhum post é ocultado.
     */
    it("em observe, classifica mas nao publica nada", async () => {
        const image = imageServiceReturning(HIDE);

        const result = await handlePostContentEvent(
            envelope("post.created", { itemId: "post-1", authorId: "autor-1", content: "festa", media }),
            serviceReturning(true),
            { imageModeration: { service: image as never, mode: "observe" } },
        );

        expect(image.moderatePost).toHaveBeenCalledTimes(1);
        expect(result).toEqual({ processed: true, valid: true });
        expect(publishMock).not.toHaveBeenCalled();
    });

    it("junta achado de texto e de imagem numa rejeicao so, com a acao mais grave", async () => {
        const image = imageServiceReturning(HIDE);

        await handlePostContentEvent(
            envelope("post.created", { itemId: "post-1", authorId: "autor-1", content: "ruim", media }),
            serviceReturning(false),
            { imageModeration: { service: image as never, mode: "enforce" } },
        );

        const published = publishMock.mock.calls[0][0];
        expect(published.action).toBe("hide");
        expect(published.issues.map((i: { code: string }) => i.code)).toEqual([
            ValidationCode.HATE_SPEECH,
            ValidationCode.IMAGE_SEXUAL,
        ]);
    });

    /** Texto nunca pede ocultação: o caminho síncrono já barra texto antes de publicar. */
    it("achado so de texto continua sendo aviso", async () => {
        const image = imageServiceReturning({ action: "allow", issues: [] });

        await handlePostContentEvent(
            envelope("post.created", { itemId: "post-1", authorId: "autor-1", content: "ruim", media }),
            serviceReturning(false),
            { imageModeration: { service: image as never, mode: "enforce" } },
        );

        expect(publishMock.mock.calls[0][0].action).toBe("notify");
    });

    it("nao classifica imagem em post.content.updated (so a legenda mudou)", async () => {
        const image = imageServiceReturning(HIDE);

        await handlePostContentEvent(
            envelope("post.content.updated", { postId: "post-2", authorId: "autor-2", caption: "nova" }),
            serviceReturning(true),
            { imageModeration: { service: image as never, mode: "enforce" } },
        );

        expect(image.moderatePost).not.toHaveBeenCalled();
    });

    it("repassa o heartbeat do Kafka para a moderacao", async () => {
        const image = imageServiceReturning({ action: "allow", issues: [] });
        const heartbeat = vi.fn(async () => undefined);

        await handlePostContentEvent(
            envelope("post.created", { itemId: "post-1", authorId: "autor-1", content: "festa", media }),
            serviceReturning(true),
            { imageModeration: { service: image as never, mode: "enforce" }, heartbeat },
        );

        expect(image.moderatePost).toHaveBeenCalledWith(expect.objectContaining({ heartbeat }));
    });

    it("sem moderacao configurada, o comportamento de texto nao muda", async () => {
        const result = await handlePostContentEvent(
            envelope("post.created", { itemId: "post-1", authorId: "autor-1", content: "ruim", media }),
            serviceReturning(false),
        );

        expect(result).toEqual({ processed: true, valid: false, action: "notify" });
    });
});
