import 'package:flutter/material.dart';
import 'package:mobile/models/feed/publication_model.dart';
import 'package:mobile/models/media/post_media.dart';
import 'package:mobile/models/safety/report_reason.dart';
import 'package:mobile/providers/feed/publication_list_provider.dart';
import 'package:mobile/providers/user/user_provider.dart';
import 'package:mobile/routes/app_routes.dart';
import 'package:mobile/theme/app_spacing.dart';
import 'package:mobile/theme/theme_extensions.dart';
import 'package:mobile/utils/relative_time.dart';
import 'package:mobile/utils/username.dart';
import 'package:mobile/widgets/cards/feed/delete_post_action.dart';
import 'package:mobile/widgets/common/vibester_image.dart';
import 'package:mobile/widgets/indicators/like_indicator.dart';
import 'package:mobile/widgets/media/post_media_carousel.dart';
import 'package:mobile/widgets/motion/double_tap_like.dart';
import 'package:mobile/widgets/motion/vibester_pressable.dart';
import 'package:mobile/widgets/safety/report_sheet.dart';
import 'package:mobile/widgets/safety/safety_actions.dart';
import 'package:provider/provider.dart';

/// Publicação no feed.
///
/// O feed é a parte do produto com maior risco de virar cópia de outra rede:
/// a estrutura avatar → foto → curtida é praticamente universal. A saída aqui
/// não foi inventar uma estrutura estranha (o usuário sabe ler feed, e mexer
/// nisso custaria usabilidade por nada), e sim mudar a **matéria**: a foto é
/// tratada como um retrato colado no muro — levemente torta, com sombra dura
/// de papel e grão por cima — e não como uma placa de vidro dentro de um
/// cartão branco.
///
/// A inclinação é minúscula (menos de 1°) e determinística pelo índice do
/// item: alterna de lado a cada post, então a coluna ganha ritmo sem parecer
/// bagunça, e o mesmo post nunca "muda de posição" ao rolar de volta.
///
/// O selo de local não é enfeite: quando o post veio de um estabelecimento,
/// ele é o atalho para a página dele — é o que costura a rede social à
/// descoberta, que é a razão de o Vibester ter as duas coisas.
///
/// LOCAL: o selo saiu de cima da foto e foi para uma linha própria logo
/// abaixo da linha de autoria (avatar + @), antes da mídia. Sobre a foto ele
/// disputava espaço com a imagem e com as bolinhas do carrossel; aqui ele é
/// lido junto de quem postou — "quem" e "onde" no mesmo bloco — e a foto
/// fica limpa.
///
/// LOCAL CLICÁVEL: tocar no local abre a página do estabelecimento — agora o
/// modelo guarda o id dele ([PublicationModel.establishmentId]), que antes se
/// perdia na conversão do item de feed. Post com o nome mas sem o id (antigo,
/// ou recém-publicado se a API não devolver o id) mostra o local sem toque.
class PublicationCard extends StatelessWidget {
  final PublicationModel publication;

  /// Posição na lista, usada para a inclinação alternada.
  final int index;

  /// Disparado junto com a navegação para o perfil do autor.
  ///
  /// O card não fala com a telemetria: quem sabe a posição do item na lista e
  /// a superfície em que ele apareceu é quem o montou.
  final VoidCallback? onAuthorTap;

  const PublicationCard({
    super.key,
    required this.publication,
    this.index = 0,
    this.onAuthorTap,
  });

  double get _tilt => (index.isEven ? 1 : -1) * 0.0055;

