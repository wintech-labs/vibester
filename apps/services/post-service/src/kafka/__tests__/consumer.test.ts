import { describe, it, expect, vi, beforeEach } from "vitest";
import { handleUserDeletedMessage, handleValidationRejectedMessage } from "../consumer";
import { env } from "../../config/env";

const ACCOUNT = "5f0c1a1e-9d8b-4c1a-8e2f-1b2c3d4e5f60";

describe("handleUserDeletedMessage", () => {
  const service = { deleteAllContent: vi.fn().mockResolvedValue(undefined) };

  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});
  });

  it("apaga o conteúdo da conta do evento do auth-service", async () => {
    await handleUserDeletedMessage(JSON.stringify({ userId: ACCOUNT, accountId: ACCOUNT, occurredAt: "x" }), service);
    expect(service.deleteAllContent).toHaveBeenCalledWith(ACCOUNT);
  });

  it("descarta evento malformado ou com id que não é UUID", async () => {
    await handleUserDeletedMessage("not-json", service);
    await handleUserDeletedMessage(JSON.stringify({}), service);
    await handleUserDeletedMessage(JSON.stringify({ accountId: "../outro-prefixo" }), service);

    expect(service.deleteAllContent).not.toHaveBeenCalled();
  });

  it("propaga erro do serviço para o Kafka reentregar", async () => {
    service.deleteAllContent.mockRejectedValueOnce(new Error("r2 down"));
    await expect(handleUserDeletedMessage(JSON.stringify({ accountId: ACCOUNT }), service)).rejects.toThrow("r2 down");
  });
});

describe("handleValidationRejectedMessage", () => {
  const POST = "7a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d";
  const moderation = { hideForModeration: vi.fn().mockResolvedValue("hidden") };

  const rejected = (data: Record<string, unknown>) => JSON.stringify({
    eventId: "evt-1",
    eventType: "post.validation.rejected",
    occurredAt: "2026-09-28T12:00:00.000Z",
    data: { postId: POST, authorId: "autor-1", ...data },
  });

  beforeEach(() => {
    vi.clearAllMocks();
    moderation.hideForModeration.mockResolvedValue("hidden");
    vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "warn").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});
    (env as { post_moderation_hide: boolean }).post_moderation_hide = true;
  });

  it("oculta o post quando a moderação pede", async () => {
    const issues = [{ code: "IMAGE_SEXUAL", field: "media", mediaIndex: 0 }];

    await handleValidationRejectedMessage(rejected({ action: "hide", issues }), moderation);

    expect(moderation.hideForModeration).toHaveBeenCalledWith(POST, issues);
  });

  /** "notify" é só aviso ao autor — o notification-service cuida; aqui não se mexe no post. */
  it("ignora rejeição que é só aviso", async () => {
    await handleValidationRejectedMessage(rejected({ action: "notify", issues: [] }), moderation);

    expect(moderation.hideForModeration).not.toHaveBeenCalled();
  });

  /** Evento publicado antes da moderação de imagem existir não tinha `action`: era sempre aviso. */
  it("trata evento sem action como aviso", async () => {
    await handleValidationRejectedMessage(rejected({ issues: [{ code: "HATE_SPEECH" }] }), moderation);

    expect(moderation.hideForModeration).not.toHaveBeenCalled();
  });

  it("respeita o freio POST_MODERATION_HIDE=off", async () => {
    (env as { post_moderation_hide: boolean }).post_moderation_hide = false;

    await handleValidationRejectedMessage(rejected({ action: "hide", issues: [] }), moderation);

    expect(moderation.hideForModeration).not.toHaveBeenCalled();
  });

  it("descarta evento malformado sem lançar", async () => {
    await handleValidationRejectedMessage("not-json", moderation);
    await handleValidationRejectedMessage(JSON.stringify({ data: { postId: "nao-e-uuid", authorId: "a", action: "hide" } }), moderation);

    expect(moderation.hideForModeration).not.toHaveBeenCalled();
  });

  it("propaga erro ao ocultar para o Kafka reentregar", async () => {
    moderation.hideForModeration.mockRejectedValueOnce(new Error("cassandra down"));

    await expect(handleValidationRejectedMessage(rejected({ action: "hide", issues: [] }), moderation))
      .rejects.toThrow("cassandra down");
  });
});
