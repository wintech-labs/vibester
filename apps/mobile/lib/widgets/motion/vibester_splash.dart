import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile/theme/app_colors.dart';
import 'package:mobile/theme/app_motion.dart';
import 'package:mobile/widgets/graffiti/grain.dart';

/// Segura o app atrás da abertura animada enquanto o boot termina.
///
/// Antes, o `main()` esperava storage seguro, tema e preferências **antes** do
/// `runApp`: nesse intervalo o Flutter não tinha quadro para pintar e o
/// aparelho mostrava tela preta até o feed surgir de repente. Agora o
/// `runApp` acontece na hora com a [VibesterSplash], o [boot] roda por trás e
/// o app é montado **embaixo** dela assim que o boot devolve os dados — o feed
/// já começa a carregar durante a animação e é revelado pronto na saída.
class SplashGate<T> extends StatefulWidget {
  /// Leitura do que o app precisa antes da primeira tela.
  final Future<T> boot;

  /// Monta o app com o resultado do [boot].
  final Widget Function(T data) builder;

  const SplashGate({super.key, required this.boot, required this.builder});

  @override
  State<SplashGate<T>> createState() => _SplashGateState<T>();
}

class _SplashGateState<T> extends State<SplashGate<T>> {
  late T _data;
  bool _ready = false;
  bool _splashGone = false;

  @override
  void initState() {
    super.initState();
    widget.boot.then(
      (data) {
        if (!mounted) return;
        setState(() {
          _data = data;
          _ready = true;
        });
      },
      onError: (Object error, StackTrace stack) {
        // Mesmo destino de uma exceção no `main()` antigo: o relatório de erro
        // do framework. A abertura continua pulsando em vez de fechar sobre
        // um app que não existe.
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'vibester boot',
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Chave fixa: o app não pode ser remontado quando a abertura sai da
          // árvore, senão providers e navegação nasceriam de novo.
          if (_ready)
            KeyedSubtree(
              key: const ValueKey('app'),
              child: widget.builder(_data),
            ),
          if (!_splashGone)
            VibesterSplash(
              ready: _ready,
              onFinished: () => setState(() => _splashGone = true),
            ),
        ],
      ),
    );
  }
}

/// Abertura do app: o logotipo gigante em néon, com o degradê da marca
/// correndo por dentro das letras e piscando como letreiro acendendo.
///
/// Sempre no papel escuro, independente do tema: é o mesmo `noturno` da tela
/// nativa de abertura (LaunchScreen.storyboard / launch_background.xml), então
/// a troca do nativo para o Flutter não tem costura. Por isso usa
/// [AppColors.dark] direto — o tema do usuário ainda está sendo lido quando
/// esta tela aparece.
///
/// Linha do tempo:
/// 1. **Acender** (~2s): o letreiro liga com tremulação de néon, entrando de
///    uma escala levemente maior; as manchas de spray acendem junto.
/// 2. **Pulsar** (enquanto o boot não termina): o degradê percorre as letras
///    e o halo respira. Só aparece se o boot demorar mais que a entrada.
/// 3. **Sair** (~0,5s): o logotipo avança na direção da câmera e a tela
///    dissolve, revelando o app já montado embaixo.
///
/// Com "Reduzir movimento" ligado não há tremulação nem zoom: um fade curto.
class VibesterSplash extends StatefulWidget {
  /// O app embaixo já está montado; a abertura pode sair ao fim da entrada.
  final bool ready;

  /// Chamado quando a saída termina e a abertura pode deixar a árvore.
  final VoidCallback onFinished;

  const VibesterSplash({
    super.key,
    required this.ready,
    required this.onFinished,
  });

  static const logoAsset = 'assets/img/logo/tipografia.png';

  /// Proporção do arquivo do logotipo (4072 × 1069).
  static const _logoAspect = 4072 / 1069;

  static const introDuration = Duration(milliseconds: 2000);
  static const pulseDuration = Duration(milliseconds: 1400);
  static const exitDuration = Duration(milliseconds: 520);

  @override
  State<VibesterSplash> createState() => _VibesterSplashState();
}

