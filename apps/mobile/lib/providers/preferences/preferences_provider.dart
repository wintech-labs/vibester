import 'package:flutter/material.dart';
import 'package:mobile/service/preferences/preferences_service.dart';

/// PREFERÊNCIAS: estado dos botões da seção "Preferências" dos Ajustes.
///
/// Segue o `ThemeProvider`: nasce com o valor lido no boot, muda só quando o
/// usuário toca no botão, avisa a tela na hora e grava no aparelho em
/// seguida.
///
/// Quem respeita cada valor:
///
/// * [swipeBetweenTabs] — a casca da Home (`HomeScreen`), que liga ou
///   desliga o arraste entre destinos.
/// * [floatingBars] — a navbar (pela `HomeScreen`), o cabeçalho do feed
///   (`FeedScreen`) e o cabeçalho da tela de posts do perfil
///   (`PostDetailScreen`). Ligado, somem ao descer e voltam ao subir;
///   desligado, ficam fixos.
class PreferencesProvider extends ChangeNotifier {
  PreferencesProvider([AppPreferences initial = const AppPreferences()])
    : _swipeBetweenTabs = initial.swipeBetweenTabs,
      _floatingBars = initial.floatingBars;

  bool _swipeBetweenTabs;
  bool _floatingBars;

  /// Trocar de aba arrastando a tela para os lados. Padrão: ligado.
  bool get swipeBetweenTabs => _swipeBetweenTabs;

  /// Barras flutuantes. Padrão: ligado.
  bool get floatingBars => _floatingBars;

  Future<void> setSwipeBetweenTabs(bool value) async {
    if (value == _swipeBetweenTabs) return;
    _swipeBetweenTabs = value;
    notifyListeners();
    await PreferencesService.saveSwipeBetweenTabs(value);
  }

  Future<void> setFloatingBars(bool value) async {
    if (value == _floatingBars) return;
    _floatingBars = value;
    notifyListeners();
    await PreferencesService.saveFloatingBars(value);
  }
}