import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mobile/models/highlights/highlight_model.dart';
import 'package:mobile/models/safety/report_reason.dart';
import 'package:mobile/providers/preferences/preferences_provider.dart';
import 'package:mobile/providers/user/user_provider.dart';
import 'package:mobile/service/posts/post_service.dart';
import 'package:mobile/theme/app_motion.dart';
import 'package:mobile/theme/app_spacing.dart';
import 'package:mobile/theme/theme_extensions.dart';
import 'package:mobile/widgets/cards/feed/delete_post_action.dart';
import 'package:mobile/widgets/common/screen_header.dart';
import 'package:mobile/widgets/media/post_media_carousel.dart';
import 'package:mobile/widgets/motion/double_tap_like.dart';
import 'package:mobile/widgets/motion/like_heart.dart';
import 'package:mobile/widgets/motion/vibester_pressable.dart';
import 'package:mobile/widgets/navigation/navbar_tokens.dart';
import 'package:mobile/widgets/safety/report_sheet.dart';
import 'package:mobile/widgets/safety/safety_actions.dart';
import 'package:provider/provider.dart';

/// Argumentos da rota [AppRoutes.postDetail].
class PostDetailArgs {
  /// Todos os posts da grade, na mesma ordem em que ela os mostra.
  final List<HighlightModel> posts;

  /// Posição, em [posts], do post que foi tocado na grade.
  final int initialIndex;

  /// Avisa a grade que um post foi excluído aqui, para ela tirá-lo sem
  /// refazer a busca.
  final ValueChanged<String>? onDeleted;

  const PostDetailArgs({
    required this.posts,
    required this.initialIndex,
    this.onDeleted,
  });
}

/// Feed dos posts de um perfil (ou de um lugar), aberto a partir da grade.
///
/// BARRAS FLUTUANTES: o cabeçalho com o voltar some ao descer e volta ao
/// subir só com "Barras flutuantes" ligado nos Ajustes (o padrão). Desligado,
/// fica fixo.
///
/// Cada post mantém o formato do detalhe de antes — mídia 4:5, curtida,
/// legenda e data —, só que empilhados na ordem da grade. A tela abre já no
/// post tocado e dá pra rolar para cima (os anteriores) ou para baixo (os
/// seguintes).
///
/// Abrir no post certo usa o `center` do `CustomScrollView`: os posts a
/// partir do tocado ficam numa lista que cresce para baixo, e os anteriores
/// numa lista que cresce para cima a partir dele. O deslocamento zero é o
/// topo do post tocado, então ele aparece exatamente no lugar, sem precisar
/// medir a altura de nada — as legendas têm tamanhos diferentes e qualquer
/// conta por altura erraria.
class PostDetailScreen extends StatefulWidget {
  final List<HighlightModel> posts;
  final int initialIndex;
  final ValueChanged<String>? onDeleted;

  const PostDetailScreen({
    super.key,
    required this.posts,
    this.initialIndex = 0,
    this.onDeleted,
  });

  PostDetailScreen.fromArgs(PostDetailArgs args, {Key? key})
    : this(
        key: key,
        posts: args.posts,
        initialIndex: args.initialIndex,
        onDeleted: args.onDeleted,
      );

