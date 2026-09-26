import 'package:shared_preferences/shared_preferences.dart';

/// PREFERÊNCIAS: escolhas de comportamento do app feitas nos Ajustes.
///
/// Um valor imutável com as duas chaves juntas, para o boot carregar tudo de
/// uma vez e o `PreferencesProvider` nascer já com o estado salvo — o mesmo
/// motivo de o tema ser lido antes do `runApp`: sem isso a tela abriria com o
/// padrão e trocaria um quadro depois.
class AppPreferences {
  /// Trocar de aba arrastando a tela para os lados.
  final bool swipeBetweenTabs;

  /// Barras flutuantes.
  final bool floatingBars;

  const AppPreferences({
    this.swipeBetweenTabs = defaultSwipeBetweenTabs,
    this.floatingBars = defaultFloatingBars,
  });

  /// Padrões de fábrica: as duas ligadas. Valem enquanto o usuário não mexer
  /// no botão — só a escolha dele grava algo no aparelho.
  static const bool defaultSwipeBetweenTabs = true;
  static const bool defaultFloatingBars = true;
}

/// Leitura e escrita das [AppPreferences] no aparelho.
///
/// Mesmo formato do `ThemeService`: `SharedPreferences`, métodos estáticos e
/// falha silenciosa. É preferência de interface, não dado da conta — perder
/// uma escrita custa no máximo o botão voltar ao padrão, e isso não pode
/// derrubar a tela nem o boot.
class PreferencesService {
  PreferencesService._();

  static const _swipeBetweenTabsKey = 'pref_swipe_between_tabs';
  static const _floatingBarsKey = 'pref_floating_bars';

  /// Carrega o que foi salvo. Chave ausente (nunca mexeram no botão) ou
  /// leitura que falhou caem no padrão de fábrica.
  static Future<AppPreferences> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return AppPreferences(
        swipeBetweenTabs:
            prefs.getBool(_swipeBetweenTabsKey) ??
            AppPreferences.defaultSwipeBetweenTabs,
        floatingBars:
            prefs.getBool(_floatingBarsKey) ??
            AppPreferences.defaultFloatingBars,
      );
    } catch (_) {
      return const AppPreferences();
    }
  }

  static Future<void> saveSwipeBetweenTabs(bool value) =>
      _save(_swipeBetweenTabsKey, value);

  static Future<void> saveFloatingBars(bool value) =>
      _save(_floatingBarsKey, value);

  static Future<void> _save(String key, bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (_) {
      // Preferência de UI não-crítica: falha de escrita é ignorada.
    }
  }
}