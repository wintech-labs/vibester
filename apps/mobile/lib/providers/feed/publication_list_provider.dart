import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:mobile/models/feed/feed_item_model.dart';
import 'package:mobile/models/feed/publication_model.dart';
import 'package:mobile/service/feed/feed_service.dart';
import 'package:mobile/service/posts/post_service.dart';
import 'package:mobile/utils/data_freshness.dart';

/// Uma carga do feed já reduzida ao que o feed desenha: post de usuário.
class _Carga {
  const _Carga({required this.posts, required this.nextCursor});

  final List<PublicationModel> posts;
  final String? nextCursor;
}

class PublicationListProvider extends ChangeNotifier {
  PublicationListProvider({
    FeedService? feedService,
    PostService? postService,
    List<Duration>? moderationChecks,
  }) : _feedService = feedService ?? FeedService(),
       _postService = postService ?? PostService(),
       _moderationChecks = moderationChecks ?? defaultModerationChecks;

  final FeedService _feedService;
  final PostService _postService;

  /// Quando, depois de publicar, o app pergunta se a moderação de imagem
  /// removeu o post.
  ///
  /// A moderação roda no worker do post-validation-service, que dá a cada post
  /// um orçamento de 45s (ver o CLAUDE.md dele); o caso comum termina em
  /// poucos segundos. A primeira consulta pega o caso comum e a segunda vem
  /// depois do orçamento. Duas leituras por post publicado é custo desprezível
  /// perto das leituras do feed, e publicar é raro perto de ler.
  static const defaultModerationChecks = [
    Duration(seconds: 15),
    Duration(seconds: 60),
  ];

  final List<Duration> _moderationChecks;
  final Map<String, Timer> _moderationTimers = {};

  final List<PublicationModel> _publications = [];
  String? _nextCursor;
  String? _userId;
  DateTime? _lastFetchedAt;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  String? _erro;
  String? _erroAoCarregarMais;

  /// Posts que a conta publicou nesta sessão.
  ///
  /// O feed-service grava o post no feed do autor de forma assíncrona (Kafka):
  /// um refresh logo depois de publicar ainda vem sem ele, e trocaria a lista
  /// pela do servidor apagando a confirmação de que a publicação deu certo.
  /// Assim que o servidor passa a trazer o post, a cópia dele prevalece
  /// (ver [_mergeOwn]).
  final List<PublicationModel> _ownPublications = [];

  /// Páginas seguidas que o provider percorre atrás de post de usuário antes
  /// de devolver o controle.
  ///
  /// O feed-service devolve tipos misturados e o cartão só existe para
  /// `userPost`, então uma página inteira pode não render nada. Quando isso
  /// acontecia a lista não crescia, o scroll não se movia e `loadMore` — que
  /// só dispara em evento de scroll — nunca era chamado de novo: o feed
  /// truncava sozinho no meio, com cursor ainda aberto.
  static const _maxPaginasSemPost = 5;

  List<PublicationModel> get publications => _publications;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get hasMore => _hasMore;
  String? get erro => _erro;

  /// Erro da paginação, separado de [erro]: aqui a lista atual continua de pé
  /// e a tela só oferece "Tentar de novo" no fim do scroll.
  String? get erroAoCarregarMais => _erroAoCarregarMais;

