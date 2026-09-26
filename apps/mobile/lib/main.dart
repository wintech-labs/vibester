import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile/models/event/event_model.dart';
import 'package:mobile/models/user/user_model.dart';
import 'package:mobile/service/media/image_cache.dart';
import 'package:mobile/service/api_client.dart';
import 'package:mobile/service/auth_storage_service.dart';
import 'package:mobile/service/event/event_service.dart';
import 'package:mobile/service/user/user_service.dart';
import 'package:mobile/providers/events/events_list_provider.dart';
import 'package:mobile/providers/feed/publication_list_provider.dart';
import 'package:mobile/providers/notification/notification_provider.dart';
import 'package:mobile/providers/place/nearby_provider.dart';
import 'package:mobile/providers/place/place_list_provider.dart';
import 'package:mobile/providers/preferences/preferences_provider.dart';
import 'package:mobile/providers/safety/block_provider.dart';
import 'package:mobile/providers/theme/theme_provider.dart';
import 'package:mobile/providers/user/user_provider.dart';
import 'package:mobile/routes/app_routes.dart';
import 'package:mobile/routes/route_observer.dart';
import 'package:mobile/service/interaction/interaction_tracker.dart';
import 'package:mobile/service/preferences/preferences_service.dart';
import 'package:mobile/service/theme/theme_service.dart';
import 'package:mobile/service/user/interests_storage.dart';
import 'package:mobile/theme/app_theme.dart';
import 'package:mobile/theme/vibester_page_route.dart';
import 'package:mobile/screens/events/event_detail_screen.dart';
import 'package:mobile/screens/events/event_list_screen.dart';
import 'package:mobile/screens/events/favorites_events_screen.dart';
import 'package:mobile/screens/feed/feed_screen.dart';
import 'package:mobile/screens/feed/new_publication_screen.dart';
import 'package:mobile/screens/home/home_screen.dart';
import 'package:mobile/screens/home/initial_screen.dart';
import 'package:mobile/screens/notification/notifications_screen.dart';
import 'package:mobile/screens/saved/saved_screen.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mobile/screens/onboarding/onboarding_screen.dart';
import 'package:mobile/screens/places/favorite_places_screen.dart';
import 'package:mobile/screens/places/hot_places_screen.dart';
import 'package:mobile/screens/places/place_detail_screen.dart';
import 'package:mobile/screens/register/email_confirm_screen.dart';
import 'package:mobile/screens/register/login_screen.dart';
import 'package:mobile/screens/register/recover_password_screen.dart';
import 'package:mobile/screens/register/register_screen.dart';
import 'package:mobile/screens/register/reset_password_screen.dart';
import 'package:mobile/screens/explore/explore_screen.dart';
import 'package:mobile/screens/settings/blocked_accounts_screen.dart';
import 'package:mobile/screens/settings/delete_account_screen.dart';
import 'package:mobile/screens/settings/personal_information_settings_screen.dart';
import 'package:mobile/screens/settings/settings_screen.dart';
import 'package:mobile/screens/user/follow_list_screen.dart';
import 'package:mobile/screens/user/other_users_profile_screen.dart';
import 'package:mobile/screens/user/profile_editing_screen.dart';
import 'package:mobile/screens/user/user_interests_screen.dart';
import 'package:mobile/screens/user/user_profile_screen.dart';
import 'package:mobile/widgets/cards/highlights/post_detail_screen.dart';
import 'package:provider/provider.dart';
import 'package:visibility_detector/visibility_detector.dart';

// Builders de transição de rota (fade+slide+scale compostos) vivem em
// lib/theme/vibester_page_route.dart: vibesterSlideRoute, vibesterFadeRoute,
// vibesterDetailRoute — usados abaixo, no onGenerateRoute.

//Classe que da ao scroll uma propriedade especifica
class _NoBounceScrollBehavior extends ScrollBehavior {
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const ClampingScrollPhysics();
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // debugPrint não é removido no build de release: iria para o log do
  // aparelho (Console.app/logcat) com payloads de notificação e mensagens de
  // erro. Em release, silencia.
  if (kReleaseMode) debugPrint = (String? message, {int? wrapWidth}) {};

  // Limites do cache de imagem em memória — o motivo de cada número vive
  // junto do cache de disco, em lib/service/media/image_cache.dart.
  VibesterImageCache.configureMemoryCache();

