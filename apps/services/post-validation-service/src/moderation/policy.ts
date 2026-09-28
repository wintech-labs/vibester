import { ValidationCode } from "../types/validation.types";
import { mostSevere, type CategoryScores, type ModerationAction } from "./types";

/**
 * Política de imagem: score de categoria -> ação.
 *
 * É dado, não lógica — no molde da blocklist de texto. Os limites abaixo são
 * **ponto de partida**, não verdade: servem para rodar em `observe` e ser
 * recalibrados olhando `image_moderation_score` em posts reais. O risco a
 * vigiar é específico de um app de vida noturna: foto de festa com roupa curta
 * ou de praia marcando `sexual` alto. Por isso ocultar exige 0.8, e entre 0.5 e
 * 0.8 só avisa o autor.
 *
 * O que NÃO está aqui, porque a API não avalia em imagem: símbolos de ódio,
 * drogas e conteúdo sexual envolvendo menores. Este último pede outra
 * ferramenta (comparação com banco de material conhecido) — ver "Moderação de
 * imagem" no CLAUDE.md.
 */
export interface ImagePolicyRule {
    code: ValidationCode;
    /** Categorias da OpenAI que alimentam a regra; vale o maior score entre elas. */
    categories: string[];
    /** Score a partir do qual o post é ocultado. Ausente = a regra nunca oculta. */
    hideAt?: number;
    /** Score a partir do qual o autor é avisado. */
    notifyAt?: number;
    message: string;
}

export const IMAGE_POLICY: ImagePolicyRule[] = [
    {
        code: ValidationCode.IMAGE_SEXUAL,
        categories: ["sexual"],
        hideAt: 0.8,
        notifyAt: 0.5,
        message: "Uma das imagens da publicação parece conter conteúdo sexual.",
    },
    {
        code: ValidationCode.IMAGE_GRAPHIC_VIOLENCE,
        categories: ["violence/graphic"],
        hideAt: 0.8,
        notifyAt: 0.5,
        message: "Uma das imagens da publicação parece conter violência explícita.",
    },
    {
        // Violência sem ser gráfica (briga, luta, arma à mostra) não oculta:
        // o contexto importa demais — uma luta de boxe num bar é evento.
        code: ValidationCode.IMAGE_VIOLENCE,
        categories: ["violence"],
        notifyAt: 0.8,
        message: "Uma das imagens da publicação parece conter violência.",
    },
    {
        // Nunca oculta e nunca é tratado como punição: o aviso ao autor é de
        // acolhimento, com o CVV (188). Ver o handler do notification-service.
        code: ValidationCode.IMAGE_SELF_HARM,
        categories: ["self-harm", "self-harm/intent", "self-harm/instructions"],
        notifyAt: 0.5,
        message: "Uma das imagens da publicação pode tratar de automutilação.",
    },
];

export interface PolicyFinding {
    code: ValidationCode;
    /** Categoria de maior score dentro da regra — é o que vai para a auditoria. */
    category: string;
    score: number;
    action: Exclude<ModerationAction, "allow">;
    message: string;
}

export interface ImageEvaluation {
    action: ModerationAction;
    findings: PolicyFinding[];
}

export function evaluateImage(scores: CategoryScores, policy: ImagePolicyRule[] = IMAGE_POLICY): ImageEvaluation {
    const findings: PolicyFinding[] = [];

    for (const rule of policy) {
        let category = rule.categories[0]!;
        let score = 0;

        for (const candidate of rule.categories) {
            const value = scores[candidate];
            if (typeof value === "number" && value > score) {
                score = value;
                category = candidate;
            }
        }

        const action: ModerationAction =
            rule.hideAt !== undefined && score >= rule.hideAt ? "hide"
                : rule.notifyAt !== undefined && score >= rule.notifyAt ? "notify"
                    : "allow";

        if (action !== "allow") {
            findings.push({ code: rule.code, category, score, action, message: rule.message });
        }
    }

    return { action: mostSevere(findings.map((finding) => finding.action)), findings };
}
