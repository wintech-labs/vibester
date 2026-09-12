import 'package:flutter/material.dart';
import 'package:mobile/theme/app_spacing.dart';
import 'package:mobile/theme/theme_extensions.dart';

/// Voz visual da tag.
enum TagTone {
  /// Sobre foto: fundo escuro semitransparente, texto branco. É a mais usada
  /// — metadado de card sobre imagem.
  onPhoto,

  /// Sobre superfície: contorno fino, texto apagado. Metadado silencioso.
  outline,

  /// Marca: preenchida em `ambar`. Categoria/atributo que o usuário escolheu.
  brand,

  /// Urgente: preenchida em `brasa`. "AGORA", "HOJE", "ÚLTIMAS".
  live,
}

/// **Tag → contexto.**
///
/// A etiqueta de sistema do Vibester: sempre DM Mono, sempre caixa alta,
/// sempre curta. Carrega data, hora, distância, categoria, preço, movimento —
/// a informação que o usuário lê *depois* de decidir olhar o card.
///
/// Diferente de `StickerTag` (torta, com sombra dura, uma por composição),
/// esta é reta e silenciosa: pode aparecer em série sem poluir.
class VibesterTag extends StatelessWidget {
  final String label;
  final TagTone tone;
  final IconData? icon;

  /// Ponto colorido antes do texto — usado por [TagTone.live] e por
  /// indicadores de estado (movimento do estabelecimento, por exemplo).
  final Color? dotColor;

  const VibesterTag(
    this.label, {
    super.key,
    this.tone = TagTone.onPhoto,
    this.icon,
    this.dotColor,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;

    final (
      Color background,
      Color foreground,
      Color? borderColor,
    ) = switch (tone) {
      TagTone.onPhoto => (
        colors.scrim.withValues(alpha: 0.55),
        Colors.white,
        null,
      ),
      TagTone.outline => (Colors.transparent, colors.textMuted, colors.outline),
      TagTone.brand => (colors.ambar, colors.onAmbar, null),
      TagTone.live => (colors.live, colors.onFill(colors.live), null),
    };

    final dot = dotColor ?? (tone == TagTone.live ? foreground : null);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs + 1,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: AppRadius.stickerAll,
        border: borderColor == null
            ? null
            : Border.all(color: borderColor, width: AppStroke.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot != null) ...[
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: AppSpacing.xs + 1),
          ],
          if (icon != null) ...[
            Icon(icon, size: 11, color: foreground),
            const SizedBox(width: AppSpacing.xs + 1),
          ],
          Text(
            label.toUpperCase(),
            style: context.typography.monoTag.copyWith(color: foreground),
          ),
        ],
      ),
    );
  }
}