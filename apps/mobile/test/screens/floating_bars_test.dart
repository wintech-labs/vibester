import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/models/highlights/highlight_model.dart';
import 'package:mobile/providers/preferences/preferences_provider.dart';
import 'package:mobile/screens/feed/feed_screen.dart';
import 'package:mobile/screens/home/home_screen.dart';
import 'package:mobile/service/preferences/preferences_service.dart';
import 'package:mobile/widgets/cards/highlights/post_detail_screen.dart';
import 'package:mobile/widgets/navigation/vibester_navbar.dart';

import '../helpers/pump_app.dart';

/// BARRAS FLUTUANTES: "Barras flutuantes" nos Ajustes controla a navbar, o
/// cabeçalho do feed e o cabeçalho da tela de posts do perfil. Ligado (o
/// padrão), somem ao descer; desligado, ficam fixos.
void main() {
  setUpAll(setUpTestEnvironment);

  PreferencesProvider barras({required bool ligadas}) =>
      PreferencesProvider(AppPreferences(floatingBars: ligadas));

  /// Uma rolagem para baixo, entregue a partir de [origem] como se viesse da
  /// lista. O feed de teste não tem posts (sem servidor), então não há o que
  /// rolar de verdade — mas as telas reagem à notificação de rolagem, e é ela
  /// que este teste precisa exercitar.
  void rolarParaBaixo(WidgetTester tester, Finder origem) {
    final context = tester.element(origem);
    ScrollUpdateNotification(
      metrics: FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 4000,
        pixels: 600,
        viewportDimension: 800,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1,
      ),
      context: context,
      scrollDelta: 40,
    ).dispatch(context);
  }

  /// Opacidade-alvo do cabeçalho que contém [conteudo] (1 = à vista).
  double opacidadeDoCabecalho(WidgetTester tester, Finder conteudo) => tester
      .widget<AnimatedOpacity>(
        find.ancestor(of: conteudo, matching: find.byType(AnimatedOpacity))
            .first,
      )
      .opacity;

  group('navbar', () {
    bool navbarVisivel(WidgetTester tester) =>
        tester.widget<VibesterNavbar>(find.byType(VibesterNavbar)).visible;

    testWidgets('ligado: some ao descer', (tester) async {
      await pumpScreen(
        tester,
        const HomeScreen(),
        preferences: barras(ligadas: true),
      );

      rolarParaBaixo(tester, find.byType(FeedScreen));
      await tester.pump();

      expect(navbarVisivel(tester), isFalse);
    });

    testWidgets('desligado: fica à vista ao descer', (tester) async {
      await pumpScreen(
        tester,
        const HomeScreen(),
        preferences: barras(ligadas: false),
      );

      rolarParaBaixo(tester, find.byType(FeedScreen));
      await tester.pump();

      expect(navbarVisivel(tester), isTrue);
    });

    testWidgets('desligar com a navbar escondida a traz de volta', (
      tester,
    ) async {
      final preferences = barras(ligadas: true);
      await pumpScreen(tester, const HomeScreen(), preferences: preferences);

      rolarParaBaixo(tester, find.byType(FeedScreen));
      await tester.pump();
      expect(navbarVisivel(tester), isFalse);

      await preferences.setFloatingBars(false);
      await tester.pump();

      expect(navbarVisivel(tester), isTrue);
    });
  });

  group('cabeçalho do feed', () {
    final logo = find.byWidgetPredicate(
      (w) =>
          w is Image &&
          w.image is AssetImage &&
          (w.image as AssetImage).assetName.startsWith('assets/img/logo/'),
    );

    testWidgets('ligado: some ao descer', (tester) async {
      await pumpScreen(
        tester,
        const FeedScreen(),
        preferences: barras(ligadas: true),
      );

      rolarParaBaixo(tester, find.byType(RefreshIndicator));
      await tester.pump();

      expect(opacidadeDoCabecalho(tester, logo), 0);
    });

    testWidgets('desligado: fica à vista ao descer', (tester) async {
      await pumpScreen(
        tester,
        const FeedScreen(),
        preferences: barras(ligadas: false),
      );

      rolarParaBaixo(tester, find.byType(RefreshIndicator));
      await tester.pump();

      expect(opacidadeDoCabecalho(tester, logo), 1);
    });
  });

  group('cabeçalho da tela de posts', () {
    // Posts de outra conta: o título fica "Posts".
    final posts = [
      for (var i = 0; i < 6; i++)
        HighlightModel(
          postId: 'post-$i',
          userId: 'outra-conta',
          imagensUrls: const [],
          legenda: 'Noite boa demais.',
          totalCurtidas: 0,
          totalComentarios: 0,
          foiDeletado: false,
          criadoEm: DateTime(2026, 9, 1).toIso8601String(),
          atualizadoEm: DateTime(2026, 9, 1).toIso8601String(),
        ),
    ];

    /// Aqui há conteúdo de verdade, então a rolagem é um arraste real.
    Future<void> arrastarParaBaixo(WidgetTester tester) async {
      await tester.drag(
        find.byType(CustomScrollView),
        const Offset(0, -500),
      );
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('ligado: some ao descer', (tester) async {
      await pumpScreen(
        tester,
        PostDetailScreen(posts: posts),
        user: fakeUser(),
        preferences: barras(ligadas: true),
      );

      await arrastarParaBaixo(tester);

      expect(opacidadeDoCabecalho(tester, find.text('Posts')), 0);
    });

    testWidgets('desligado: fica à vista ao descer', (tester) async {
      await pumpScreen(
        tester,
        PostDetailScreen(posts: posts),
        user: fakeUser(),
        preferences: barras(ligadas: false),
      );

      await arrastarParaBaixo(tester);

      expect(opacidadeDoCabecalho(tester, find.text('Posts')), 1);
    });
  });
}