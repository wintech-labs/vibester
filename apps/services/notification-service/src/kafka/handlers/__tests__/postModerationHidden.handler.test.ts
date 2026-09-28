import { describe, it, expect, vi, beforeEach } from "vitest";
import { handlePostModerationHiddenEvent } from "../postModerationHidden.handler";

const { mockInsertNotification } = vi.hoisted(() => ({
    mockInsertNotification: vi.fn(),
}));

vi.mock("../../../services/insertNotification.service", () => ({
    insertNotification: mockInsertNotification,
}));

function envelope(data: unknown): string {
    return JSON.stringify({
        eventId: "evt-1",
        eventType: "post.moderation.hidden",
        occurredAt: "2026-09-28T12:00:00.000Z",
        data,
    });
}

describe("handlePostModerationHiddenEvent", () => {
    beforeEach(() => {
        vi.clearAllMocks();
        mockInsertNotification.mockResolvedValue(undefined);
    });

    /**
     * O post-service só publica este evento depois de ocultar o post de fato —
     * é o único lugar onde a mensagem pode dizer "foi removida".
     */
    it("tells the author the post was removed, and why", async () => {
        await handlePostModerationHiddenEvent(
            envelope({
                postId: "post-1",
                authorId: "author-1",
                issues: [{ code: "IMAGE_SEXUAL", field: "media", mediaIndex: 0 }],
                hiddenAt: "2026-09-28T12:00:00.000Z",
            }),
        );

        expect(mockInsertNotification).toHaveBeenCalledWith(
            "post_rejected",
            "author-1",
            "author-1",
            "post-1",
            "Sua publicação foi removida porque uma das imagens parece conter conteúdo sexual.",
        );
    });

    it("falls back to a generic removal message for unknown codes", async () => {
        await handlePostModerationHiddenEvent(
            envelope({ postId: "post-2", authorId: "author-2", issues: [{ code: "CODIGO_NOVO" }] }),
        );

        expect(String(mockInsertNotification.mock.calls[0][4])).toBe(
            "Sua publicação foi removida por não seguir as diretrizes da comunidade.",
        );
    });

    it("adds the support message when self-harm was among the reasons", async () => {
        await handlePostModerationHiddenEvent(
            envelope({
                postId: "post-3",
                authorId: "author-3",
                issues: [
                    { code: "IMAGE_GRAPHIC_VIOLENCE", field: "media", mediaIndex: 0 },
                    { code: "IMAGE_SELF_HARM", field: "media", mediaIndex: 1 },
                ],
            }),
        );

        const content = String(mockInsertNotification.mock.calls[0][4]);
        expect(content).toContain("foi removida porque uma das imagens parece conter violência explícita");
        expect(content).toContain("188");
    });

    it.each([
        ["invalid json", "{ not json"],
        ["missing postId", JSON.stringify({ authorId: "a", issues: [] })],
        ["missing authorId", JSON.stringify({ postId: "p", issues: [] })],
    ])("ignores %s without throwing", async (_label, raw) => {
        await expect(handlePostModerationHiddenEvent(raw)).resolves.toBeUndefined();
        expect(mockInsertNotification).not.toHaveBeenCalled();
    });
});
