import 'package:flutter/material.dart';
import 'package:mobile/models/notification/notification_model.dart';
import 'package:mobile/theme/app_spacing.dart';
import 'package:mobile/theme/theme_extensions.dart';
import 'package:mobile/utils/relative_time.dart';
import 'package:mobile/widgets/common/vibester_image.dart';
import 'package:mobile/widgets/motion/vibester_pressable.dart';

/// Linha de notificação.
///
/// Deixou de ser um `Card` com borda e margem própria: numa lista de vinte
/// itens, vinte caixas empilhadas viram uma parede. Aqui é uma linha separada
/// por fio, e o "não lida" é marcado por uma barra em `brasa` na lateral —
/// posição fixa, alinhada com o avatar, em vez de um ponto que empurrava todo
/// o conteúdo para o lado quando aparecia.
class NotificationCard extends StatelessWidget {
  final NotificationModel notification;
  final VoidCallback? onTap;

  const NotificationCard({super.key, required this.notification, this.onTap});

  /// Aviso do próprio Vibester, não de outra pessoa: hoje só `post_rejected`,
  /// que chega quando a revalidação de conteúdo reprova um post já publicado.
  ///
  /// Sem este caso a linha saía quebrada — o `switch` de [_acao] não conhecia o
  /// tipo e devolvia texto vazio, e o ator (que o servidor manda nulo para
  /// aviso do sistema) virava "Alguém". O autor via "Alguém" e mais nada, sem
  /// o motivo que vem em `conteudo`.
  bool get _doSistema => notification.tipo == 'post_rejected';

  String get _nomeAtor {
    if (_doSistema) return 'Vibester';
    return (notification.atorNome?.isNotEmpty ?? false)
        ? notification.atorNome!
        : 'Alguém';
  }

  String get _acao {
    final plural = notification.outrosCount > 0;

    switch (notification.tipo) {
      case 'like':
        return plural ? 'curtiram sua publicação' : 'curtiu sua publicação';
      case 'comment':
        final conteudo = notification.conteudo;
        final trecho = conteudo.isNotEmpty ? ': "$conteudo"' : '';
        return plural
            ? 'comentaram sua publicação$trecho'
            : 'comentou sua publicação$trecho';
      case 'follow':
        return plural ? 'começaram a seguir você' : 'começou a seguir você';
      case 'post_rejected':
        // O texto inteiro — motivo e o que dá para fazer — já vem pronto do
        // servidor, em pt-BR.
        final conteudo = notification.conteudo;
        return conteudo.isNotEmpty
            ? conteudo
            : 'Sua publicação não segue as diretrizes da comunidade.';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.typography;

    // A miniatura também aparece no aviso de reprovação: é ela que diz ao
    // autor qual das publicações dele foi reprovada.
    //
    // Post apagado nunca mostra miniatura. Quando quem apagou foi a moderação
    // de imagem, a foto é justamente o que foi removido — e sem isto ela
    // voltaria a aparecer dentro da própria notificação (e nas curtidas
    // antigas daquele post). O servidor já deixa de mandar a URL; isto cobre
    // resposta antiga em cache e servidor de versão anterior.
    final hasThumbnail =
        (notification.tipo == 'like' ||
            notification.tipo == 'comment' ||
            _doSistema) &&
        !notification.postApagado &&
        (notification.postImagemUrl?.isNotEmpty ?? false);

    // Duplicata do mesmo aviso é agrupada pelo servidor e chegaria como
    // "e mais 1" — que não faz sentido quando o "ator" é o próprio Vibester.
    final mostraOutros = !_doSistema && notification.outrosCount > 0;

    return VibesterPressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screen,
          vertical: AppSpacing.md,
        ),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.hairline)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Barra de "não lida": ocupa espaço sempre, então a lista não
            // desloca quando as notificações são marcadas como vistas.
            Container(
              width: AppStroke.marker,
              height: 40,
              decoration: BoxDecoration(
                color: notification.lida ? Colors.transparent : colors.brasa,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: AppSpacing.md),

            ClipOval(
              child: SizedBox(
                width: 44,
                height: 44,
                // Aviso do sistema não tem rosto: fonte vazia cai no ícone.
                child: VibesterImage(
                  source: _doSistema ? '' : notification.atorAvatarUrl ?? '',
                  placeholderIcon: _doSistema
                      ? Icons.shield_outlined
                      : Icons.person_outline_rounded,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      style: type.bodyMedium.copyWith(
                        color: colors.textSecondary,
                      ),
                      children: [
                        TextSpan(
                          text: _nomeAtor,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: colors.textPrimary,
                          ),
                        ),
                        if (mostraOutros)
                          TextSpan(text: ' e mais ${notification.outrosCount}'),
                        TextSpan(text: ' $_acao'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    formatRelativeTime(notification.criadoEm).toUpperCase(),
                    style: type.monoMicro.copyWith(color: colors.textDisabled),
                  ),
                ],
              ),
            ),

            if (hasThumbnail) ...[
              const SizedBox(width: AppSpacing.md),
              ClipRRect(
                borderRadius: AppRadius.stickerAll,
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: VibesterImage(
                    source: notification.postImagemUrl!,
                    placeholderIcon: Icons.photo_outlined,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