  // Resolução com que o VisibilityDetector reporta mudança de visibilidade.
  // O padrão de 500ms é grosso demais para a telemetria do feed: o
  // InteractionTracker separa "piscada de rolagem" (<300ms, descartada) de
  // "descarte rápido" (<1s, sinal negativo) de "foi visto" (≥1s), e com meio
  // segundo de granularidade esses três casos se confundem. 100ms custa mais
  // CPU, e é o preço de o dado de atenção significar alguma coisa.
  VisibilityDetectorController.instance.updateInterval = const Duration(
    milliseconds: 100,
  );

  await initializeDateFormatting('pt_BR', null);
  // Interesses escolhidos no onboarding: restaurados antes da primeira tela
  // pra a régua de categorias da Home já nascer na ordem do usuário.
  await InterestsStorage.restore();
  var savedUser = await AuthStorageService.loadSession();
  final etapaPendente = await AuthStorageService.etapaPendente();
  // JWT vencido não é sessão: restaurar abriria a home com o feed recusando
  // tudo com 401. Descarta e começa pela tela inicial.
  final savedToken = savedUser?.token;
  // Guardado para a interface: descartar a sessão em silêncio faz o usuário
  // abrir o app, cair na tela inicial e achar que perdeu tudo. O 401 em tempo
  // de uso já explica o que houve (ver `_handleSessionExpired`); o boot
  // precisava fazer o mesmo.
  var sessaoExpirada = false;
  if (savedToken != null && ApiClient.isTokenExpired(savedToken)) {
    await AuthStorageService.clearSession();
    savedUser = null;
    sessaoExpirada = true;
  }
  if (savedUser?.token != null) {
    ApiClient.token = savedUser!.token;
  }
  final initialThemeMode = await ThemeService.loadThemeMode();
  // PREFERÊNCIAS: lidas antes da primeira tela pelo mesmo motivo do tema —
  // o app já nasce com a escolha do usuário, sem abrir no padrão e trocar um
  // quadro depois.
  final initialPreferences = await PreferencesService.load();
  runApp(
    MyApp(
      savedUser: savedUser,
      etapaPendente: etapaPendente,
      initialThemeMode: initialThemeMode,
      initialPreferences: initialPreferences,
      sessaoExpirada: sessaoExpirada,
    ),
  );
}

class MyApp extends StatefulWidget {
  final UserModel? savedUser;
  final ThemeMode initialThemeMode;

  /// PREFERÊNCIAS: escolhas dos Ajustes já lidas do aparelho no boot.
  final AppPreferences initialPreferences;

  /// Passo do cadastro deixado pela metade, ou `null` se não há.
  final EtapaCadastro? etapaPendente;

  /// A sessão salva foi descartada no boot por token vencido. O app avisa e
  /// leva ao login, em vez de abrir a capa como se nunca tivesse havido conta.
  final bool sessaoExpirada;

  const MyApp({
    super.key,
    this.savedUser,
    this.etapaPendente,
    required this.initialThemeMode,
    this.initialPreferences = const AppPreferences(),
    this.sessaoExpirada = false,
  });

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final AppLinks _appLinks = AppLinks();
  final UserService _userService = UserService();
  final EventService _eventService = EventService();
  StreamSubscription<Uri>? _linkSubscription;

  /// Providers de sessão vivem como campos do State, não como variáveis
  /// locais do `build`.
  ///
  /// Criados dentro do `build` e entregues com `.value`, eles nasciam de novo
  /// a cada reconstrução deste widget: o usuário logado sumia, o contador de
  /// notificações voltava a zero e as instâncias antigas ficavam sem
  /// `dispose`, ainda ouvindo. Hoje nada aqui chama `setState`, então o
  /// defeito estava dormente — mas é o tipo de armadilha que explode na
  /// primeira mudança inocente neste arquivo.
  late final UserProvider _userProvider;
  late final NotificationProvider _notificationProvider;
  late final ThemeProvider _themeProvider;
  late final BlockProvider _blockProvider;

  /// PREFERÊNCIAS: campo do State pelo mesmo motivo dos providers acima.
  /// Criado no `build`, voltaria ao estado lido no boot a cada reconstrução.
  late final PreferencesProvider _preferencesProvider;

