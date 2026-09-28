import { describe, it, expect, vi, beforeEach } from "vitest";

const { mockRedis, mockSend } = vi.hoisted(() => ({
  mockRedis: { del: vi.fn().mockResolvedValue(1) },
  mockSend: vi.fn().mockResolvedValue(undefined),
}));
vi.mock("../../config/redis", () => ({
  redis: mockRedis,
  cacheAside: async <T>(_key: string, _ttl: number, fetchFn: () => Promise<T>): Promise<T> => fetchFn(),
}));
vi.mock("../../kafka/producer", () => ({
  producer: { send: mockSend },
}));

import { PostService } from "../post.service";
import { PostRepository } from "../../repository/post.repository";
import { LikeRepository } from "../../repository/like.repository";
import { MediaType, Post } from "../../types/post.types";

function makePost(overrides: Partial<Post> = {}): Post {
  return {
    postId: "post-1",
    userId: "autor-1",
    media: [{ url: "https://test.r2.dev/posts/autor-1/a.jpg", type: MediaType.IMAGE }],
    imageUrls: ["https://test.r2.dev/posts/autor-1/a.jpg"],
    caption: "festa",
    totalLikes: 3,
    totalComments: 0,
    isDeleted: false,
    createdAt: new Date("2026-09-01T00:00:00.000Z"),
    ...overrides,
  } as Post;
}

function publishedEvents() {
  return mockSend.mock.calls.map(([record]) => ({
    topic: record.topic,
    key: record.messages[0].key,
    ...JSON.parse(record.messages[0].value),
  }));
}

describe("PostService.hideForModeration", () => {
  let repo: PostRepository;
  let service: PostService;
  const ISSUES = [{ code: "IMAGE_SEXUAL", field: "media", mediaIndex: 0 }];

  beforeEach(() => {
    vi.clearAllMocks();
    repo = {
      findById: vi.fn().mockResolvedValue(makePost()),
      softDeleteInAllViews: vi.fn().mockResolvedValue(undefined),
    } as unknown as PostRepository;
    service = new PostService(repo, {} as LikeRepository);
  });

  /**
   * Reaproveita o soft delete: `post.deleted` é o que já faz o feed-service
   * tirar o post das timelines e o user-service descontar o contador.
   */
  it("oculta pelo caminho do soft delete e publica post.deleted", async () => {
    const result = await service.hideForModeration("post-1", ISSUES);

    expect(result).toBe("hidden");
    expect(repo.softDeleteInAllViews).toHaveBeenCalledTimes(1);
    expect(publishedEvents()[0]).toMatchObject({
      topic: "posts",
      key: "post-1",
      eventType: "post.deleted",
      data: { postId: "post-1", authorId: "autor-1" },
    });
  });

  /**
   * O aviso "foi removida" sai daqui, depois da remoção — nunca da
   * recomendação do validador, que poderia não ter sido executada.
   */
  it("publica post.moderation.hidden depois de ocultar, com os motivos", async () => {
    await service.hideForModeration("post-1", ISSUES);

    const events = publishedEvents();
    expect(events.map((e) => e.eventType)).toEqual(["post.deleted", "post.moderation.hidden"]);
    expect(events[1]).toMatchObject({
      topic: "post.moderation.hidden",
      key: "post-1",
      data: { postId: "post-1", authorId: "autor-1", issues: ISSUES },
    });
  });

  it("limpa o cache do post", async () => {
    await service.hideForModeration("post-1", ISSUES);

    expect(mockRedis.del).toHaveBeenCalled();
  });

  /**
   * Quem pede é o sistema, não uma pessoa: não há dono a comparar. (O
   * `softDelete` comum recusa com 403 quem não é o autor.)
   */
  it("nao checa dono", async () => {
    repo.findById = vi.fn().mockResolvedValue(makePost({ userId: "qualquer-outro" }));

    await expect(service.hideForModeration("post-1", ISSUES)).resolves.toBe("hidden");
  });

  /**
   * O Kafka reentrega. Post que o autor já apagou (ou que uma entrega anterior
   * já ocultou) não pode virar erro — seria retry infinito — nem republicar
   * post.deleted, que descontaria o contador do perfil duas vezes.
   */
  it("e idempotente: post ja apagado nao publica nada de novo", async () => {
    repo.findById = vi.fn().mockResolvedValue(makePost({ isDeleted: true }));

    await expect(service.hideForModeration("post-1", ISSUES)).resolves.toBe("already_deleted");
    expect(repo.softDeleteInAllViews).not.toHaveBeenCalled();
    expect(mockSend).not.toHaveBeenCalled();
  });

  it("post inexistente nao e erro", async () => {
    repo.findById = vi.fn().mockResolvedValue(null);

    await expect(service.hideForModeration("post-x", ISSUES)).resolves.toBe("not_found");
    expect(mockSend).not.toHaveBeenCalled();
  });
});
