import 'package:flutter/material.dart';
import 'package:mobile/models/media/media_item.dart';
import 'package:mobile/models/place/place_model.dart';
import 'package:mobile/models/user/user_model.dart';
import 'package:mobile/providers/feed/publication_list_provider.dart';
import 'package:mobile/providers/notification/notification_provider.dart';
import 'package:mobile/providers/user/user_provider.dart';
import 'package:mobile/service/media/media_processor.dart';
import 'package:mobile/service/media_upload_service.dart';
import 'package:mobile/service/posts/post_service.dart';
import 'package:mobile/theme/app_motion.dart';
import 'package:mobile/theme/app_spacing.dart';
import 'package:mobile/theme/theme_extensions.dart';
import 'package:mobile/utils/clock_format.dart';
import 'package:mobile/utils/location_picker.dart';
import 'package:mobile/widgets/buttons/vibester_button.dart';
import 'package:mobile/widgets/common/vibester_image.dart';
import 'package:mobile/widgets/common/vibester_tag.dart';
import 'package:mobile/widgets/graffiti/grain.dart';
import 'package:mobile/widgets/media/media_controls.dart';
import 'package:mobile/widgets/media/media_flow.dart';
import 'package:mobile/widgets/motion/vibester_pressable.dart';
import 'package:provider/provider.dart';

/// Composer de publicação.
///
/// Era um formulário: `AppBar` com um ícone de "+", um seletor de foto, um
/// campo de legenda e um `ListTile` de local. Aqui é uma tela de composição —
/// a foto ocupa a maior parte do espaço, tratada como o retrato que vai ser
/// colado no feed (inclinação mínima, sombra dura, grão), e legenda e local
/// entram por baixo dela, na ordem em que a pessoa pensa: *isso aqui → o que
/// foi → onde foi*.
///
/// Duas correções de comportamento vieram junto, porque eram defeitos e não
/// estética:
///
/// * O local escolhido **agora é enviado**. Antes ele ficava numa variável
///   local e o `createPost` era chamado sem nenhum dos campos de
///   estabelecimento — marcar um lugar não produzia efeito nenhum.
/// * O erro exibido era `e.toString()` de uma exceção crua num `SnackBar`.
///   Agora mostra a mensagem tratada que o service já monta, e o `toString`
///   fica no `debugPrint`.
///
/// Fotos e vídeos vêm do `MediaFlow` (câmera do Vibester ou galeria, com
/// prévia) já processados: nada sobe até o toque em "Publicar", então mídia
/// removida nunca vira upload. A ordem da faixa de miniaturas é a ordem do
/// carrossel no feed — arrastar reordena.
class NewPublicationScreen extends StatefulWidget {
  const NewPublicationScreen({super.key});

  @override
  State<NewPublicationScreen> createState() => _NewPublicationScreenState();
}

class _NewPublicationScreenState extends State<NewPublicationScreen> {
  static const _captionLimit = 280;

  /// Limite do post-service por post.
  static const _maxMedia = 10;

  final _captionController = TextEditingController();
  final PostService _postService = PostService();

  List<MediaItem> _media = const [];

  /// Mídias já no R2 desde a última tentativa de publicar. Quando o
  /// post-service recusa o texto (422), a pessoa só corrige a legenda: sem
  /// isto, cada nova tentativa subia as mesmas fotos de novo e deixava as
  /// anteriores órfãs no bucket. Qualquer mudança em [_media] descarta.
  List<UploadedMedia>? _uploaded;

  /// Item mostrado no quadro grande.
  int _selected = 0;
  PlaceModel? _place;
  bool _publishing = false;

  @override
  void initState() {
    super.initState();
    _captionController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _captionController.dispose();
    // Publicado ou abandonado, o arquivo processado já não serve — exceto se
    // a pessoa saiu com o envio em andamento, que ainda está lendo dele.
    if (!_publishing) _media.forEach(MediaProcessor.discard);
    super.dispose();
  }

  bool get _canPublish => _media.isNotEmpty && !_publishing;

  Future<void> _addMedia() async {
    final room = _maxMedia - _media.length;
    if (room <= 0) return;
    final picked = await MediaFlow.pickMedia(context, maxItems: room);
    if (picked.isEmpty || !mounted) return;
    setState(() {
      _selected = _media.length;
      _media = [..._media, ...picked];
      _uploaded = null;
    });
  }

