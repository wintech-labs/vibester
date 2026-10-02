import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:mobile/theme/app_motion.dart';
import 'package:mobile/theme/app_spacing.dart';
import 'package:mobile/theme/theme_extensions.dart';
import 'package:mobile/widgets/navigation/navbar_tokens.dart';

/// Um destino da navbar.
class NavbarDestination {
  final IconData icon;
  final IconData activeIcon;

  /// Rótulo em DM Mono, visível só quando o destino está ativo.
  final String label;

  /// TAMANHO DO ÍCONE: tamanho próprio deste destino. Nulo usa o padrão da
  /// navbar ([NavbarTokens.iconSize]).
  ///
  /// Existe para ícones de outra família, como os do Font Awesome: os ícones
  /// do Material têm uma margem interna no desenho, e os do Font Awesome
  /// ocupam o quadrado inteiro — no mesmo tamanho, parecem maiores que os
  /// vizinhos. Um valor menor aqui equilibra o peso visual.
  final double? iconSize;

  const NavbarDestination({
    required this.icon,
    required this.activeIcon,
    required this.label,
    this.iconSize,
  });
}

/// Item tocável da navbar, com três animações que se somam sem brigar:
///
/// * **toque** — comprime para 0.92 e volta com mola, respondendo em ~130ms,
///   antes de a navegação acontecer. Feedback que espera a tela trocar chega
///   tarde demais para ser lido como resposta ao dedo.
/// * **seleção** — um pulso curto (1.0 → 1.12 → 1.0) quando o item *passa* a
///   ser o ativo. Dispara na transição, não enquanto ele estiver ativo: um
///   ícone que pulsa sozinho para sempre cansa.
/// * **entrada** — fade e subida escalonados, orquestrados pela navbar.
///
/// O rótulo só existe no destino ativo. Quatro pares ícone+texto permanentes
/// são a definição de navegação genérica; aqui o texto aparece onde o usuário
/// está, e o estado ativo deixa de depender só de cor — que é também o que
/// resolve acessibilidade para quem não distingue o âmbar do cinza.
class NavbarItem extends StatefulWidget {
  final NavbarDestination destination;
  final bool active;
  final VoidCallback onTap;
  final double width;

  /// Progresso de entrada deste item (0 a 1), vindo da navbar.
  final double entrance;

  /// Contador de não lidas. Zero esconde o selo.
  final int badgeCount;

  const NavbarItem({
    super.key,
    required this.destination,
    required this.active,
    required this.onTap,
    required this.width,
    this.entrance = 1,
    this.badgeCount = 0,
  });

  @override
  State<NavbarItem> createState() => _NavbarItemState();
}

class _NavbarItemState extends State<NavbarItem> with TickerProviderStateMixin {
  /// Escala do toque. O intervalo passa de 1.0 porque a volta tem overshoot.
  late final AnimationController _press = AnimationController(
    vsync: this,
    value: 1,
    lowerBound: 0.8,
    upperBound: 1.2,
  );

  /// Pulso de seleção, disparado uma vez por transição.
  late final AnimationController _select = AnimationController(
    vsync: this,
    duration: NavbarTokens.select,
  );

