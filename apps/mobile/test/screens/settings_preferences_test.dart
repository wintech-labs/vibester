import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/providers/preferences/preferences_provider.dart';
import 'package:mobile/screens/settings/settings_screen.dart';
import 'package:mobile/service/preferences/preferences_service.dart';
import 'package:mobile/widgets/common/settings_row.dart';

import '../helpers/pump_app.dart';

/// PREFERÊNCIAS: a seção nova dos Ajustes.
void main() {
  setUpAll(setUpTestEnvironment);

  /// O interruptor da linha com este rótulo.
  Finder interruptorDe(String rotulo) => find.descendant(
    of: find.ancestor(
      of: find.text(rotulo),
      matching: find.byType(SettingsRow),
    ),
    matching: find.byType(Switch),
  );

  bool ligado(WidgetTester tester, String rotulo) =>
      tester.widget<Switch>(interruptorDe(rotulo)).value;

  Future<void> abrirAjustes(
    WidgetTester tester, {
    PreferencesProvider? preferences,
  }) => pumpScreen(
    tester,
    const SettingsScreen(),
    size: const Size(390, 1600),
    user: fakeUser(),
    preferences: preferences,
  );

  testWidgets('fica entre Aparência e Ajuda e privacidade', (tester) async {
    await abrirAjustes(tester);

    final aparencia = tester.getTopLeft(find.text('APARÊNCIA')).dy;
    final preferencias = tester.getTopLeft(find.text('PREFERÊNCIAS')).dy;
    final ajuda = tester.getTopLeft(find.text('AJUDA E PRIVACIDADE')).dy;

    expect(preferencias, greaterThan(aparencia));
    expect(preferencias, lessThan(ajuda));
  });

  testWidgets('os dois interruptores vêm ligados de fábrica', (tester) async {
    await abrirAjustes(tester);

    expect(ligado(tester, 'Deslizar para trocar de aba'), isTrue);
    expect(ligado(tester, 'Barras flutuantes'), isTrue);
  });

  testWidgets('tocar desliga, e o texto da linha não muda com o estado', (
    tester,
  ) async {
    final preferences = PreferencesProvider();
    await abrirAjustes(tester, preferences: preferences);

    await tester.tap(interruptorDe('Deslizar para trocar de aba'));
    await tester.pumpAndSettle();

    expect(ligado(tester, 'Deslizar para trocar de aba'), isFalse);
    expect(preferences.swipeBetweenTabs, isFalse);
    expect(ligado(tester, 'Barras flutuantes'), isTrue);

    // Diferente da linha do tema, o rótulo é fixo.
    expect(find.text('Deslizar para trocar de aba'), findsOneWidget);

    // E a escolha foi gravada para o próximo boot.
    final reloaded = await PreferencesService.load();
    expect(reloaded.swipeBetweenTabs, isFalse);
  });

  testWidgets('abre mostrando o que estava salvo', (tester) async {
    await abrirAjustes(
      tester,
      preferences: PreferencesProvider(
        const AppPreferences(swipeBetweenTabs: true, floatingBars: false),
      ),
    );

    expect(ligado(tester, 'Deslizar para trocar de aba'), isTrue);
    expect(ligado(tester, 'Barras flutuantes'), isFalse);
  });
}