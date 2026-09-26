import 'package:flutter/material.dart';
import 'package:mobile/providers/feed/publication_list_provider.dart';
import 'package:mobile/providers/preferences/preferences_provider.dart';
import 'package:mobile/providers/safety/block_provider.dart';
import 'package:mobile/providers/user/user_provider.dart';
import 'package:mobile/models/interaction/interaction_event_model.dart';
import 'package:mobile/routes/app_routes.dart';
import 'package:mobile/routes/route_observer.dart';
import 'package:mobile/service/interaction/interaction_tracker.dart';
import 'package:mobile/theme/app_motion.dart';
import 'package:mobile/theme/app_spacing.dart';
import 'package:mobile/theme/theme_extensions.dart';
import 'package:mobile/widgets/buttons/vibester_button.dart';
import 'package:mobile/widgets/cards/feed/publication_card.dart';
import 'package:mobile/widgets/common/vibester_skeleton.dart';
import 'package:mobile/widgets/common/vibester_state.dart';
import 'package:mobile/widgets/motion/staggered_entrance.dart';
import 'package:mobile/widgets/navigation/navbar_tokens.dart';
import 'package:mobile/widgets/tracking/tracked_feed_item.dart';
import 'package:provider/provider.dart';

/// FEED — o que as pessoas estão postando.
///
/// Mudou de lugar na arquitetura: era a primeira aba *dentro* da Home, ou
/// seja, a tela que abria o app era a rede social, e a descoberta ficava
/// escondida atrás de uma segunda aba. Aqui o feed é um destino próprio, e
/// quem abre o Vibester cai em HOJE — o produto abre respondendo "o que tem
/// pra fazer", não "quem postou".
///
/// O botão flutuante de publicar saiu: publicar agora é o botão central do
/// dock, disponível de qualquer destino, sem um FAB competindo com ele na
/// mesma tela.
class FeedScreen extends StatefulWidget {
  /// Mantido por compatibilidade com quem ainda navega para a rota `/feed`
  /// direto; a casca da Home não precisa mais dele para esconder a navegação.
  final ValueNotifier<bool>? navbarVisibleNotifier;

  const FeedScreen({super.key, this.navbarVisibleNotifier});

  @override
  State<FeedScreen> createState() => FeedScreenState();
}

class FeedScreenState extends State<FeedScreen> with RouteAware {
  final _scrollController = ScrollController();

  /// Guardado aqui porque `context.read` não pode ser chamado no `dispose`.
  InteractionTracker? _tracker;

  /// Altura do cabeçalho com a logo. O conteúdo reserva esse espaço no topo
  /// do scroll, então com o cabeçalho à vista nada nasce escondido atrás dele.
  static const double _headerHeight = 50;

  /// Mesmo par de logotipos da tela inicial: `tipografia.png` tem o "STER"
  /// branco, para o fundo escuro; a versão azul tem o "STER" preto, para o
  /// claro.
  static const _logo = 'assets/img/logo/tipografia.png';
  static const _logoLight = 'assets/img/logo/tipografia_preto.png';

  /// Mesmo gesto do dock: some ao descer, volta ao subir.
  bool _headerVisible = true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _load({bool force = false}) {
    final userId = context.read<UserProvider>().user?.accountId;
    if (userId == null) return;
    context.read<PublicationListProvider>().fetchPublications(
      userId,
      force: force,
    );
  }