class _VibesterSplashState extends State<VibesterSplash>
    with TickerProviderStateMixin {
  static const _colors = AppColors.dark;

  late final AnimationController _intro;
  late final AnimationController _pulse;
  late final AnimationController _exit;

  /// Letreiro de néon ligando: apaga e acende algumas vezes antes de firmar.
  late final Animation<double> _flicker;
  late final Animation<double> _enterScale;
  late final Animation<double> _glowIn;

  bool _reduceMotion = false;
  bool _imageRequested = false;
  bool _exiting = false;

  @override
  void initState() {
    super.initState();
    _reduceMotion = WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations;

    _intro =
        AnimationController(
          vsync: this,
          duration: _reduceMotion
              ? AppMotion.slow
              : VibesterSplash.introDuration,
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed) _maybeExit();
        });

    _pulse = AnimationController(
      vsync: this,
      duration: VibesterSplash.pulseDuration,
    );

    _exit =
        AnimationController(
          vsync: this,
          duration: _reduceMotion ? AppMotion.ui : VibesterSplash.exitDuration,
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed) widget.onFinished();
        });

    _flicker = _reduceMotion
        ? CurvedAnimation(parent: _intro, curve: AppMotion.enter)
        : TweenSequence<double>([
            TweenSequenceItem(tween: ConstantTween(0), weight: 8),
            TweenSequenceItem(tween: Tween(begin: 0, end: 0.9), weight: 4),
            TweenSequenceItem(tween: Tween(begin: 0.9, end: 0.15), weight: 3),
            TweenSequenceItem(tween: Tween(begin: 0.15, end: 0.75), weight: 4),
            TweenSequenceItem(tween: ConstantTween(0.75), weight: 5),
            TweenSequenceItem(tween: Tween(begin: 0.75, end: 0.3), weight: 3),
            TweenSequenceItem(tween: Tween(begin: 0.3, end: 1), weight: 6),
            TweenSequenceItem(tween: ConstantTween(1), weight: 67),
          ]).animate(_intro);

    _enterScale = Tween<double>(begin: _reduceMotion ? 1 : 1.14, end: 1)
        .animate(
          CurvedAnimation(
            parent: _intro,
            curve: const Interval(0, 0.75, curve: Curves.easeOutQuart),
          ),
        );

    _glowIn = CurvedAnimation(
      parent: _intro,
      curve: const Interval(0.1, 0.8, curve: AppMotion.enter),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_imageRequested) return;
    _imageRequested = true;
    // A entrada só começa com o logotipo decodificado: sem isso a tremulação
    // rodaria sobre uma imagem ainda vazia e o primeiro "acender" se perderia.
    // O teto de 400ms garante que a abertura nunca fica parada esperando.
    Future.any<void>([
      precacheImage(const AssetImage(VibesterSplash.logoAsset), context),
      Future<void>.delayed(const Duration(milliseconds: 400)),
    ]).whenComplete(_start);
  }

  void _start() {
    if (!mounted || _intro.isAnimating || _intro.isCompleted) return;
    _intro.forward();
    if (!_reduceMotion) _pulse.repeat();
  }

  @override
  void didUpdateWidget(VibesterSplash oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.ready && !oldWidget.ready) _maybeExit();
  }

  void _maybeExit() {
    if (_exiting || !widget.ready || !_intro.isCompleted) return;
    _exiting = true;
    setState(() {});
    _exit.forward();
  }

  @override
  void dispose() {
    _intro.dispose();
    _pulse.dispose();
    _exit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final exitFade = CurvedAnimation(parent: _exit, curve: AppMotion.exit);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      // Durante a saída o app embaixo já recebe toque.
      child: IgnorePointer(
        ignoring: _exiting,
        child: FadeTransition(
          opacity: ReverseAnimation(exitFade),
          child: ColoredBox(
            color: _colors.noturno,
            child: Semantics(
              label: 'Vibester',
              child: AnimatedBuilder(
                animation: Listenable.merge([_intro, _pulse, _exit]),
                builder: (context, _) => _buildFrame(exitFade.value),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFrame(double exit) {
    // Fase do pulso em onda (0 → 1 → 0), para respirar sem salto no loop.
    final phase = _pulse.value;
    final breath = 0.5 - 0.5 * math.cos(phase * 2 * math.pi);
    final flicker = _flicker.value;

    final glow = _glowIn.value * (0.75 + 0.25 * breath);
    final scale = _enterScale.value * (1 + 0.35 * exit);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        // Logotipo ocupa quase a largura toda: é fundo, não selo.
        final logoWidth = width * 0.86;
        final logoHeight = logoWidth / VibesterSplash._logoAspect;
        final dpr = View.of(context).devicePixelRatio;

        return Stack(
          fit: StackFit.expand,
          children: [
            // Manchas de spray: âmbar em cima à esquerda, brasa embaixo à
            // direita, cruzando levemente com a respiração.
            _Blob(
              color: _colors.ambar,
              center: Offset(
                width * (0.18 + 0.06 * breath),
                height * (0.3 - 0.03 * breath),
              ),
              radius: width * 0.95,
              intensity: 0.34 * glow,
            ),
            _Blob(
              color: _colors.brasa,
              center: Offset(
                width * (0.85 - 0.06 * breath),
                height * (0.72 + 0.03 * breath),
              ),
              radius: width * 0.9,
              intensity: 0.3 * glow,
            ),
            const Positioned.fill(child: Grain(opacity: 0.06, density: 0.5)),

            Center(
              child: Transform.scale(
                scale: scale,
                child: SizedBox(
                  width: logoWidth,
                  height: logoHeight,
                  child: Stack(
                    clipBehavior: Clip.none,
                    fit: StackFit.expand,
                    children: [
                      // Halo de néon: a mesma letra borrada, piscando mais
                      // forte que o traço — é ele que "acende" o ar em volta.
                      Opacity(
                        opacity: (flicker * (0.35 + 0.45 * breath)).clamp(0, 1),
                        child: ImageFiltered(
                          imageFilter: ui.ImageFilter.blur(
                            sigmaX: 18,
                            sigmaY: 18,
                            tileMode: TileMode.decal,
                          ),
                          child: _gradientLogo(phase, logoWidth, dpr),
                        ),
                      ),
                      Opacity(
                        opacity: flicker.clamp(0, 1),
                        child: _gradientLogo(phase, logoWidth, dpr),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Logotipo pintado inteiro com o degradê da marca, correndo da esquerda
  /// para a direita. As cores se repetem (âmbar → brasa → âmbar) para o loop
  /// fechar sem emenda quando a fase volta a zero.
  Widget _gradientLogo(double phase, double width, double dpr) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => LinearGradient(
        colors: [
          _colors.ambar,
          _colors.brasa,
          // Reflexo claro do âmbar: é o "piscar" que atravessa as letras.
          Color.lerp(_colors.ambar, Colors.white, 0.45)!,
          _colors.ambar,
        ],
        stops: const [0.0, 0.45, 0.72, 1.0],
        tileMode: TileMode.repeated,
        transform: _SlideGradient(phase),
      ).createShader(bounds),
      child: Image.asset(
        VibesterSplash.logoAsset,
        fit: BoxFit.contain,
        // O arquivo tem 4072px; decodificado no tamanho de tela.
        cacheWidth: (width * dpr).round(),
        gaplessPlayback: true,
      ),
    );
  }
}

/// Desloca o degradê em uma largura inteira por ciclo do pulso.
class _SlideGradient extends GradientTransform {
  final double phase;

  const _SlideGradient(this.phase);

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * phase, 0, 0);
}

/// Mancha radial de cor. Gradiente, não blur, pelo mesmo motivo do
/// `SprayGlow`: custo quase zero por quadro.
class _Blob extends StatelessWidget {
  final Color color;
  final Offset center;
  final double radius;
  final double intensity;

  const _Blob({
    required this.color,
    required this.center,
    required this.radius,
    required this.intensity,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: center.dx - radius,
      top: center.dy - radius,
      width: radius * 2,
      height: radius * 2,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            colors: [
              color.withValues(alpha: intensity),
              color.withValues(alpha: intensity * 0.4),
              color.withValues(alpha: 0),
            ],
            stops: const [0.0, 0.42, 1.0],
          ),
        ),
      ),
    );
  }
}
