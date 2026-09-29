import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/models/feed/feed_item_model.dart';
import 'package:mobile/models/feed/publication_model.dart';
import 'package:mobile/providers/feed/publication_list_provider.dart';
import 'package:mobile/service/feed/feed_service.dart';
import 'package:mobile/service/posts/post_service.dart';

/// O feed é a lista mais longa do app e a única que mistura tipos de item —
/// estes testes cobrem o que a tela não deixa ver: o que acontece entre o
/// disparo da busca e a resposta, e o que sobra quando uma página vem sem
/// nenhum post de usuário.
class _FakeFeedService extends FeedService {
  _FakeFeedService(this.paginas);

  final List<FeedPage> paginas;
  final List<String?> cursoresPedidos = [];
  Object? erro;

  /// Quando preenchido, segura a resposta até o teste liberar.
  Completer<void>? espera;

  @override
  Future<FeedPage> getFeed({
    required String userId,
    String? cursor,
    int limit = 20,
  }) async {
    cursoresPedidos.add(cursor);
    if (espera != null) await espera!.future;
    if (erro != null) throw erro!;
    return paginas[cursoresPedidos.length - 1];
  }
}

/// Responde a consulta da moderação na ordem de [respostas]; esgotadas,
/// o post segue no ar.
class _FakePostService extends PostService {
  _FakePostService(this.respostas);

  final List<PostModerationStatus> respostas;
  final List<String> consultas = [];

  @override
  Future<PostModerationStatus> moderationStatus(String postId) async {
    consultas.add(postId);
    return consultas.length <= respostas.length
        ? respostas[consultas.length - 1]
        : PostModerationStatus.visible;
  }

  @override
  Future<void> deletePost({
    required String postId,
    required String userId,
  }) async {}
}

FeedItemModel _post(String id, {DateTime? em}) => FeedItemModel(
  itemId: id,
  itemType: FeedItemType.userPost,
  userId: 'conta-1',
  createdAt: em ?? DateTime(2026, 9, 1),
  updatedAt: em ?? DateTime(2026, 9, 1),
  authorId: 'autor-1',
  authorUsername: 'ana',
  content: 'post $id',
);

FeedItemModel _evento(String id) => FeedItemModel(
  itemId: id,
  itemType: FeedItemType.event,
  userId: 'conta-1',
  createdAt: DateTime(2026, 9, 1),
  updatedAt: DateTime(2026, 9, 1),
);

