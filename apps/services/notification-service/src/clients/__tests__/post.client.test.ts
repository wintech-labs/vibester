import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { PostClient } from "../post.client";

describe("PostClient.getPost", () => {
    let client: PostClient;

    beforeEach(() => {
        client = new PostClient();
        vi.stubGlobal("fetch", vi.fn());
    });

    afterEach(() => {
        vi.unstubAllGlobals();
        vi.useRealTimers();
    });

    it("returns a mapped PostSummary when the response is 200 and ok", async () => {
        (global.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
            ok: true,
            json: async () => ({
                postId: "post-1",
                imageUrls: ["https://cdn/img1.jpg", "https://cdn/img2.jpg"],
                caption: "Nice day",
                isDeleted: false,
            }),
        });

        const result = await client.getPost("post-1");

        expect(result).toEqual({
            postId: "post-1",
            imageUrl: "https://cdn/img1.jpg",
            caption: "Nice day",
            isDeleted: false,
        });
    });

    it("uses '' as imageUrl when imageUrls is empty/absent", async () => {
        (global.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
            ok: true,
            json: async () => ({ postId: "post-1", imageUrls: [], caption: "x", isDeleted: false }),
        });

        const result = await client.getPost("post-1");

        expect(result?.imageUrl).toBe("");
    });

    it("marks isDeleted=true and forces caption='Publicação removida' when the post is deleted", async () => {
        (global.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
            ok: true,
            json: async () => ({ postId: "post-1", imageUrls: [], caption: "original caption", isDeleted: true }),
        });

        const result = await client.getPost("post-1");

        expect(result?.isDeleted).toBe(true);
        expect(result?.caption).toBe("Publicação removida");
    });

    /**
     * Quando quem apagou foi a moderação de imagem, a foto é o que foi
     * removido. Devolver a URL faria ela voltar como miniatura em toda
     * notificação daquele post, inclusive nas curtidas antigas.
     */
    it("does not return the image of a deleted post", async () => {
        (global.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({
            ok: true,
            json: async () => ({ postId: "post-1", imageUrls: ["https://cdn/removida.jpg"], caption: "x", isDeleted: true }),
        });

        const result = await client.getPost("post-1");

        expect(result?.imageUrl).toBe("");
        expect(result?.isDeleted).toBe(true);
    });

    it("returns null when response.ok is false", async () => {
        (global.fetch as ReturnType<typeof vi.fn>).mockResolvedValue({ ok: false });

        const result = await client.getPost("post-1");

        expect(result).toBeNull();
    });

    it("returns null and does not throw when the request exceeds the timeout", async () => {
        (global.fetch as ReturnType<typeof vi.fn>).mockImplementation(
            (_url: string, init: { signal: AbortSignal }) =>
                new Promise((_resolve, reject) => {
                    init.signal.addEventListener("abort", () => reject(new Error("aborted")));
                }),
        );

        const promise = client.getPost("post-1");
        const result = await promise;

        expect(result).toBeNull();
    });

    it("returns null when fetch rejects due to a network error", async () => {
        (global.fetch as ReturnType<typeof vi.fn>).mockRejectedValue(new Error("network error"));

        const result = await client.getPost("post-1");

        expect(result).toBeNull();
    });
});