  /// Volta ao topo, onde fica o post recém-publicado.
  void scrollToTop() {
    _setHeaderVisible(true);
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: AppMotion.slow,
      curve: AppMotion.standard,
    );
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 400) {
      context.read<PublicationListProvider>().loadMore();
    }
  }

  /// Esconde o cabeçalho ao descer e devolve ao subir, com o mesmo limiar de
  /// 3px que a Home usa para o dock — os dois se movem juntos. No topo da
  /// lista ele fica sempre à vista, senão sobraria um buraco no lugar dele.
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is! ScrollUpdateNotification) return false;
    if (notification.metrics.axis != Axis.vertical) return false;
    // Só o scroll do próprio feed; carrossel de mídia dentro do card não conta.
    if (notification.depth != 0) return false;

    // BARRAS FLUTUANTES: desligado nos Ajustes, o cabeçalho não some nem
    // volta com a rolagem — fica fixo (ver o `visible` no `build`). O `false`
    // mantém a notificação subindo até a Home, que decide o dock pela mesma
    // preferência.
    if (!context.read<PreferencesProvider>().floatingBars) return false;

    if (notification.metrics.pixels <= _headerHeight) {
      _setHeaderVisible(true);
      return false;
    }

    final delta = notification.scrollDelta ?? 0;
    if (delta > 3) {
      _setHeaderVisible(false);
    } else if (delta < -3) {
      _setHeaderVisible(true);
    }
    // false: a notificação continua subindo até a Home, que controla o dock.
    return false;
  }

  void _setHeaderVisible(bool visible) {
    if (_headerVisible == visible || !mounted) return;
    setState(() => _headerVisible = visible);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    _tracker = maybeInteractionTracker(context);

    final route = ModalRoute.of(context);

    if (route != null) {
      appRouteObserver.subscribe(this, route);
    }
  }

  /// CORREÇÃO: chamado pelo `RouteObserver` no momento da inscrição (feita no
  /// `didChangeDependencies` acima), ou seja, quando este feed passa a existir.
  ///
  /// Garante que um feed recém-montado nasça "sem nada por cima". O tracker
  /// vive acima desta tela e sobrevive a ela: sair da conta pelos Ajustes —
  /// uma rota empilhada sobre a Home — deixava a flag de "coberto" ligada,
  /// porque a Home era removida da pilha sem nunca receber o `didPopNext`, e
  /// o feed da próxima sessão nascia sem medir.
  @override
  void didPush() => _tracker?.setCoveredByRoute(false);

  /// Uma rota foi empilhada por cima — perfil do autor, detalhe do post.
  ///
  /// A partir daqui o `Overlay` para de pintar esta tela e o detector de
  /// visibilidade dos cards congela no último valor. Sem este aviso, o post
  /// que estava na tela acumularia atenção durante a visita à outra tela.
  ///
  /// CORREÇÃO: esta tela agora só informa se há algo por cima dela — não se
  /// ela está visível. O feed vive dentro da casca da Home, e as rotas abertas
  /// a partir de HOJE, BUSCA ou VOCÊ também caem aqui, porque a rota por baixo
  /// é a mesma. Antes, fechar um evento aberto em HOJE chamava o antigo
  /// `resumeSurface` e religava a medição do feed, que nem estava na tela.
  /// Se o feed é a aba atual é o outro interruptor, e ele é da Home.
  @override
  void didPushNext() => _tracker?.setCoveredByRoute(true);

  @override
  void didPopNext() => _tracker?.setCoveredByRoute(false);

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final provider = context.watch<PublicationListProvider>();
    // Bloqueio some na hora; o feed-service tira os posts do feed em seguida.
    final blocks = context.watch<BlockProvider>();
    // BARRAS FLUTUANTES: `select` para reconstruir só quando esta preferência
    // muda.
    final floatingBars = context.select<PreferencesProvider, bool>(
      (p) => p.floatingBars,
    );
    final publications = provider.publications
        .where((p) => !blocks.isBlocked(p.authorId))
        .toList();

    return Scaffold(
      backgroundColor: colors.noturno,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            NotificationListener<ScrollNotification>(
              onNotification: _onScrollNotification,
              child: RefreshIndicator(
                color: colors.ambar,
                backgroundColor: colors.surface,
                // O indicador de refresh nasce abaixo do cabeçalho, não
                // escondido atrás dele.
                edgeOffset: _headerHeight,
                onRefresh: () async => _load(force: true),
                child: CustomScrollView(
                  controller: _scrollController,
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    // Espaço do cabeçalho: ele flutua por cima do scroll,
                    // então o primeiro post começa logo abaixo dele e, quando
                    // o cabeçalho sobe, o conteúdo ocupa o lugar.
                    const SliverToBoxAdapter(
                      child: SizedBox(height: _headerHeight),
                    ),

                    if (provider.isLoading && publications.isEmpty)
                      const SliverToBoxAdapter(child: _FeedSkeleton())
                    else if (provider.erro != null && publications.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: VibesterState.error(
                          message: provider.erro!,
                          onAction: () => _load(force: true),
                        ),
                      )
                    else if (publications.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: VibesterState(
                          headline: 'Feed vazio',
                          message:
                              'Siga gente que sai e o rolê aparece aqui. '
                              'Ou seja você a começar: publique o seu.',
                          icon: Icons.photo_camera_outlined,
                          actionLabel: 'Publicar agora',
                          onAction: () => Navigator.pushNamed(
                            context,
                            AppRoutes.newPublication,
                          ),
                        ),
                      )
                    else
                      SliverList.builder(
                        itemCount: publications.length,
                        itemBuilder: (context, index) {
                          final publication = publications[index];
                          final itemId = publication.id;

                          // Post recém-criado, ainda só local: sem id não há o
                          // que rastrear, e um itemId vazio reprovaria o lote
                          // inteiro no interaction-service.
                          if (itemId == null) {
                            return StaggeredEntrance(
                              index: index,
                              child: PublicationCard(
                                publication: publication,
                                index: index,
                              ),
                            );
                          }

                          // A posição é a da lista já filtrada por bloqueio —
                          // a que a pessoa viu de fato, que é o que torna a
                          // comparação entre itens justa.
                          final tracked = TrackedItem(
                            itemId: itemId,
                            itemType: InteractionItemType.post,
                            source: InteractionSource.feed,
                            position: index,
                            authorId: publication.authorId,
                          );

                          return StaggeredEntrance(
                            index: index,
                            child: TrackedFeedItem(
                              item: tracked,
                              child: PublicationCard(
                                publication: publication,
                                index: index,
                                onAuthorTap: () => _tracker?.recordTap(
                                  tracked,
                                  InteractionType.profileOpen,
                                ),
                              ),
                            ),
                          );
                        },
                      ),

                    if (provider.isLoadingMore)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: AppSpacing.screen,
                            vertical: AppSpacing.lg,
                          ),
                          child: VibesterSkeleton(height: 220),
                        ),
                      )
                    else if (provider.erroAoCarregarMais != null &&
                        publications.isNotEmpty)
                      SliverToBoxAdapter(
                        child: _FeedMoreError(
                          message: provider.erroAoCarregarMais!,
                          onRetry: () => context
                              .read<PublicationListProvider>()
                              .loadMore(),
                        ),
                      )
                    else if (publications.isNotEmpty && !provider.hasMore)
                      const SliverToBoxAdapter(child: _FeedEnd()),

                    const SliverPadding(
                      padding: EdgeInsets.only(bottom: AppSpacing.dockGap),
                    ),
                  ],
                ),
              ),
            ),

            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _FeedHeader(
                // BARRAS FLUTUANTES: desligado, sempre à vista.
                visible: _headerVisible || !floatingBars,
                height: _headerHeight,
                logo: Theme.of(context).brightness == Brightness.light
                    ? _logoLight
                    : _logo,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Cabeçalho do feed: a logo no centro, sobre o mesmo fundo da tela.
///
/// Mesma coreografia do dock (`VibesterNavbar`), espelhada: desliza para
/// cima e apaga ao descer, volta ao subir. O `ClipRect` corta o que passa da
/// borda da área segura, para ele sumir por trás da barra de status em vez
/// de desenhar por cima dela.
class _FeedHeader extends StatelessWidget {
  final bool visible;
  final double height;
  final String logo;

  const _FeedHeader({
    required this.visible,
    required this.height,
    required this.logo,
  });

  @override
  Widget build(BuildContext context) {
    final duration = context.adaptiveMotion(NavbarTokens.hide);

    return ClipRect(
      child: AnimatedSlide(
        offset: visible ? Offset.zero : const Offset(0, -1),
        duration: duration,
        curve: AppMotion.standard,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: duration,
          curve: AppMotion.standard,
          child: IgnorePointer(
            ignoring: !visible,
            child: Container(
              height: height,
              color: context.colors.noturno,
              alignment: Alignment.center,
              child: Semantics(
                label: 'Vibester',
                image: true,
                child: Image.asset(logo, height: 22, fit: BoxFit.contain),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FeedSkeleton extends StatelessWidget {
  const _FeedSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(
        horizontal: AppSpacing.screen,
        vertical: AppSpacing.lg,
      ),
      child: Column(
        children: [
          _PostSkeleton(),
          SizedBox(height: AppSpacing.xxl),
          _PostSkeleton(),
        ],
      ),
    );
  }
}

class _PostSkeleton extends StatelessWidget {
  const _PostSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const VibesterSkeleton(
              width: 36,
              height: 36,
              borderRadius: BorderRadius.all(Radius.circular(18)),
            ),
            const SizedBox(width: AppSpacing.md),
            const VibesterSkeleton(width: 120, height: 12),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        const AspectRatio(aspectRatio: 4 / 5, child: VibesterSkeleton()),
        const SizedBox(height: AppSpacing.md),
        const VibesterSkeletonLines(lines: 2),
      ],
    );
  }
}

/// Falha ao paginar. Não é a mesma coisa que o feed não carregar: aqui já tem
/// conteúdo na tela, então o erro fica no rodapé do scroll com o caminho de
/// volta, sem derrubar a lista que o usuário já estava lendo.
class _FeedMoreError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _FeedMoreError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.screen,
        vertical: AppSpacing.xl,
      ),
      child: Column(
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: context.typography.bodyMedium.copyWith(
              color: context.colors.textMuted,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          VibesterButton(
            label: 'Tentar de novo',
            onPressed: onRetry,
            variant: VibesterButtonVariant.ghost,
            expand: false,
            compact: true,
            icon: Icons.refresh_rounded,
          ),
        ],
      ),
    );
  }
}

/// Fim da lista — encerra o scroll com voz de produto em vez de silêncio.
class _FeedEnd extends StatelessWidget {
  const _FeedEnd();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
      child: Center(
        child: Text(
          'VOCÊ VIU TUDO  ·  VAI SAIR DE CASA',
          style: context.typography.monoMicro.copyWith(
            color: context.colors.textDisabled,
          ),
        ),
      ),
    );
  }
}