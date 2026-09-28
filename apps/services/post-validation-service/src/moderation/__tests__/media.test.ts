import { describe, it, expect } from "vitest";
import { collectModerationTargets } from "../media";

const BASE = "https://media.test";
const url = (name: string) => `${BASE}/posts/autor/${name}`;

describe("collectModerationTargets", () => {
    it("classifica a propria imagem de cada foto, guardando a posicao", () => {
        const result = collectModerationTargets({
            media: [{ url: url("a.jpg"), type: "IMAGE" }, { url: url("b.jpg"), type: "IMAGE" }],
        }, BASE);

        expect(result.targets).toEqual([
            { mediaIndex: 0, url: url("a.jpg") },
            { mediaIndex: 1, url: url("b.jpg") },
        ]);
    });

    /** A API não aceita vídeo: a capa é o que dá para classificar. */
    it("usa a capa do video, nao o video", () => {
        const result = collectModerationTargets({
            media: [{ url: url("v.mp4"), type: "VIDEO", thumbnailUrl: url("capa.jpg") }],
        }, BASE);

        expect(result.targets).toEqual([{ mediaIndex: 0, url: url("capa.jpg") }]);
    });

    it("registra video sem capa como nao classificado", () => {
        const result = collectModerationTargets({ media: [{ url: url("v.mp4"), type: "VIDEO" }] }, BASE);

        expect(result.targets).toEqual([]);
        expect(result.skipped).toEqual([{ mediaIndex: 0, reason: "video_without_cover" }]);
    });

    /**
     * Defesa em profundidade: o post-service já recusa mídia fora do bucket,
     * mas este serviço nunca deve mandar a um terceiro uma URL que não é nossa.
     */
    it("nao envia URL de fora do bucket", () => {
        const result = collectModerationTargets({
            media: [
                { url: "https://outro-site.com/foto.jpg", type: "IMAGE" },
                { url: `${BASE}.evil.com/foto.jpg`, type: "IMAGE" },
            ],
        }, BASE);

        expect(result.targets).toEqual([]);
        expect(result.skipped.map((s) => s.reason)).toEqual(["foreign_url", "foreign_url"]);
    });

    it("aceita o formato legado imageUrls quando nao ha media", () => {
        const result = collectModerationTargets({ imageUrls: [url("a.jpg")] }, BASE);

        expect(result.targets).toEqual([{ mediaIndex: 0, url: url("a.jpg") }]);
    });

    it("respeita o teto de 10 midias por post", () => {
        const media = Array.from({ length: 12 }, (_, i) => ({ url: url(`${i}.jpg`), type: "IMAGE" }));

        const result = collectModerationTargets({ media }, BASE);

        expect(result.targets).toHaveLength(10);
        expect(result.skipped.filter((s) => s.reason === "over_limit")).toHaveLength(2);
    });

    it("nao explode com payload estranho", () => {
        expect(collectModerationTargets({ media: [null, { url: 42 }] as unknown[] }, BASE).targets).toEqual([]);
        expect(collectModerationTargets({}, BASE).targets).toEqual([]);
    });
});
