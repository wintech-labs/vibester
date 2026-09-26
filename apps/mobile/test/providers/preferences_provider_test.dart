import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/providers/preferences/preferences_provider.dart';
import 'package:mobile/service/preferences/preferences_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// PREFERÊNCIAS: os dois interruptores da seção "Preferências" dos Ajustes.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('PreferencesService', () {
    test('sem nada salvo, as duas preferências vêm ligadas', () async {
      final prefs = await PreferencesService.load();

      expect(prefs.swipeBetweenTabs, isTrue);
      expect(prefs.floatingBars, isTrue);
    });
  });

  group('PreferencesProvider', () {
    test('nasce com o que foi lido no boot', () {
      final provider = PreferencesProvider(
        const AppPreferences(swipeBetweenTabs: false, floatingBars: true),
      );

      expect(provider.swipeBetweenTabs, isFalse);
      expect(provider.floatingBars, isTrue);
    });

    test('desligar o arraste avisa a tela e sobrevive ao reinício', () async {
      final provider = PreferencesProvider();
      var notified = false;
      provider.addListener(() => notified = true);

      await provider.setSwipeBetweenTabs(false);

      expect(provider.swipeBetweenTabs, isFalse);
      expect(notified, isTrue);

      // "Reinício do app": o próximo boot lê do aparelho.
      final reloaded = await PreferencesService.load();
      expect(reloaded.swipeBetweenTabs, isFalse);
      expect(reloaded.floatingBars, isTrue, reason: 'a outra não muda');
    });

    test('desligar as barras flutuantes sobrevive ao reinício', () async {
      final provider = PreferencesProvider();

      await provider.setFloatingBars(false);

      final reloaded = await PreferencesService.load();
      expect(reloaded.floatingBars, isFalse);
      expect(reloaded.swipeBetweenTabs, isTrue, reason: 'a outra não muda');
    });

    test('religar grava de novo o ligado', () async {
      final provider = PreferencesProvider();

      await provider.setFloatingBars(false);
      await provider.setFloatingBars(true);

      final reloaded = await PreferencesService.load();
      expect(reloaded.floatingBars, isTrue);
    });

    test('valor igual ao atual não notifica nem grava', () async {
      final provider = PreferencesProvider();
      var notified = false;
      provider.addListener(() => notified = true);

      await provider.setSwipeBetweenTabs(true);

      expect(notified, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), isEmpty, reason: 'o padrão não é gravado');
    });
  });
}