  @override
  State<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends State<PostDetailScreen> {
  /// Mesma altura do cabeçalho do feed.
  static const double _headerHeight = 56;

  final PostService _postService = PostService();
  final _centerKey = UniqueKey();

  /// Começa em `-_headerHeight`: o post tocado nasce logo abaixo do
  /// cabeçalho, e não escondido atrás dele.
  final _scrollController = ScrollController(
    initialScrollOffset: -_headerHeight,
  );

  /// Cópia local dos posts. Curtida e exclusão mexem aqui, e não em cada
  /// item: um post que sai da tela é desmontado pela lista, e o estado dele
  /// se perderia na volta.
  late List<HighlightModel> _posts;

  /// Índice, em [_posts], do primeiro post da lista de baixo — o que foi
  /// tocado na grade.
  late int _centerIndex;

  final Set<String> _togglingLikes = {};
  final Set<String> _deleting = {};

  bool _headerVisible = true;

  @override
  void initState() {
    super.initState();
    _posts = List.of(widget.posts);
    _centerIndex = widget.initialIndex.clamp(0, math.max(0, _posts.length - 1));
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------
  // Cabeçalho
  // -------------------------------------------------------------------

  /// Mesmo gesto do cabeçalho do feed: some ao descer, volta ao subir, e no
  /// começo da lista fica sempre à vista.
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is! ScrollUpdateNotification) return false;
    if (notification.metrics.axis != Axis.vertical) return false;
    // Só o scroll da lista; o carrossel de mídia dentro do post não conta.
    if (notification.depth != 0) return false;

    // BARRAS FLUTUANTES: desligado nos Ajustes, o cabeçalho com o voltar fica
    // fixo — a rolagem não o esconde (ver o `visible` no `build`).
    if (!context.read<PreferencesProvider>().floatingBars) return false;

    final metrics = notification.metrics;
    if (metrics.pixels <= metrics.minScrollExtent + _headerHeight) {
      _setHeaderVisible(true);
      return false;
    }

    final delta = notification.scrollDelta ?? 0;
    if (delta > 3) {
      _setHeaderVisible(false);
    } else if (delta < -3) {
      _setHeaderVisible(true);
    }
    return false;
  }

  void _setHeaderVisible(bool visible) {
    if (_headerVisible == visible || !mounted) return;
    setState(() => _headerVisible = visible);
  }

  // -------------------------------------------------------------------
  // Ações de cada post
  // -------------------------------------------------------------------

  void _replace(String postId, HighlightModel Function(HighlightModel) edit) {
    final index = _posts.indexWhere((p) => p.postId == postId);
    if (index == -1) return;
    _posts[index] = edit(_posts[index]);
  }

