import { describe, it, expect } from "vitest";
import { evaluateImage } from "../policy";
import { mostSevere } from "../types";
import { ValidationCode } from "../../types/validation.types";

describe("evaluateImage", () => {
    it("deixa passar foto sem score relevante", () => {
        expect(evaluateImage({ sexual: 0.1, violence: 0.05 })).toEqual({ action: "allow", findings: [] });
    });

    /**
     * O ponto de calibragem do app: foto de festa com roupa curta pode marcar
     * `sexual` médio. Entre 0.5 e 0.8 isso só avisa o autor — nunca oculta.
     */
    it("so avisa em conteudo sexual de score medio", () => {
        const result = evaluateImage({ sexual: 0.6 });

        expect(result.action).toBe("notify");
        expect(result.findings[0]).toMatchObject({ code: ValidationCode.IMAGE_SEXUAL, action: "notify" });
    });

    it("oculta conteudo sexual de score alto", () => {
        expect(evaluateImage({ sexual: 0.92 }).action).toBe("hide");
    });

    it("oculta violencia grafica de score alto", () => {
        const result = evaluateImage({ "violence/graphic": 0.85 });

        expect(result.action).toBe("hide");
        expect(result.findings[0].code).toBe(ValidationCode.IMAGE_GRAPHIC_VIOLENCE);
    });

    /** Uma luta de boxe num bar é evento: violência não gráfica nunca oculta. */
    it("nunca oculta violencia nao grafica, mesmo com score maximo", () => {
        const result = evaluateImage({ violence: 0.99 });

        expect(result.action).toBe("notify");
        expect(result.findings[0].code).toBe(ValidationCode.IMAGE_VIOLENCE);
    });

    /** Automutilação é acolhimento, não punição: só aviso, e nunca ocultação. */
    it("automutilacao so avisa, e usa o maior score entre as subcategorias", () => {
        const result = evaluateImage({ "self-harm": 0.2, "self-harm/intent": 0.97 });

        expect(result.action).toBe("notify");
        expect(result.findings[0]).toMatchObject({
            code: ValidationCode.IMAGE_SELF_HARM,
            category: "self-harm/intent",
            score: 0.97,
        });
    });

    it("devolve a acao mais grave e todos os achados", () => {
        const result = evaluateImage({ sexual: 0.6, "violence/graphic": 0.9 });

        expect(result.action).toBe("hide");
        expect(result.findings.map((f) => f.code)).toEqual([
            ValidationCode.IMAGE_SEXUAL,
            ValidationCode.IMAGE_GRAPHIC_VIOLENCE,
        ]);
    });

    it("usa o limite inclusivo", () => {
        expect(evaluateImage({ sexual: 0.8 }).action).toBe("hide");
        expect(evaluateImage({ sexual: 0.5 }).action).toBe("notify");
    });
});

describe("mostSevere", () => {
    it("ordena allow < notify < hide", () => {
        expect(mostSevere([])).toBe("allow");
        expect(mostSevere(["allow", "notify"])).toBe("notify");
        expect(mostSevere(["notify", "hide", "allow"])).toBe("hide");
    });
});