  void _remove(int index) {
    final removed = _media[index];
    setState(() {
      _media = [..._media]..removeAt(index);
      _uploaded = null;
      if (_selected >= _media.length) _selected = _media.length - 1;
      if (_selected < 0) _selected = 0;
    });
    MediaProcessor.discard(removed);
  }

  void _reorder(int from, int to) {
    if (to > from) to -= 1;
    final selectedItem = _media[_selected];
    setState(() {
      final list = [..._media];
      list.insert(to, list.removeAt(from));
      _media = list;
      _uploaded = null;
      _selected = list.indexOf(selectedItem);
    });
  }

  Future<void> _chooseLocation() async {
    final place = await showModalBottomSheet<PlaceModel>(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      builder: (_) => const LocationPicker(),
    );

    if (place != null) setState(() => _place = place);
  }

  Future<void> _publish(UserModel user) async {
    if (_media.isEmpty || _publishing) return;

    setState(() => _publishing = true);

    try {
      final uploaded = _uploaded ??= await _postService.uploadMedia(
        userId: user.userID.toString(),
        media: _media,
      );
      final created = await _postService.createPost(
        userVerified: false,
        userProfilePicture: user.fotoPerfil,
        userUsername: user.nomeUsuario,
        // O id do autor vem sempre do usuário em sessão, nunca de argumento
        // de rota — é a barreira do app contra publicar em nome de outro.
        userId: user.userID.toString(),
        media: uploaded,
        caption: _captionController.text.trim(),
        establishmentId: _place?.id,
        establishmentName: _place?.nome,
        establishmentLogo: _place?.profileImage,
        establishmentCategory: _place?.categoria,
      );
      // Envio concluído: o `dispose` já pode apagar os arquivos processados.
      _publishing = false;
      // O post entra no topo do feed antes de a tela fechar — é a confirmação
      // de que a publicação deu certo. O feed-service só o grava no feed do
      // autor depois, via Kafka — um refresh agora ainda viria sem ele.
      if (created != null && mounted) {
        final feed = context.read<PublicationListProvider>();
        feed.addOwnPublication(created);
        final postId = created.id;
        if (postId != null) {
          feed.watchModeration(
            postId,
            onRemoved: _moderationRemovalNotice(user),
          );
        }
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _publishing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e is Exception
                ? e.toString().replaceFirst('Exception: ', '')
                : 'Não foi possível publicar agora',
          ),
        ),
      );
      debugPrint('Falha ao publicar: $e');
    }
  }

  /// O que acontece quando a moderação de imagem remove o post, segundos
  /// depois de esta tela fechar.
  ///
  /// Tudo que precisa de `context` é lido agora: o `ScaffoldMessenger` é o do
  /// `MaterialApp`, que continua vivo e mostra o aviso sobre a tela em que a
  /// pessoa estiver. O motivo detalhado fica na notificação `post_rejected`
  /// que o notification-service grava — por isso o sino é atualizado junto.
  VoidCallback _moderationRemovalNotice(UserModel author) {
    final messenger = ScaffoldMessenger.of(context);
    final notifications = context.read<NotificationProvider>();
    final session = context.read<UserProvider>();
    final accountId = author.accountId;

    return () {
      // Saiu da conta (ou trocou) enquanto a checagem corria: o aviso é de
      // outra sessão.
      if (accountId == null || session.user?.accountId != accountId) return;

      notifications.markStale();
      notifications.fetchUnreadCount(accountId);
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Sua publicação foi removida por não seguir as diretrizes da '
            'comunidade. O motivo está nas notificações.',
          ),
        ),
      );
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.typography;
    final user = context.read<UserProvider>().user;

    return Scaffold(
      backgroundColor: colors.noturno,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Column(
          children: [
            // Cabeçalho da composição: sair à esquerda, publicar à direita.
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.screen,
                AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Semantics(
                    button: true,
                    label: 'Cancelar',
                    child: VibesterPressable(
                      onTap: () => Navigator.maybePop(context),
                      borderRadius: AppRadius.pillAll,
                      child: SizedBox(
                        width: 44,
                        height: 44,
                        child: Icon(
                          Icons.close_rounded,
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      'NOVO ROLÊ',
                      style: type.monoEyebrow.copyWith(color: colors.textMuted),
                    ),
                  ),
                  SizedBox(
                    width: 132,
                    child: VibesterButton(
                      label: 'Publicar',
                      compact: true,
                      state: _publishing
                          ? VibesterButtonState.loading
                          : VibesterButtonState.idle,
                      onPressed: _canPublish && user != null
                          ? () => _publish(user)
                          : null,
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.screen,
                  AppSpacing.sm,
                  AppSpacing.screen,
                  AppSpacing.xxl,
                ),
                children: [
                  _MediaSlot(
                    item: _media.isEmpty ? null : _media[_selected],
                    position: _selected,
                    total: _media.length,
                    onAdd: _addMedia,
                    onRemove: () => _remove(_selected),
                  ),
                  if (_media.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.lg),
                    _MediaStrip(
                      media: _media,
                      selected: _selected,
                      canAdd: _media.length < _maxMedia,
                      onSelect: (i) => setState(() => _selected = i),
                      onReorder: _reorder,
                      onAdd: _addMedia,
                    ),
                  ],

                  const SizedBox(height: AppSpacing.xl),

                  Text(
                    'LEGENDA',
                    style: type.monoEyebrow.copyWith(color: colors.textMuted),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextField(
                    controller: _captionController,
                    maxLines: 4,
                    maxLength: _captionLimit,
                    cursorColor: colors.ambar,
                    style: type.bodyLarge.copyWith(color: colors.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'Conta como foi…',
                      hintStyle: type.bodyLarge.copyWith(
                        color: colors.textDisabled,
                      ),
                      counterText: '',
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '${_captionController.text.characters.length}/$_captionLimit',
                      style: type.monoMicro.copyWith(
                        color:
                            _captionController.text.characters.length >
                                _captionLimit - 20
                            ? colors.brasa
                            : colors.textDisabled,
                      ),
                    ),
                  ),

                  const SizedBox(height: AppSpacing.lg),
                  Divider(color: colors.hairline, height: 1),

                  _PlaceRow(place: _place, onTap: _chooseLocation),
                  if (_place != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: VibesterPressable(
                        onTap: () => setState(() => _place = null),
                        borderRadius: AppRadius.pillAll,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: AppSpacing.sm,
                          ),
                          child: Text(
                            'REMOVER LOCAL',
                            style: type.monoMicro.copyWith(
                              color: colors.textDisabled,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Quadro grande. Vazio, é um bloco de parede convidando ao toque;
/// preenchido, é o item selecionado já do jeito que vai aparecer no feed —
/// retrato torto, sombra dura, grão — com o selo de vídeo quando for vídeo.
class _MediaSlot extends StatelessWidget {
  final MediaItem? item;
  final int position;
  final int total;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  const _MediaSlot({
    required this.item,
    required this.position,
    required this.total,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final item = this.item;

    if (item == null) {
      return Semantics(
        button: true,
        label: 'Adicionar foto ou vídeo',
        excludeSemantics: true,
        child: VibesterPressable(
          onTap: onAdd,
          borderRadius: AppRadius.mdAll,
          child: AspectRatio(
            aspectRatio: 4 / 5,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: AppRadius.mdAll,
                border: Border.all(color: colors.outline),
              ),
              child: Grain(
                opacity: 0.06,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.add_a_photo_outlined,
                      size: 30,
                      color: colors.ambar,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      'TOCA PRA ESCOLHER FOTO OU VÍDEO',
                      textAlign: TextAlign.center,
                      style: context.typography.monoSmall.copyWith(
                        color: colors.textMuted,
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

    return AspectRatio(
      aspectRatio: 4 / 5,
      child: Transform.rotate(
        angle: -0.006,
        child: Container(
          decoration: BoxDecoration(
            boxShadow: [
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
            child: Stack(
              fit: StackFit.expand,
              children: [
                AnimatedSwitcher(
                  duration: context.adaptiveMotion(AppMotion.micro),
                  child: VibesterImage(
                    key: ValueKey(item.coverPath),
                    source: item.coverPath,
                  ),
                ),
                const Grain(opacity: 0.05, density: 0.35),
                if (item.isVideo)
                  Center(
                    child: Icon(
                      Icons.play_circle_outline_rounded,
                      size: 56,
                      color: colors.textPrimary.withValues(alpha: 0.9),
                    ),
                  ),
                Positioned(
                  left: AppSpacing.md,
                  top: AppSpacing.md,
                  child: Row(
                    children: [
                      if (total > 1) VibesterTag('${position + 1}/$total'),
                      if (total > 1 && item.isVideo)
                        const SizedBox(width: AppSpacing.xs),
                      if (item.isVideo)
                        VibesterTag(
                          item.duration == null
                              ? 'VÍDEO'
                              : formatClock(item.duration!),
                          icon: Icons.videocam_outlined,
                        ),
                    ],
                  ),
                ),
                Positioned(
                  right: AppSpacing.sm,
                  top: AppSpacing.sm,
                  child: MediaRoundButton(
                    icon: Icons.close_rounded,
                    semanticLabel: item.isVideo
                        ? 'Remover este vídeo'
                        : 'Remover esta foto',
                    size: 44,
                    onTap: onRemove,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Faixa de miniaturas: tocar mostra no quadro, segurar e arrastar muda a
/// ordem do carrossel, e o "+" no fim adiciona mais.
class _MediaStrip extends StatelessWidget {
  static const _thumbWidth = 64.0;
  static const _thumbHeight = 80.0;

  final List<MediaItem> media;
  final int selected;
  final bool canAdd;
  final ValueChanged<int> onSelect;
  final ReorderCallback onReorder;
  final VoidCallback onAdd;

  const _MediaStrip({
    required this.media,
    required this.selected,
    required this.canAdd,
    required this.onSelect,
    required this.onReorder,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: _thumbHeight,
          child: ReorderableListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: media.length,
            onReorder: onReorder,
            proxyDecorator: (child, _, _) =>
                Material(color: Colors.transparent, child: child),
            footer: canAdd
                ? Semantics(
                    button: true,
                    label: 'Adicionar mais',
                    excludeSemantics: true,
                    child: VibesterPressable(
                      onTap: onAdd,
                      borderRadius: AppRadius.smAll,
                      child: Container(
                        width: _thumbWidth,
                        height: _thumbHeight,
                        decoration: BoxDecoration(
                          color: colors.surface,
                          borderRadius: AppRadius.smAll,
                          border: Border.all(color: colors.outline),
                        ),
                        child: Icon(Icons.add_rounded, color: colors.ambar),
                      ),
                    ),
                  )
                : null,
            itemBuilder: (context, i) {
              final item = media[i];
              final isSelected = i == selected;
              return Padding(
                key: ValueKey(item.path),
                padding: const EdgeInsets.only(right: AppSpacing.sm),
                child: Semantics(
                  button: true,
                  selected: isSelected,
                  label:
                      '${item.isVideo ? 'Vídeo' : 'Foto'} ${i + 1} de ${media.length}. '
                      'Segura e arrasta pra mudar a ordem',
                  excludeSemantics: true,
                  child: GestureDetector(
                    onTap: () => onSelect(i),
                    child: AnimatedContainer(
                      duration: context.adaptiveMotion(AppMotion.micro),
                      width: _thumbWidth,
                      height: _thumbHeight,
                      decoration: BoxDecoration(
                        borderRadius: AppRadius.smAll,
                        border: Border.all(
                          color: isSelected ? colors.ambar : colors.hairline,
                          width: isSelected
                              ? AppStroke.marker
                              : AppStroke.hairline,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.sm - 2),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            VibesterImage(source: item.coverPath),
                            if (item.isVideo)
                              Positioned(
                                left: AppSpacing.xs,
                                bottom: AppSpacing.xs,
                                child: Icon(
                                  Icons.videocam_rounded,
                                  size: 14,
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
            },
          ),
        ),
        if (media.length > 1) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            'SEGURA E ARRASTA PRA MUDAR A ORDEM',
            style: context.typography.monoMicro.copyWith(
              color: colors.textDisabled,
            ),
          ),
        ],
      ],
    );
  }
}

class _PlaceRow extends StatelessWidget {
  final PlaceModel? place;
  final VoidCallback onTap;

  const _PlaceRow({required this.place, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final selected = place != null;

    return VibesterPressable(
      onTap: onTap,
      borderRadius: AppRadius.mdAll,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
        child: Row(
          children: [
            Icon(
              Icons.place_outlined,
              size: 20,
              color: selected ? colors.ambar : colors.textMuted,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                selected ? place!.nome : 'Marcar o lugar',
                style: context.typography.titleMedium.copyWith(
                  color: selected ? colors.textPrimary : colors.textMuted,
                ),
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: colors.textDisabled,
            ),
          ],
        ),
      ),
    );
  }
}