  Future<void> _alternarCurtida(String postId) async {
    final userId = context.read<UserProvider>().user?.accountId;
    if (userId == null || _togglingLikes.contains(postId)) return;

    final index = _posts.indexWhere((p) => p.postId == postId);
    if (index == -1) return;
    final curtiaAntes = _posts[index].curtidoPeloUsuario;

    setState(() {
      _togglingLikes.add(postId);
      _replace(
        postId,
        (p) => p.copyWith(
          curtidoPeloUsuario: !curtiaAntes,
          totalCurtidas: curtiaAntes
              ? math.max(0, p.totalCurtidas - 1)
              : p.totalCurtidas + 1,
        ),
      );
    });

    try {
      if (curtiaAntes) {
        await _postService.unlikePost(postId: postId, userId: userId);
      } else {
        await _postService.likePost(postId: postId, userId: userId);
      }
    } catch (e) {
      final is409 =
          e.toString().contains('409') ||
          e.toString().contains('already liked') ||
          e.toString().contains('already unliked');
      if (!is409 && mounted) {
        debugPrint('Curtida falhou para o post $postId: $e');
        // Desfaz pelo id, não pela posição: um post pode ter sido excluído
        // enquanto a requisição andava.
        setState(
          () => _replace(
            postId,
            (p) => p.copyWith(
              curtidoPeloUsuario: curtiaAntes,
              totalCurtidas: math.max(
                0,
                p.totalCurtidas + (curtiaAntes ? 1 : -1),
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _togglingLikes.remove(postId));
      } else {
        _togglingLikes.remove(postId);
      }
    }
  }

  Future<void> _excluir(String postId) async {
    if (_deleting.contains(postId)) return;
    setState(() => _deleting.add(postId));

    final excluido = await confirmAndDeletePost(context, postId: postId);
    if (!mounted) return;

    if (!excluido) {
      setState(() => _deleting.remove(postId));
      return;
    }

    widget.onDeleted?.call(postId);

    // Sem post nenhum não há o que mostrar: volta pra grade.
    if (_posts.length <= 1) {
      Navigator.pop(context);
      return;
    }

    setState(() {
      final index = _posts.indexWhere((p) => p.postId == postId);
      if (index != -1) {
        _posts.removeAt(index);
        // Post acima do tocado: a lista de cima encolhe e o tocado continua
        // sendo o primeiro da lista de baixo.
        if (index < _centerIndex) _centerIndex--;
      }
      _deleting.remove(postId);
    });
  }

  /// Folha do ⋯: excluir no post do dono; denunciar e bloquear no de outra
  /// pessoa. Mesmas opções do cartão do feed, mesma ordem.
  Future<void> _abrirOpcoes(HighlightModel post, {required bool isOwn}) async {
    final action = await showSafetyActionsSheet(
      context,
      actions: isOwn
          ? const [SafetyAction.deletePost]
          : const [SafetyAction.reportPost, SafetyAction.block],
    );
    if (!mounted || action == null) return;

    switch (action) {
      case SafetyAction.deletePost:
        await _excluir(post.postId);
      case SafetyAction.reportPost:
        await showReportSheet(
          context,
          targetType: ReportTargetType.post,
          targetId: post.postId,
          targetOwnerId: post.userId,
        );
      case SafetyAction.block:
        final bloqueado = await confirmAndBlockUser(
          context,
          accountId: post.userId,
          displayName: '',
        );
        // Os posts desta tela são do perfil bloqueado: não há o que ficar
        // vendo aqui.
        if (bloqueado && mounted) Navigator.pop(context);
      case SafetyAction.reportProfile:
      case SafetyAction.unblock:
        break;
    }
  }

  // -------------------------------------------------------------------
  // Tela
  // -------------------------------------------------------------------

  Widget _buildPost(HighlightModel post, String? viewerId) {
    final isOwn = viewerId != null && post.userId == viewerId;

    // Sem sessão, ou sem saber de quem é o post, não há o que oferecer no ⋯.
    final temOpcoes = viewerId != null && post.userId.isNotEmpty;

    return _PostItem(
      key: ValueKey(post.postId),
      post: post,
      showOptions: temOpcoes && !_deleting.contains(post.postId),
      onLike: () => _alternarCurtida(post.postId),
      onOptions: () => _abrirOpcoes(post, isOwn: isOwn),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final viewerId = context.select<UserProvider, String?>(
      (p) => p.user?.accountId,
    );
    // BARRAS FLUTUANTES: `select` para reconstruir só quando esta preferência
    // muda.
    final floatingBars = context.select<PreferencesProvider, bool>(
      (p) => p.floatingBars,
    );

    // "Meus Posts" só quando todos são da conta logada; na grade de outro
    // perfil ou de um lugar, "Posts".
    final meus =
        viewerId != null &&
        widget.posts.isNotEmpty &&
        widget.posts.every((p) => p.userId == viewerId);

    final antes = _centerIndex;
    final depois = _posts.length - _centerIndex;

    return Scaffold(
      backgroundColor: colors.noturno,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            NotificationListener<ScrollNotification>(
              onNotification: _onScrollNotification,
              child: CustomScrollView(
                controller: _scrollController,
                center: _centerKey,
                slivers: [
                  // Posts anteriores ao tocado. Esta lista cresce para cima a
                  // partir do centro: o item 0 é o post logo acima do tocado.
                  // O último item é o espaço do cabeçalho, no topo de tudo.
                  SliverList.builder(
                    itemCount: antes + 1,
                    itemBuilder: (context, i) {
                      if (i == antes) {
                        return const SizedBox(height: _headerHeight);
                      }
                      return _buildPost(_posts[antes - 1 - i], viewerId);
                    },
                  ),

                  // Do post tocado em diante.
                  SliverList.builder(
                    key: _centerKey,
                    itemCount: depois,
                    itemBuilder: (context, i) =>
                        _buildPost(_posts[_centerIndex + i], viewerId),
                  ),

                  SliverToBoxAdapter(
                    child: SizedBox(
                      height:
                          MediaQuery.paddingOf(context).bottom + AppSpacing.xl,
                    ),
                  ),
                ],
              ),
            ),

            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _PostsHeader(
                // BARRAS FLUTUANTES: desligado, sempre à vista.
                visible: _headerVisible || !floatingBars,
                height: _headerHeight,
                title: meus ? 'Meus Posts' : 'Posts',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Cabeçalho com o voltar e o título, no lugar do voltar flutuante que cada
/// post tinha.
///
/// Mesma coreografia do cabeçalho do feed (e do dock): desliza para cima e
/// apaga ao descer, volta ao subir. O `ClipRect` faz ele sumir por trás da
/// barra de status em vez de desenhar por cima dela.
class _PostsHeader extends StatelessWidget {
  final bool visible;
  final double height;
  final String title;

  const _PostsHeader({
    required this.visible,
    required this.height,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
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
              color: colors.noturno,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: VibesterBackButton(),
                  ),
                  Text(
                    title,
                    style: context.typography.titleMedium.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Um post do feed do perfil: exatamente o bloco que o detalhe mostrava —
/// mídia 4:5 com duplo toque para curtir, curtidas, legenda e data —, sem o
/// voltar, que agora é um só, no cabeçalho.
///
/// Sem estado próprio: curtida e exclusão vivem na tela, que sobrevive ao
/// item sair e voltar da área visível.
class _PostItem extends StatelessWidget {
  final HighlightModel post;

  /// O ⋯ no canto superior direito da mídia. Fora enquanto a exclusão do
  /// post está em andamento.
  final bool showOptions;
  final VoidCallback onLike;
  final VoidCallback onOptions;

  const _PostItem({
    super.key,
    required this.post,
    required this.showOptions,
    required this.onLike,
    required this.onOptions,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.typography;
    final dataFormatada = _formatarData(post.criadoEm);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          children: [
            AspectRatio(
              aspectRatio: 4 / 5,
              child: DoubleTapLike(
                onLike: () {
                  if (!post.curtidoPeloUsuario) onLike();
                },
                child: PostMediaCarousel(media: post.midias),
              ),
            ),
            // Toda ação sobre o post — excluir, denunciar, bloquear — entra
            // por aqui: um ⋯ só, no mesmo canto, seja o post de quem for.
            if (showOptions)
              Positioned(
                top: AppSpacing.sm,
                right: AppSpacing.lg,
                child: _FloatingButton(
                  icon: Icons.more_horiz_rounded,
                  label: 'Opções da publicação',
                  onTap: onOptions,
                ),
              ),
          ],
        ),

        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.screen,
            AppSpacing.xs,
            AppSpacing.screen,
            AppSpacing.huge,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Action(
                icon: LikeHeart(
                  liked: post.curtidoPeloUsuario,
                  inactiveColor: colors.textSecondary,
                  size: 22,
                ),
                value: post.totalCurtidas,
                active: post.curtidoPeloUsuario,
                semanticLabel: post.curtidoPeloUsuario ? 'Descurtir' : 'Curtir',
                onTap: onLike,
              ),

              if (post.legenda.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  post.legenda,
                  style: type.bodyLarge.copyWith(color: colors.textPrimary),
                ),
              ],

              if (dataFormatada.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  dataFormatada.toUpperCase(),
                  style: type.monoMicro.copyWith(color: colors.textDisabled),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

String _formatarData(String isoDate) {
  if (isoDate.isEmpty) return '';
  try {
    final data = DateTime.parse(isoDate);
    return DateFormat("d 'de' MMMM 'de' y", 'pt_BR').format(data);
  } catch (_) {
    return '';
  }
}

class _FloatingButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _FloatingButton({required this.icon, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: VibesterPressable(
        onTap: onTap,
        borderRadius: AppRadius.pillAll,
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: context.colors.scrim.withValues(alpha: 0.55),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
          ),
          child: Icon(icon, size: 20, color: Colors.white),
        ),
      ),
    );
  }
}

/// Ação com contador (curtir, comentar). Contador em DM Mono; alvo de 44px
/// mesmo com o ícone pequeno.
class _Action extends StatelessWidget {
  final Widget icon;
  final int value;
  final bool active;
  final String? semanticLabel;
  final VoidCallback? onTap;

  const _Action({
    required this.icon,
    required this.value,
    this.active = false,
    this.semanticLabel,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? context.colors.brasa : context.colors.textSecondary;

    return Semantics(
      button: onTap != null,
      label: semanticLabel,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          height: 44,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              icon,
              const SizedBox(width: AppSpacing.sm),
              Text(
                value.toString().padLeft(2, '0'),
                style: context.typography.mono.copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}