  /// Ver [PlaceListProvider.fetchPlaces] para a lógica de staleness. Aqui
  /// também considera troca de usuário como motivo para refazer a busca.
  Future<void> fetchPublications(String userId, {bool force = false}) async {
    final sameUser = _userId == userId;
    if (sameUser &&
        _publications.isNotEmpty &&
        !force &&
        !isDataStale(_lastFetchedAt)) {
      return;
    }

    // Só a troca de usuário esvazia a lista na hora — o feed anterior é de
    // outra sessão e não pode aparecer nem por um quadro. No pull-to-refresh
    // a lista atual fica na tela até a nova chegar: limpar antes do request
    // trocava o feed inteiro pelo esqueleto a cada refresh, e devolvia o
    // usuário para o topo mesmo quando nada tinha mudado.
    if (!sameUser) {
      // Post da sessão anterior é de outra conta; antes da primeira busca
      // (`_userId` nulo) ainda não há conta anterior para descartar.
      if (_userId != null) {
        _ownPublications.clear();
        _cancelModerationWatches();
      }
      _publications.clear();
      _nextCursor = null;
      _hasMore = true;
    }

    _userId = userId;
    _isLoading = true;
    _erro = null;
    _erroAoCarregarMais = null;
    notifyListeners();

    try {
      final carga = await _carregar(userId);
      _publications
        ..clear()
        ..addAll(_mergeOwn(carga.posts));
      _nextCursor = carga.nextCursor;
      _hasMore = carga.nextCursor != null;
      _lastFetchedAt = DateTime.now();
    } catch (e) {
      debugPrint('Falha ao carregar o feed de $userId: $e');
      _erro = _mensagem(e, 'Não foi possível carregar o feed');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadMore() async {
    if (_isLoadingMore || !_hasMore || _userId == null) return;

    _isLoadingMore = true;
    _erroAoCarregarMais = null;
    notifyListeners();

    try {
      final carga = await _carregar(_userId!, cursor: _nextCursor);
      final ownIds = {for (final p in _ownPublications) p.id};
      _publications.addAll(carga.posts.where((p) => !ownIds.contains(p.id)));
      _nextCursor = carga.nextCursor;
      _hasMore = carga.nextCursor != null;
    } catch (e) {
      // A lista atual fica de pé e o erro vira uma linha com "Tentar de novo"
      // no fim do scroll. Antes isso sumia em silêncio: o feed só parava de
      // crescer, sem nada explicando o motivo nem caminho de volta.
      debugPrint('Falha ao paginar o feed de $_userId: $e');
      _erroAoCarregarMais = _mensagem(
        e,
        'Não foi possível carregar mais publicações',
      );
    } finally {
      _isLoadingMore = false;
      notifyListeners();
    }
  }

  /// Busca a partir de [cursor] até juntar ao menos um post ou acabar o feed.
  Future<_Carga> _carregar(String userId, {String? cursor}) async {
    final posts = <PublicationModel>[];
    var proximo = cursor;
    var paginas = 0;

    do {
      final page = await _feedService.getFeed(userId: userId, cursor: proximo);
      posts.addAll(
        page.items
            .where((item) => item.itemType == FeedItemType.userPost)
            .map(PublicationModel.fromFeedItem),
      );
      proximo = page.nextCursor;
      paginas++;
    } while (posts.isEmpty && proximo != null && paginas < _maxPaginasSemPost);

    return _Carga(posts: posts, nextCursor: proximo);
  }

  /// Mensagem já tratada pelo service (`apiErrorMessage`), sem o prefixo que o
  /// `toString()` da `Exception` acrescenta. Qualquer `Error` (um `TypeError`
  /// de parsing, por exemplo) cai no genérico: é texto de programador, não
  /// serve para a tela.
  String _mensagem(Object e, String fallback) =>
      e is Exception ? e.toString().replaceFirst('Exception: ', '') : fallback;

  /// Encaixa os posts da própria conta na primeira página, cada um antes do
  /// primeiro post mais antigo que ele — a ordem do servidor não muda. Se o
  /// servidor já trouxer o post (o autor passou a receber o próprio post, por
  /// exemplo), vale a cópia dele, que tem curtidas atualizadas.
  List<PublicationModel> _mergeOwn(List<PublicationModel> server) {
    final merged = [...server];
    final serverIds = {for (final p in server) p.id};
    for (final own in _ownPublications.reversed) {
      if (serverIds.contains(own.id)) continue;
      final index = merged.indexWhere(
        (p) => p.publicatedAt.isBefore(own.publicatedAt),
      );
      merged.insert(index == -1 ? merged.length : index, own);
    }
    return merged;
  }

  void addPublication(PublicationModel publication) {
    _publications.insert(0, publication);
    notifyListeners();
  }

  /// Post que a conta acabou de publicar: entra no topo do feed na hora e
  /// continua lá nos refreshes seguintes (ver [_ownPublications]).
  void addOwnPublication(PublicationModel publication) {
    _ownPublications
      ..removeWhere((p) => p.id == publication.id)
      ..insert(0, publication);
    _publications
      ..removeWhere((p) => p.id == publication.id)
      ..insert(0, publication);
    notifyListeners();
  }

  /// Mantém a cópia de [_ownPublications] igual à da lista, para uma curtida
  /// não voltar atrás no próximo refresh.
  void _syncOwn(PublicationModel publication) {
    final index = _ownPublications.indexWhere((p) => p.id == publication.id);
    if (index != -1) _ownPublications[index] = publication;
  }

  /// Exclusão otimista: tira a publicação da lista antes da resposta e a
  /// devolve à mesma posição se a API recusar. Funciona também para post que
  /// não está no feed (aberto pela grade do perfil) — aí só chama a API.
  /// Relança o erro para a tela avisar o usuário.
  Future<void> deletePublication(String id, String userId) async {
    final index = _publications.indexWhere((p) => p.id == id);
    final removed = index == -1 ? null : _publications.removeAt(index);
    if (removed != null) notifyListeners();

    // Excluído pelo autor: a consulta da moderação veria `isDeleted` e
    // anunciaria uma remoção que não aconteceu.
    _moderationTimers.remove(id)?.cancel();

    try {
      await _postService.deletePost(postId: id, userId: userId);
      _ownPublications.removeWhere((p) => p.id == id);
    } catch (e) {
      if (removed != null) {
        _publications.insert(min(index, _publications.length), removed);
        notifyListeners();
      }
      rethrow;
    }
  }

  /// Acompanha um post recém-publicado até a moderação de imagem decidir.
  ///
  /// Se ela removeu o post, ele sai da lista (e de [_ownPublications], senão
  /// o próximo refresh o traria de volta) e [onRemoved] avisa a tela. O motivo
  /// não vem daqui: o notification-service grava o aviso `post_rejected` com o
  /// texto pronto, e é lá que a pessoa lê por que foi removido.
  ///
  /// Falha de rede numa consulta não é veredito: só segue para a próxima.
  void watchModeration(String postId, {required VoidCallback onRemoved}) {
    _moderationTimers.remove(postId)?.cancel();
    _scheduleModerationCheck(postId, 0, onRemoved);
  }

  void _scheduleModerationCheck(
    String postId,
    int attempt,
    VoidCallback onRemoved,
  ) {
    if (attempt >= _moderationChecks.length) {
      _moderationTimers.remove(postId);
      return;
    }

    final previous = attempt == 0
        ? Duration.zero
        : _moderationChecks[attempt - 1];
    final wait = _moderationChecks[attempt] - previous;

    _moderationTimers[postId] = Timer(wait, () async {
      final status = await _postService.moderationStatus(postId);
      // Cancelado enquanto a consulta estava no ar (logout, exclusão).
      if (!_moderationTimers.containsKey(postId)) return;

      if (status == PostModerationStatus.removed) {
        _moderationTimers.remove(postId);
        _removeModerated(postId);
        onRemoved();
        return;
      }
      _scheduleModerationCheck(postId, attempt + 1, onRemoved);
    });
  }

  void _removeModerated(String postId) {
    _ownPublications.removeWhere((p) => p.id == postId);
    final before = _publications.length;
    _publications.removeWhere((p) => p.id == postId);
    if (_publications.length != before) notifyListeners();
  }

  void _cancelModerationWatches() {
    for (final timer in _moderationTimers.values) {
      timer.cancel();
    }
    _moderationTimers.clear();
  }

  @override
  void dispose() {
    _cancelModerationWatches();
    super.dispose();
  }

  Future<void> toggleLike(String? id, String? userId) async {
    if (id == null || userId == null) return;

    final index = _publications.indexWhere((p) => p.id == id);
    if (index == -1) return;

    final pub = _publications[index];
    final wasLiked = pub.isLiked;

    _publications[index] = pub.copyWith(
      isLiked: !wasLiked,
      likes: wasLiked ? max(0, pub.likes - 1) : pub.likes + 1,
    );
    _syncOwn(_publications[index]);
    notifyListeners();

    try {
      if (wasLiked) {
        await _postService.unlikePost(postId: id, userId: userId);
      } else {
        await _postService.likePost(postId: id, userId: userId);
      }
    } catch (e) {
      final is409 =
          e.toString().contains('409') ||
          e.toString().contains('already liked') ||
          e.toString().contains('already unliked');
      if (!is409) {
        // Sem este log a falha era invisível: a UI só voltava ao estado
        // anterior e parecia que o toque nem tinha chamado a API.
        debugPrint('toggleLike falhou para o post $id: $e');
        _publications[index] = pub;
        _syncOwn(pub);
        notifyListeners();
      }
    }
  }
}
