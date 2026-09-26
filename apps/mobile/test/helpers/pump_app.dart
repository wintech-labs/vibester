import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mobile/providers/events/events_list_provider.dart';
import 'package:mobile/providers/feed/publication_list_provider.dart';
import 'package:mobile/providers/notification/notification_provider.dart';
import 'package:mobile/providers/place/nearby_provider.dart';
import 'package:mobile/providers/place/place_list_provider.dart';
import 'package:mobile/providers/preferences/preferences_provider.dart';
import 'package:mobile/providers/safety/block_provider.dart';
import 'package:mobile/providers/theme/theme_provider.dart';
import 'package:mobile/providers/user/user_provider.dart';
import 'package:mobile/models/user/user_model.dart';
import 'package:mobile/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tamanhos de tela usados na bateria de renderização.
///
/// O menor (`iPhoneSE`) é o que costuma revelar `RenderFlex overflowed`, e o
/// maior garante que nada assume largura de celular — os dois extremos que o
/// briefing pede para testar (§106).
class TestScreens {
  TestScreens._();

  /// iPhone SE / Android pequeno.
  static const small = Size(320, 568);

  /// Aparelho de referência.
  static const medium = Size(390, 844);

  /// Telas grandes / tablet estreito.
  static const large = Size(600, 1024);

  static const all = <String, Size>{
    'pequena (320x568)': small,
    'média (390x844)': medium,
    'grande (600x1024)': large,
  };
}

/// Preparo comum a todos os testes: locale pt_BR (usado por praticamente todo
/// `DateFormat` do app) e `SharedPreferences` em memória.
Future<void> setUpTestEnvironment() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  await initializeDateFormatting('pt_BR', null);
}

/// Usuário de teste com dados plausíveis — nunca usado em tela de produção,
/// só para exercitar os caminhos que dependem de sessão.
UserModel fakeUser({String? cidade}) => UserModel(
  id: 'profile-1',
  accountId: 'account-1',
  userID: 'account-1',
  token: 'token-de-teste',
  nome: 'Ana Vibes',
  nomeUsuario: '@anavibes',
  bio: 'Sai toda quinta.',
  seguidores: 128,
  seguindo: 90,
  totalPosts: 12,
  interesses: 'Bares, Shows',
  email: 'ana@example.com',
  dataNascimento: '2000-01-01',
  cidade: cidade ?? 'Maringá',
);

/// Monta um widget dentro do `MaterialApp` real do app (tema, rotas nomeadas
/// vazias, providers) num tamanho de tela definido.
///
/// Qualquer exceção do framework durante o build — incluindo estouro de
/// layout, que é reportado como erro em debug — reprova o teste. É o que
/// transforma esta função num verificador de QA visual automatizado.
Future<void> pumpScreen(
  WidgetTester tester,
  Widget screen, {
  Size size = TestScreens.medium,
  UserModel? user,
  ThemeMode themeMode = ThemeMode.dark,
  BlockProvider? blocks,
  RouteFactory? onGenerateRoute,
  PreferencesProvider? preferences,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final userProvider = UserProvider();
  if (user != null) userProvider.setUser(user);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => PlaceListProvider()),
        ChangeNotifierProvider(create: (_) => NearbyProvider()),
        ChangeNotifierProvider(create: (_) => EventsListProvider()),
        ChangeNotifierProvider(create: (_) => PublicationListProvider()),
        ChangeNotifierProvider(create: (_) => NotificationProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider(themeMode)),
        ChangeNotifierProvider.value(value: blocks ?? BlockProvider()),
        // PREFERÊNCIAS: os Ajustes leem este provider; sem ele toda tela que
        // o usa cairia em `ProviderNotFoundException`. Por padrão nasce com
        // os valores de fábrica; um teste que precisa de outro estado passa
        // o seu em [preferences].
        ChangeNotifierProvider.value(
          value: preferences ?? PreferencesProvider(),
        ),
        ChangeNotifierProvider.value(value: userProvider),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: themeMode,
        home: screen,
        // As telas navegam por nome; sem isso um toque acidental num botão
        // derrubaria o teste por rota desconhecida. Um teste que precisa ver
        // para onde a tela navegou passa o seu próprio `onGenerateRoute`.
        onGenerateRoute:
            onGenerateRoute ??
            (settings) => MaterialPageRoute(builder: (_) => const SizedBox.shrink()),
      ),
    ),
  );

  // As telas disparam busca em postFrameCallback. Sem servidor no ambiente de
  // teste, as chamadas ficam presas até o `connectTimeout` de 10s do Dio
  // (`ApiClient`), então avançamos o relógio além disso: é assim que a
  // requisição termina e o provider cai no estado de erro tratado — que é
  // justamente o caminho que queremos ver renderizando.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(seconds: 11));
  await tester.pump(const Duration(seconds: 11));
}

/// Envolve um componente solto (card, botão, tag) no tema do app.
Future<void> pumpComponent(
  WidgetTester tester,
  Widget child, {
  Size size = TestScreens.medium,
  double? width,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, child: child),
        ),
      ),
      onGenerateRoute: (_) =>
          MaterialPageRoute(builder: (_) => const SizedBox.shrink()),
    ),
  );

  // Dois pumps de propósito. Animações iniciadas em `addPostFrameCallback`
  // (a entrada da navbar, por exemplo) só ganham o primeiro tick no frame
  // seguinte, e o primeiro tick de um `Ticker` sempre reporta tempo zero:
  // com um pump só, o componente ficaria congelado no início da animação —
  // invisível, no caso de uma entrada que começa em opacidade 0.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
}