  /// Telemetria do feed. Vive no State pelo mesmo motivo dos providers acima:
  /// guarda as impressões abertas e o buffer de envio, e seria zerada a cada
  /// reconstrução se nascesse no `build`.
  late final InteractionTracker _interactionTracker;
  AppLifecycleListener? _lifecycleListener;

  @override
  void initState() {
    super.initState();
    ApiClient.onSessionExpired = _handleSessionExpired;

    _userProvider = UserProvider();
    _notificationProvider = NotificationProvider();
    _themeProvider = ThemeProvider(widget.initialThemeMode);
    _blockProvider = BlockProvider();
    _preferencesProvider = PreferencesProvider(widget.initialPreferences);
    _interactionTracker = InteractionTracker();

    // O fim da sessão é a parte mais valiosa do dado — é o que fez a pessoa
    // sair — e é exatamente o que se perde sem um envio ao ir para segundo
    // plano, porque o app pode nunca mais voltar.
    _lifecycleListener = AppLifecycleListener(
      onPause: _interactionTracker.onAppPaused,
      onResume: _interactionTracker.onAppResumed,
    );

    // A busca do contador de não lidas saiu daqui: a HomeScreen agora a faz
    // ao montar e ao voltar do segundo plano, o que cobre também quem entra
    // pelo login (e não só a sessão restaurada do disco). Mantê-la nos dois
    // lugares só produzia duas chamadas idênticas no primeiro segundo.
    if (widget.savedUser != null) {
      _userProvider.setUser(widget.savedUser!);
    }

    _initDeepLinks();

    if (widget.sessaoExpirada) {
      // Depois do primeiro frame: antes disso não existe navigator nem
      // messenger para receber isso.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _avisarSessaoExpirada();
      });
    }
  }

  /// Leva ao login com a explicação. Mesma pilha e mesma mensagem do caminho
  /// de 401 em tempo de uso, para as duas formas de perder a sessão terminarem
  /// no mesmo lugar.
  void _avisarSessaoExpirada() {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;

    navigator.pushNamed(AppRoutes.login);
    ScaffoldMessenger.of(navigator.context).showSnackBar(
      const SnackBar(content: Text('Sua sessão expirou. Entra de novo.')),
    );
  }

  // 401 numa rota autenticada: o token venceu. Encerra a sessão pelos dois
  // lados (memória e storage seguro, via UserProvider.logout) e volta ao
  // login, mesma pilha do "Sair" das configurações.
  Future<void> _handleSessionExpired() async {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;

    final messenger = ScaffoldMessenger.of(navigator.context);
    final userProvider = navigator.context.read<UserProvider>();
    if (userProvider.user == null) return;

    await userProvider.logout();
    if (!mounted) return;

    // O provider vive acima do navigator e sobrevive ao logout: sem isto, a
    // próxima conta a entrar herdava o selo e a lista da anterior até a
    // primeira busca terminar.
    _notificationProvider.clear();
    _blockProvider.clear();

    navigator.pushNamedAndRemoveUntil(AppRoutes.initialScreen, (_) => false);
    navigator.pushNamed(AppRoutes.login);
    messenger.showSnackBar(
      const SnackBar(content: Text('Sua sessão expirou. Entra de novo.')),
    );
  }

  Future<void> _initDeepLinks() async {
    final initialUri = await _appLinks.getInitialLink();
    if (initialUri != null) _handleUri(initialUri);

    _linkSubscription = _appLinks.uriLinkStream.listen(_handleUri);
  }

  // Espera vibester://profile/{token} (token gerado por
  // UserService.generateShareLink no backend), vibester://event/{id} e
  // vibester://place/{id} (links de ShareLinks). Quem chega pelo link vem da
  // landing page, que monta esses endereços.
  Future<void> _handleUri(Uri uri) async {
    if (uri.scheme != 'vibester') return;
    final segment = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
    if (segment == null) return;

    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;

    switch (uri.host) {
      case 'profile':
        return _openSharedProfile(navigator, segment);
      case 'event':
        return _openSharedEvent(navigator, segment);
      case 'place':
        // PlaceDetailScreen já busca pelo id e trata o não encontrado.
        navigator.pushNamed(AppRoutes.placeDetail, arguments: segment);
    }
  }

  // A rota de detalhe recebe o EventModel pronto (vem de um card), então o
  // link busca o evento antes de abrir.
  Future<void> _openSharedEvent(
    NavigatorState navigator,
    String eventId,
  ) async {
    final messenger = ScaffoldMessenger.of(navigator.context);
    try {
      final event = await _eventService.getEventById(eventId);
      if (!mounted) return;
      navigator.pushNamed(AppRoutes.eventDetail, arguments: event);
    } catch (e) {
      debugPrint('Falha ao abrir evento compartilhado: $e');
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Não foi possível abrir esse rolê agora.'),
        ),
      );
    }
  }

  Future<void> _openSharedProfile(
    NavigatorState navigator,
    String token,
  ) async {

    // Capturados antes do await: depois dele o context do navigator pode ter
    // sido desmontado, e usá-lo cruzando o gap assíncrono é o que o
    // use_build_context_synchronously alerta.
    final messenger = ScaffoldMessenger.of(navigator.context);
    final currentUserId = navigator.context
        .read<UserProvider>()
        .user
        ?.accountId;

    try {
      final resolvedAccountId = await _userService.resolveShareToken(token);
      if (!mounted) return;

      if (resolvedAccountId == null) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Este link de compartilhamento expirou ou é inválido.',
            ),
          ),
        );
        return;
      }

      if (resolvedAccountId == currentUserId) {
        navigator.pushNamed(AppRoutes.profile);
      } else {
        navigator.pushNamed(
          AppRoutes.otherProfile,
          arguments: resolvedAccountId,
        );
      }
    } catch (e) {
      // Mensagem tratada na tela; o detalhe da exceção fica no log local.
      debugPrint('Falha ao abrir link compartilhado: $e');
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Não foi possível abrir esse link agora.'),
        ),
      );
    }
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    ApiClient.onSessionExpired = null;
    _userProvider.dispose();
    _notificationProvider.dispose();
    _themeProvider.dispose();
    _blockProvider.dispose();
    _preferencesProvider.dispose();
    _lifecycleListener?.dispose();
    _interactionTracker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => PlaceListProvider()),
        ChangeNotifierProvider(create: (_) => NearbyProvider()),
        ChangeNotifierProvider(create: (_) => EventsListProvider()),
        ChangeNotifierProvider(create: (_) => PublicationListProvider()),
        ChangeNotifierProvider.value(value: _userProvider),
        ChangeNotifierProvider.value(value: _notificationProvider),
        ChangeNotifierProvider.value(value: _themeProvider),
        ChangeNotifierProvider.value(value: _blockProvider),
        ChangeNotifierProvider.value(value: _preferencesProvider),
        // Provider simples, não ChangeNotifier: telemetria nunca redesenha tela.
        Provider<InteractionTracker>.value(value: _interactionTracker),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, _) => MaterialApp(
          navigatorKey: _navigatorKey,
          navigatorObservers: [appRouteObserver],
          debugShowCheckedModeBanner: false,
          //Chama a classe da propriedade de scroll
          scrollBehavior: _NoBounceScrollBehavior(),
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: themeProvider.themeMode,
          // A conta nasce na confirmação do e-mail, mas o cadastro só termina
          // na apresentação. Fechar o app entre os dois deixa uma etapa
          // gravada, e é ela que diz onde retomar — sem isso o app abria na
          // home com perfil e interesses em branco, sem perguntar mais nada.
          initialRoute: widget.savedUser == null
              ? AppRoutes.initialScreen
              : switch (widget.etapaPendente) {
                  EtapaCadastro.perfil => AppRoutes.profileEditing,
                  EtapaCadastro.interesses => AppRoutes.userInterestsSetup,
                  EtapaCadastro.apresentacao => AppRoutes.onboarding,
                  null => AppRoutes.home,
                },
          onGenerateRoute: (settings) {
            switch (settings.name) {
              // EVENTS
              case AppRoutes.eventList:
                return vibesterSlideRoute(
                  const EventListScreen(showHeader: true),
                  settings,
                );
              case AppRoutes.favoritesEvents:
                return vibesterSlideRoute(
                  const FavoritesEventsScreen(),
                  settings,
                );
              case AppRoutes.eventDetail:
                final event = settings.arguments as EventModel;
                return vibesterDetailRoute(
                  EventDetailScreen(eventModel: event),
                  settings,
                );

              // PLACES
              case AppRoutes.favoritesPlaces:
                return vibesterSlideRoute(
                  const FavoritePlacesScreen(),
                  settings,
                );
              case AppRoutes.hotPlaces:
                return vibesterSlideRoute(const HotPlacesScreen(), settings);
              case AppRoutes.placeDetail:
                final placeId = settings.arguments as String;
                return vibesterDetailRoute(
                  PlaceDetailScreen(placeId: placeId),
                  settings,
                );

              // HOME
              case AppRoutes.home:
                return vibesterFadeRoute(const HomeScreen(), settings);
              case AppRoutes.initialScreen:
                return vibesterFadeRoute(const InitialScreen(), settings);

              // ONBOARDING
              case AppRoutes.onboarding:
                return vibesterFadeRoute(const OnboardingScreen(), settings);

              // REGISTER
              case AppRoutes.emailConfirm:
                final args = settings.arguments as Map<String, String>;
                return vibesterFadeRoute(
                  EmailConfirmScreen(
                    email: args['email']!,
                    senha: args['senha']!,
                  ),
                  settings,
                );
              case AppRoutes.login:
                return vibesterFadeRoute(const LoginScreen(), settings);
              case AppRoutes.recoverPassword:
                return vibesterFadeRoute(
                  const RecoverPasswordScreen(),
                  settings,
                );
              case AppRoutes.register:
                return vibesterFadeRoute(const RegisterScreen(), settings);
              case AppRoutes.resetPassword:
                final email = settings.arguments as String? ?? '';
                return vibesterFadeRoute(
                  ResetPasswordScreen(email: email),
                  settings,
                );

              // SEARCH
              case AppRoutes.search:
                return vibesterSlideRoute(const ExploreScreen(), settings);

              // SETTINGS
              case AppRoutes.settings:
                return vibesterSlideRoute(const SettingsScreen(), settings);
              case AppRoutes.personalInformationSettings:
                return vibesterSlideRoute(
                  const PersonalInformationSettingsScreen(),
                  settings,
                );
              case AppRoutes.blockedAccounts:
                return vibesterSlideRoute(
                  const BlockedAccountsScreen(),
                  settings,
                );
              case AppRoutes.deleteAccount:
                return vibesterSlideRoute(
                  const DeleteAccountScreen(),
                  settings,
                );

              // USER
              case AppRoutes.profile:
                return vibesterSlideRoute(const UserProfileScreen(), settings);
              case AppRoutes.profileEditing:
                return vibesterSlideRoute(
                  const ProfileEditingScreen(),
                  settings,
                );
              case AppRoutes.userInterests:
                // Edição avulsa, vinda das configurações: salva e volta.
                return vibesterSlideRoute(
                  const UserInterestsScreen(),
                  settings,
                );
              case AppRoutes.userInterestsSetup:
                // Mesma tela como passo do cadastro: sem seta de voltar, e ao
                // concluir segue para a apresentação descartando a pilha.
                return vibesterSlideRoute(
                  const UserInterestsScreen(noCadastro: true),
                  settings,
                );
              case AppRoutes.otherProfile:
                final accountid = settings.arguments as String;
                return vibesterSlideRoute(
                  OtherUsersProfileScreen(accountId: accountid),
                  settings,
                );
              case AppRoutes.followList:
                final args = settings.arguments as FollowListArgs;
                return vibesterSlideRoute(
                  FollowListScreen.fromArgs(args),
                  settings,
                );

              // NOTIFICATIONS
              case AppRoutes.notifications:
                return vibesterSlideRoute(
                  const NotificationsScreen(),
                  settings,
                );

              // SAVED
              case AppRoutes.saved:
                return vibesterSlideRoute(const SavedScreen(), settings);

              // FEED
              case AppRoutes.feed:
                return vibesterSlideRoute(const FeedScreen(), settings);
              case AppRoutes.newPublication:
                return vibesterDetailRoute(
                  const NewPublicationScreen(),
                  settings,
                );
              case AppRoutes.postDetail:
                final args = settings.arguments as PostDetailArgs;
                return vibesterDetailRoute(
                  PostDetailScreen.fromArgs(args),
                  settings,
                );

              default:
                return null;
            }
          },
        ),
      ),
    );
  }
}