  /// Toque duplo na foto só curte — se já está curtido, o coração grande
  /// aparece mas nada vai para a API.
  void _likeFromPhoto(BuildContext context) {
    if (publication.isLiked) return;
    final userId = context.read<UserProvider>().user?.accountId;
    if (userId == null) return;
    context.read<PublicationListProvider>().toggleLike(publication.id, userId);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.typography;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screen,
        AppSpacing.md,
        AppSpacing.screen,
        AppSpacing.xxl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AuthorLine(publication: publication, onAuthorTap: onAuthorTap),

          // LOCAL: logo abaixo do avatar e do @, alinhado à margem esquerda.
          //
          // LOCAL CLICÁVEL: o respiro acima da linha (xs) e parte do de baixo
          // (sm) passaram para dentro dela, como padding — viram área de
          // toque em vez de espaço morto. O espaçamento visto na tela é o
          // mesmo de antes: xs acima, sm + xs = md abaixo.
          if (publication.location != null &&
              publication.location!.isNotEmpty) ...[
            _PlaceLine(
              place: publication.location!,
              onTap: publication.establishmentId == null
                  ? null
                  : () => Navigator.pushNamed(
                      context,
                      AppRoutes.placeDetail,
                      arguments: publication.establishmentId,
                    ),
            ),
            const SizedBox(height: AppSpacing.xs),
          ] else
            const SizedBox(height: AppSpacing.md),

          Transform.rotate(
            angle: _tilt,
            child: Container(
              decoration: BoxDecoration(
                boxShadow: [
                  // Sombra dura, sem desfoque: papel sobre parede.
                  BoxShadow(
                    color: colors.scrim.withValues(alpha: 0.5),
                    offset: const Offset(5, 5),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(AppRadius.sm),
                  topRight: Radius.circular(AppRadius.sm),
                  bottomRight: Radius.circular(AppRadius.sm),
                ),
                child: AspectRatio(
                  aspectRatio: 4 / 5,
                  // LOCAL: aqui havia um `Stack` com a mídia e o selo de local
                  // posicionado no canto inferior esquerdo. Com o selo fora
                  // da foto, sobrou só a mídia, e o `Stack` saiu junto.
                  child: DoubleTapLike(
                    onLike: () => _likeFromPhoto(context),
                    // Foto, vídeo ou carrossel — na ordem de `media`. As
                    // bolinhas ficam na base e o contador no topo.
                    child: PostMediaCarousel(
                      media: publication.media.isNotEmpty
                          ? publication.media
                          : [
                              if (publication.publicationImage.isNotEmpty)
                                PostMedia.image(publication.publicationImage),
                            ],
                      grain: true,
                      counterOnTop: true,
                    ),
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: AppSpacing.md),

          if (publication.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Text(
                publication.description,
                style: type.bodyLarge.copyWith(color: colors.textSecondary),
              ),
            ),

          Row(
            children: [
              LikeIndicator(publication: publication),
              const Spacer(),
              Text(
                formatRelativeTime(publication.publicatedAt).toUpperCase(),
                style: type.monoMicro.copyWith(color: colors.textDisabled),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// LOCAL: linha do lugar marcado, abaixo da linha de autoria.
///
/// Só ícone e texto, sem caixa em volta: o pino em `brasa` é o que marca a
/// linha como "lugar", e o nome vai em DM Mono caixa alta no tom apagado de
/// metadado. A primeira versão tinha o contorno fino do `VibesterTag`
/// `outline`, e a borda pesava demais logo abaixo do avatar — saiu.
///
/// Não usa o `VibesterTag` por um motivo: o texto dele não quebra nem corta,
/// e nome de estabelecimento pode ser comprido ("Espaço Cultural e
/// Gastronômico ..."). Sobre a foto isso passava despercebido; numa linha da
/// largura do card, estouraria a tela. Aqui o nome corta com reticências.
class _PlaceLine extends StatelessWidget {
  final String place;

  /// LOCAL CLICÁVEL: abre a página do estabelecimento. Nulo quando o post não
  /// traz o id — a linha aparece igual, só sem toque.
  final VoidCallback? onTap;

  const _PlaceLine({required this.place, this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;

    // Sem caixa, sem padding lateral: o pino começa na mesma margem do
    // avatar, em vez de ficar recuado pelo respiro de uma borda que não
    // existe mais.
    //
    // LOCAL CLICÁVEL: o padding vertical é o respiro que antes ficava fora da
    // linha (ver o `build` do card); aqui dentro ele engorda a área de toque
    // sem mudar nada do que se vê.
    final line = Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs, bottom: AppSpacing.sm),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.place_outlined, size: 11, color: colors.brasa),
          const SizedBox(width: AppSpacing.xs + 1),
          Flexible(
            child: Text(
              place.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.typography.monoTag.copyWith(
                color: colors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );

    if (onTap == null) {
      return Semantics(
        label: 'Local: $place',
        excludeSemantics: true,
        child: line,
      );
    }

    // LOCAL CLICÁVEL: mesmo `VibesterPressable` do autor logo acima — mesma
    // compressão no toque —, sem sublinhado nem cor de link: o pino em
    // `brasa` já diz que ali tem um lugar, como o avatar diz que ali tem uma
    // pessoa.
    return Semantics(
      button: true,
      label: 'Abrir $place',
      excludeSemantics: true,
      child: VibesterPressable(
        borderRadius: AppRadius.smAll,
        onTap: onTap,
        child: line,
      ),
    );
  }
}

enum _PostOption { delete, report, block }

/// Linha de autoria: avatar, @ e o menu de opções — excluir no post do próprio
/// usuário; denunciar e bloquear no post de outra pessoa.
class _AuthorLine extends StatelessWidget {
  final PublicationModel publication;
  final VoidCallback? onAuthorTap;

  const _AuthorLine({required this.publication, this.onAuthorTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.typography;

    final viewerId = context.select<UserProvider, String?>(
      (p) => p.user?.accountId,
    );
    final isOwn =
        viewerId != null &&
        publication.id != null &&
        publication.authorId == viewerId;
    // Denunciar/bloquear precisa de sessão e de saber de quem é o post.
    final canModerate =
        viewerId != null &&
        publication.id != null &&
        publication.authorId != null;

    return Row(
      // O ⋯ fica preso na borda direita, não importa o tamanho do @. Com
      // `Spacer` ele saía do lugar: `Spacer` é `Expanded` (flex apertado) e
      // disputava o espaço livre com o `Flexible` (flex solto) do autor —
      // cada um ficava com metade, então o chip encolhia até o @ caber, o
      // vazio continuava valendo metade da linha, e o botão parava a meio
      // caminho. Sem ele, o autor é o único filho flexível: recebe todo o
      // espaço que sobra do botão e o alinhamento empurra o ⋯ para o fim.
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: VibesterPressable(
            borderRadius: AppRadius.pillAll,
            onTap: publication.authorId == null
                ? null
                : () {
                    onAuthorTap?.call();
                    Navigator.pushNamed(
                      context,
                      AppRoutes.otherProfile,
                      arguments: publication.authorId,
                    );
                  },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipOval(
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: VibesterImage(
                      source: publication.autorProfileImage,
                      placeholderIcon: Icons.person_outline_rounded,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Flexible(
                  child: Text(
                    publication.autor.isEmpty
                        ? 'Alguém'
                        : formatHandle(publication.autor),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.titleSmall.copyWith(color: colors.textPrimary),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (canModerate)
          PopupMenuButton<_PostOption>(
            tooltip: 'Opções da publicação',
            color: colors.surfaceRaised,
            icon: Icon(Icons.more_horiz_rounded, color: colors.textMuted),
            onSelected: (option) => switch (option) {
              _PostOption.delete => confirmAndDeletePost(
                context,
                postId: publication.id!,
              ),
              _PostOption.report => showReportSheet(
                context,
                targetType: ReportTargetType.post,
                targetId: publication.id!,
                targetOwnerId: publication.authorId,
              ),
              _PostOption.block => confirmAndBlockUser(
                context,
                accountId: publication.authorId!,
                displayName: formatHandle(publication.autor),
              ),
            },
            itemBuilder: (_) => [
              if (isOwn)
                _menuItem(
                  context,
                  _PostOption.delete,
                  Icons.delete_outline_rounded,
                  'Excluir publicação',
                )
              else ...[
                _menuItem(
                  context,
                  _PostOption.report,
                  Icons.flag_outlined,
                  'Denunciar publicação',
                ),
                _menuItem(
                  context,
                  _PostOption.block,
                  Icons.block_rounded,
                  'Bloquear perfil',
                ),
              ],
            ],
          ),
      ],
    );
  }

  PopupMenuItem<_PostOption> _menuItem(
    BuildContext context,
    _PostOption value,
    IconData icon,
    String label,
  ) {
    final color = context.colors.error;
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: AppSpacing.md),
          Text(
            label,
            style: context.typography.titleSmall.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}