void main() {
  test('pull-to-refresh mantém a lista na tela até a nova chegar', () async {
    final service = _FakeFeedService([
      FeedPage(items: [_post('p1'), _post('p2')], nextCursor: null),
      FeedPage(items: [_post('p3')], nextCursor: null),
    ]);
    final provider = PublicationListProvider(feedService: service);

    await provider.fetchPublications('conta-1');
    expect(provider.publications.length, 2);

    // Segura a segunda resposta: é exatamente a janela em que a lista sumia e
    // a tela caía para o esqueleto.
    service.espera = Completer<void>();
    final refresh = provider.fetchPublications('conta-1', force: true);
    await Future<void>.delayed(Duration.zero);

    expect(provider.isLoading, isTrue);
    expect(provider.publications.length, 2, reason: 'lista não pode piscar');

    service.espera!.complete();
    await refresh;

    expect(provider.publications.single.id, 'p3');
    expect(provider.isLoading, isFalse);
  });

  test('troca de usuário esvazia a lista na hora', () async {
    final service = _FakeFeedService([
      FeedPage(items: [_post('p1')], nextCursor: null),
      FeedPage(items: [_post('p9')], nextCursor: null),
    ]);
    final provider = PublicationListProvider(feedService: service);

    await provider.fetchPublications('conta-1');

    service.espera = Completer<void>();
    final troca = provider.fetchPublications('conta-2');
    await Future<void>.delayed(Duration.zero);

    expect(
      provider.publications,
      isEmpty,
      reason: 'feed de outra sessão não pode aparecer nem por um quadro',
    );

    service.espera!.complete();
    await troca;
    expect(provider.publications.single.id, 'p9');
  });

  test('página só com item de estabelecimento não trunca o feed', () async {
    final service = _FakeFeedService([
      FeedPage(items: [_evento('e1'), _evento('e2')], nextCursor: 'c1'),
      FeedPage(items: [_evento('e3')], nextCursor: 'c2'),
      FeedPage(items: [_post('p1')], nextCursor: null),
    ]);
    final provider = PublicationListProvider(feedService: service);

    await provider.fetchPublications('conta-1');

    expect(service.cursoresPedidos, [null, 'c1', 'c2']);
    expect(provider.publications.single.id, 'p1');
    expect(provider.hasMore, isFalse);
  });

  test('para de percorrer depois de 5 páginas sem post', () async {
    final service = _FakeFeedService(
      List.generate(
        8,
        (i) => FeedPage(items: [_evento('e$i')], nextCursor: 'c$i'),
      ),
    );
    final provider = PublicationListProvider(feedService: service);

    await provider.fetchPublications('conta-1');

    expect(service.cursoresPedidos.length, 5);
    expect(provider.publications, isEmpty);
    // Cursor continua aberto: o scroll pode pedir mais.
    expect(provider.hasMore, isTrue);
  });

  test('erro de carga mostra a mensagem tratada do service', () async {
    final service = _FakeFeedService([])
      ..erro = Exception(
        'Sem conexão com o servidor. Tenta de novo em '
        'instantes.',
      );
    final provider = PublicationListProvider(feedService: service);

    await provider.fetchPublications('conta-1');

    expect(
      provider.erro,
      'Sem conexão com o servidor. Tenta de novo em instantes.',
    );
  });

  test('erro de parsing não vaza texto de programador para a tela', () async {
    final service = _FakeFeedService([])..erro = TypeError();
    final provider = PublicationListProvider(feedService: service);

    await provider.fetchPublications('conta-1');

    expect(provider.erro, 'Não foi possível carregar o feed');
  });

  test('falha ao paginar preserva a lista e oferece o erro', () async {
    final service = _FakeFeedService([
      FeedPage(items: [_post('p1')], nextCursor: 'c1'),
    ]);
    final provider = PublicationListProvider(feedService: service);

    await provider.fetchPublications('conta-1');
    expect(provider.hasMore, isTrue);

    service.erro = Exception('Serviço indisponível no momento.');
    await provider.loadMore();

    expect(provider.publications.single.id, 'p1');
    expect(provider.erroAoCarregarMais, 'Serviço indisponível no momento.');
    expect(provider.erro, isNull, reason: 'a lista carregada segue válida');
    expect(provider.isLoadingMore, isFalse);
  });

  test('loadMore bem-sucedido limpa o erro anterior e soma a página', () async {
    final service = _FakeFeedService([
      FeedPage(items: [_post('p1')], nextCursor: 'c1'),
      FeedPage(items: [_post('p2')], nextCursor: null),
    ]);
    final provider = PublicationListProvider(feedService: service);

    await provider.fetchPublications('conta-1');
    await provider.loadMore();

    expect(provider.publications.map((p) => p.id), ['p1', 'p2']);
    expect(provider.erroAoCarregarMais, isNull);
    expect(provider.hasMore, isFalse);
  });

  group('post da própria conta', () {
    PublicationModel meu(String id, DateTime em) => PublicationModel(
      id: id,
      autor: 'eu',
      autorProfileImage: '',
      publicationImage: '',
      description: '',
      publicatedAt: em,
    );

    test('entra no topo na hora', () async {
      final service = _FakeFeedService([
        FeedPage(items: [_post('p1')], nextCursor: null),
      ]);
      final provider = PublicationListProvider(feedService: service);
      await provider.fetchPublications('conta-1');

      provider.addOwnPublication(meu('meu', DateTime(2026, 9, 2)));

      expect(provider.publications.map((p) => p.id), ['meu', 'p1']);
    });

    test('sobrevive ao refresh, na posição da data', () async {
      // O feed-service grava o post no feed do autor via Kafka: um refresh
      // logo depois de publicar ainda vem sem ele.
      final service = _FakeFeedService([
        FeedPage(items: [_post('p1')], nextCursor: null),
        FeedPage(
          items: [
            _post('novo', em: DateTime(2026, 9, 3)),
            _post('p1', em: DateTime(2026, 9, 1)),
          ],
          nextCursor: null,
        ),
      ]);
      final provider = PublicationListProvider(feedService: service);
      await provider.fetchPublications('conta-1');
      provider.addOwnPublication(meu('meu', DateTime(2026, 9, 2)));

      await provider.fetchPublications('conta-1', force: true);

      expect(provider.publications.map((p) => p.id), ['novo', 'meu', 'p1']);
    });

    test('não duplica quando o servidor já traz o post', () async {
      final service = _FakeFeedService([
        FeedPage(items: [_post('p1')], nextCursor: null),
        FeedPage(
          items: [
            _post('meu', em: DateTime(2026, 9, 2)),
            _post('p1'),
          ],
          nextCursor: null,
        ),
      ]);
      final provider = PublicationListProvider(feedService: service);
      await provider.fetchPublications('conta-1');
      provider.addOwnPublication(meu('meu', DateTime(2026, 9, 2)));

      await provider.fetchPublications('conta-1', force: true);

      expect(provider.publications.map((p) => p.id), ['meu', 'p1']);
      expect(
        provider.publications.first.autor,
        'ana',
        reason: 'vale a cópia do servidor',
      );
    });

    test('some ao trocar de conta', () async {
      final service = _FakeFeedService([
        FeedPage(items: [_post('p1')], nextCursor: null),
        FeedPage(items: [_post('p2')], nextCursor: null),
      ]);
      final provider = PublicationListProvider(feedService: service);
      await provider.fetchPublications('conta-1');
      provider.addOwnPublication(meu('meu', DateTime(2026, 9, 2)));

      await provider.fetchPublications('conta-2');

      expect(provider.publications.map((p) => p.id), ['p2']);
    });
  });

  group('moderação de imagem depois de publicar', () {
    const checks = [Duration(milliseconds: 10), Duration(milliseconds: 30)];

    PublicationModel meu(String id) => PublicationModel(
      id: id,
      autor: 'eu',
      autorProfileImage: '',
      publicationImage: '',
      description: '',
      publicatedAt: DateTime(2026, 9, 2),
    );

    Future<PublicationListProvider> montar(_FakePostService posts) async {
      final provider = PublicationListProvider(
        feedService: _FakeFeedService([
          FeedPage(items: [_post('p1')], nextCursor: null),
          FeedPage(items: [_post('p1')], nextCursor: null),
        ]),
        postService: posts,
        moderationChecks: checks,
      );
      await provider.fetchPublications('conta-1');
      provider.addOwnPublication(meu('meu'));
      return provider;
    }

    test('post removido sai da lista e não volta no refresh', () async {
      final posts = _FakePostService([PostModerationStatus.removed]);
      final provider = await montar(posts);
      var avisos = 0;

      provider.watchModeration('meu', onRemoved: () => avisos++);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(provider.publications.map((p) => p.id), ['p1']);
      expect(avisos, 1);
      expect(posts.consultas, ['meu'], reason: 'removido encerra a checagem');

      await provider.fetchPublications('conta-1', force: true);
      expect(provider.publications.map((p) => p.id), ['p1']);
    });

    test('falha de rede não é veredito: segue para a próxima', () async {
      final posts = _FakePostService([
        PostModerationStatus.unknown,
        PostModerationStatus.removed,
      ]);
      final provider = await montar(posts);
      var avisos = 0;

      provider.watchModeration('meu', onRemoved: () => avisos++);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(posts.consultas, ['meu', 'meu']);
      expect(avisos, 1);
      expect(provider.publications.map((p) => p.id), ['p1']);
    });

    test('post aprovado fica e as consultas param no fim', () async {
      final posts = _FakePostService([]);
      final provider = await montar(posts);
      var avisos = 0;

      provider.watchModeration('meu', onRemoved: () => avisos++);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(posts.consultas, ['meu', 'meu']);
      expect(avisos, 0);
      expect(provider.publications.map((p) => p.id), ['meu', 'p1']);
    });

    test('exclusão pelo autor cancela o aviso de remoção', () async {
      final posts = _FakePostService([PostModerationStatus.removed]);
      final provider = await montar(posts);
      var avisos = 0;

      provider.watchModeration('meu', onRemoved: () => avisos++);
      await provider.deletePublication('meu', 'conta-1');
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(posts.consultas, isEmpty);
      expect(avisos, 0);
    });

    test('troca de conta cancela a checagem', () async {
      final posts = _FakePostService([PostModerationStatus.removed]);
      final provider = await montar(posts);
      var avisos = 0;

      provider.watchModeration('meu', onRemoved: () => avisos++);
      await provider.fetchPublications('conta-2');
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(posts.consultas, isEmpty);
      expect(avisos, 0);
    });
  });
}