  static final _pulse = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(
        begin: 1.0,
        end: NavbarTokens.activeScale,
      ).chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 45,
    ),
    TweenSequenceItem(
      tween: Tween(
        begin: NavbarTokens.activeScale,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.easeOutBack)),
      weight: 55,
    ),
  ]);

  @override
  void didUpdateWidget(covariant NavbarItem old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active && !context.reduceMotion) {
      _select.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _press.dispose();
    _select.dispose();
    super.dispose();
  }

  void _animatePress(bool pressed) {
    if (context.reduceMotion) {
      _press.value = 1;
      return;
    }

    _press.animateWith(
      SpringSimulation(
        pressed ? AppMotion.springPress : AppMotion.springBouncy,
        _press.value,
        pressed ? NavbarTokens.pressScale : 1.0,
        pressed ? 0 : 2.4, // velocidade inicial gera o overshoot ao soltar
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final foreground = widget.active ? colors.ambar : colors.textMuted;

    return Semantics(
      button: true,
      selected: widget.active,
      label: widget.destination.label,
      child: GestureDetector(
        onTap: widget.onTap,
        onTapDown: (_) => _animatePress(true),
        onTapUp: (_) => _animatePress(false),
        onTapCancel: () => _animatePress(false),
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: widget.width,
          height: NavbarTokens.height,
          child: Opacity(
            // Entrada escalonada: sobe e aparece.
            opacity: widget.entrance.clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, (1 - widget.entrance) * 10),
              child: AnimatedBuilder(
                animation: Listenable.merge([_press, _select]),
                builder: (context, child) => Transform.scale(
                  scale: _press.value * _pulse.evaluate(_select),
                  child: child,
                ),
                child: _Content(
                  destination: widget.destination,
                  active: widget.active,
                  foreground: foreground,
                  badgeCount: widget.badgeCount,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Content extends StatelessWidget {
  final NavbarDestination destination;
  final bool active;
  final Color foreground;
  final int badgeCount;

  const _Content({
    required this.destination,
    required this.active,
    required this.foreground,
    required this.badgeCount,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            // Contorno → preenchido com morph curto, em vez de a forma do
            // ícone saltar de um frame para o outro.
            AnimatedSwitcher(
              duration: context.adaptiveMotion(NavbarTokens.press),
              transitionBuilder: (child, animation) => ScaleTransition(
                scale: animation,
                child: FadeTransition(opacity: animation, child: child),
              ),
              child: Icon(
                active ? destination.activeIcon : destination.icon,
                key: ValueKey(active),
                // TAMANHO DO ÍCONE: o do destino, quando ele define um.
                size: destination.iconSize ?? NavbarTokens.iconSize,
                // Sem brilho no ícone: o destaque do item ativo é a cor de
                // fundo da cápsula e mais nada.
                color: foreground,
              ),
            ),
            if (badgeCount > 0)
              Positioned(top: -2, right: -6, child: _Badge(count: badgeCount)),
          ],
        ),

        // O rótulo entra pela altura, não só por opacidade: o espaço é
        // reservado pela animação, então o ícone não pula quando ele aparece.
        AnimatedSize(
          duration: context.adaptiveMotion(NavbarTokens.select),
          curve: AppMotion.standard,
          child: active
              ? Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: MediaQuery.withClampedTextScaling(
                    // O rótulo tem 9px e vive numa barra de altura fixa;
                    // acompanhar text scaling sem teto estouraria a barra.
                    maxScaleFactor: 1.3,
                    // Excluído da semântica: o `Semantics` do item já anuncia
                    // este mesmo texto. Sem isso o leitor de tela lê o
                    // destino ativo duas vezes ("FEED, FEED").
                    child: ExcludeSemantics(
                      child: Text(
                        destination.label,
                        style: context.typography.monoMicro.copyWith(
                          color: colors.ambar,
                        ),
                      ),
                    ),
                  ),
                )
              : const SizedBox(width: 0, height: 0),
        ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  final int count;

  const _Badge({required this.count});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      constraints: const BoxConstraints(minWidth: 15, minHeight: 15),
      decoration: BoxDecoration(
        color: colors.brasa,
        borderRadius: AppRadius.pillAll,
        // O anel na cor da superfície separa o selo do ícone por trás.
        border: Border.all(color: colors.surfaceRaised, width: 1.5),
        boxShadow: [
          BoxShadow(color: colors.brasa.withValues(alpha: 0.45), blurRadius: 8),
        ],
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: context.typography.monoMicro.copyWith(
          color: colors.onBrasa,
          fontSize: 8,
        ),
      ),
    );
  }
}