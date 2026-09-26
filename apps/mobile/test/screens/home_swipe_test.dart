import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/providers/preferences/preferences_provider.dart';
import 'package:mobile/screens/home/home_screen.dart';
import 'package:mobile/service/preferences/preferences_service.dart';

import '../helpers/pump_app.dart';

/// ARRASTE: troca de destino arrastando a tela para os lados.
///
/// O rótulo da navbar só existe no destino ativo, então ele é o jeito mais
/// direto de saber em que destino a casca está: se aparece "BUSCA" e some
/// "FEED", a troca aconteceu de verdade — página e navbar juntas.
void main() {
  setUpAll(setUpTestEnvironment);

  /// Depois de trocar de destino, a tela nova nasce e dispara as buscas dela.
  /// Sem servidor no teste, as chamadas só terminam no timeout do Dio — mesmo
  /// motivo dos pumps longos do `pumpScreen`.
  Future<void> esperarDestinoNovo(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(seconds: 11));
    await tester.pump(const Duration(seconds: 11));
  }

  testWidgets('arrastar para a esquerda leva do FEED à BUSCA', (tester) async {
    await pumpScreen(tester, const HomeScreen());

    expect(find.text('FEED'), findsOneWidget);

    await tester.fling(
      find.byType(PageView).first,
      const Offset(-300, 0),
      1000,
    );
    await esperarDestinoNovo(tester);

    expect(find.text('BUSCA'), findsOneWidget);
    expect(find.text('FEED'), findsNothing);
  });

  testWidgets('arrastar de volta para a direita retorna ao FEED', (
    tester,
  ) async {
    await pumpScreen(tester, const HomeScreen());

    await tester.fling(
      find.byType(PageView).first,
      const Offset(-300, 0),
      1000,
    );
    await esperarDestinoNovo(tester);

    await tester.fling(
      find.byType(PageView).first,
      const Offset(300, 0),
      1000,
    );
    await esperarDestinoNovo(tester);

    expect(find.text('FEED'), findsOneWidget);
    expect(find.text('BUSCA'), findsNothing);
  });

  testWidgets('arraste curto que não passa da metade não troca de destino', (
    tester,
  ) async {
    await pumpScreen(tester, const HomeScreen());

    // Devagar e curto: a página volta para onde estava ao soltar.
    await tester.timedDrag(
      find.byType(PageView).first,
      const Offset(-60, 0),
      const Duration(milliseconds: 600),
    );
    await esperarDestinoNovo(tester);

    expect(find.text('FEED'), findsOneWidget);
    expect(find.text('BUSCA'), findsNothing);
  });

  // PREFERÊNCIA DE ARRASTE: "Deslizar para trocar de aba" nos Ajustes.
  group('com o arraste desligado nos Ajustes', () {
    PreferencesProvider desligado() => PreferencesProvider(
      const AppPreferences(swipeBetweenTabs: false),
    );

    testWidgets('arrastar não troca de destino', (tester) async {
      await pumpScreen(tester, const HomeScreen(), preferences: desligado());

      await tester.fling(
        find.byType(PageView).first,
        const Offset(-300, 0),
        1000,
      );
      await esperarDestinoNovo(tester);

      expect(find.text('FEED'), findsOneWidget);
      expect(find.text('BUSCA'), findsNothing);
    });

    testWidgets('o toque na navbar continua trocando de destino', (
      tester,
    ) async {
      await pumpScreen(tester, const HomeScreen(), preferences: desligado());

      // Destinos inativos não têm rótulo; o ícone da BUSCA é o de explorar.
      await tester.tap(find.byIcon(Icons.explore_outlined));
      await esperarDestinoNovo(tester);

      expect(find.text('BUSCA'), findsOneWidget);
      expect(find.text('FEED'), findsNothing);
    });

    testWidgets('mudar a preferência vale na hora, sem reabrir o app', (
      tester,
    ) async {
      final preferences = PreferencesProvider();
      await pumpScreen(tester, const HomeScreen(), preferences: preferences);

      await preferences.setSwipeBetweenTabs(false);
      await tester.pump();

      await tester.fling(
        find.byType(PageView).first,
        const Offset(-300, 0),
        1000,
      );
      await esperarDestinoNovo(tester);

      expect(find.text('FEED'), findsOneWidget);
      expect(find.text('BUSCA'), findsNothing);
    });
  });
}