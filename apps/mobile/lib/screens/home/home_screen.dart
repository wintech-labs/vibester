import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile/providers/safety/block_provider.dart';
import 'package:mobile/providers/notification/notification_provider.dart';
import 'package:mobile/providers/preferences/preferences_provider.dart';
import 'package:mobile/providers/user/user_provider.dart';
import 'package:mobile/routes/app_routes.dart';
import 'package:mobile/screens/explore/explore_screen.dart';
import 'package:mobile/screens/feed/feed_screen.dart';
import 'package:mobile/screens/home/today_screen.dart';
import 'package:mobile/screens/user/user_profile_screen.dart';
import 'package:mobile/theme/app_motion.dart';
import 'package:mobile/theme/theme_extensions.dart';
import 'package:mobile/widgets/navigation/vibester_navbar.dart';
import 'package:provider/provider.dart';
import 'package:mobile/service/interaction/interaction_tracker.dart';

/// Casca de navegação do app.
///
/// A arquitetura anterior tinha **duas** navegações empilhadas: quatro abas
/// embaixo (home / busca / favoritos / perfil) e, dentro da primeira, mais
/// três abas no topo (FEED / DESTAQUES / EM ALTA). Isso significava que o
/// conteúdo mais importante do produto — o que está acontecendo hoje — ficava
/// atrás de uma aba dentro de uma aba, e que o botão voltar precisava de uma
/// máquina de estados só pra saber onde o usuário estava.
///
/// Aqui existe uma navegação só, com quatro destinos e uma ação:
///
/// * **FEED** — o social: o que as pessoas estão postando (tela inicial).
/// * **EXPLORAR** — busca ativa: categorias, lugares, eventos, pessoas.
/// * **(+)** — publicar (ação, não destino: volta pra onde o usuário estava).
/// * **HOJE** — descoberta: o que está rolando agora, perto, nesta semana.
/// * **VOCÊ** — identidade, salvos e ajustes.
///
/// Favoritos deixou de ser um destino de primeiro nível (virou uma seção
/// dentro de VOCÊ, junto da identidade — que é onde o usuário procura o que
/// ele mesmo salvou) e notificações saíram de dentro da aba de favoritos, um
/// lugar onde ninguém as encontraria, para o sino do cabeçalho de HOJE.
///
/// **Arrastar entre destinos.** Além do toque na navbar, dá para trocar de
/// destino arrastando a tela para os lados (FEED ↔ BUSCA ↔ HOJE ↔ VOCÊ; a
/// ação central não é página, o arraste passa direto por ela). Os destinos
/// vivem num `PageView` em vez de um `IndexedStack`.
///
/// Conflito de gestos, decidido de propósito: onde já existe algo que rola
/// para o lado dentro da tela — carrossel de fotos do post, régua de
/// categorias, carrosséis de eventos — **o conteúdo ganha**. Na última foto
/// de um post, arrastar não faz nada; não troca de aba. É o comportamento
/// padrão do Flutter para rolagens aninhadas no mesmo eixo (a mais interna
/// fica com o gesto), então não há código aqui para isso: é só não
/// atrapalhar. Onde o conteúdo não rola para o lado (post de uma foto só,
/// lista que cabe inteira na tela), o arraste chega ao `PageView` e troca de
/// destino.
///
/// PREFERÊNCIA DE ARRASTE: o arraste pode ser desligado nos Ajustes
/// ("Deslizar para trocar de aba", ligado de fábrica). Desligado, a troca de
/// destino volta a ser só pela navbar, pelo voltar do Android e pelo
/// pós-publicação — os mesmos caminhos de antes do arraste existir.
///
/// BARRAS FLUTUANTES: o dock que some ao descer e volta ao subir também pode
/// ser desligado nos Ajustes ("Barras flutuantes", ligado de fábrica).
/// Desligado, a navbar fica sempre à vista. A mesma preferência vale para o
/// cabeçalho do feed e o da tela de posts do perfil.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const _feedIndex = 0;
  static const _exploreIndex = 1;
  static const _todayIndex = 2;
  static const _profileIndex = 3;

  /// Tela inicial do produto — hoje o FEED.
  static const _homeIndex = _feedIndex;

  int _currentIndex = _homeIndex;
  bool _dockVisible = true;

  /// Páginas dos destinos. Começa na tela inicial.
  late final PageController _pageController = PageController(
    initialPage: _homeIndex,
  );

  /// Destino em que a tela **assentou** — diferente de [_currentIndex], que
  /// muda no meio do arraste, assim que a página passa da metade.
  ///
  /// Existe porque nem todo efeito de troca de destino deve disparar nesse
  /// meio do caminho. A telemetria e o destaque da navbar, sim: a partir da
  /// metade, o destino novo é o que ocupa a maior parte da tela. Já as
  /// leituras de rede (selo de não lidas, perfil) só fazem sentido quando a
  /// pessoa de fato ficou no destino — quem arrasta até a metade e desiste,
  /// ou vai e volta indeciso, dispararia uma requisição a cada passagem.
  int _settledIndex = _homeIndex;

  /// Posição contínua da página enquanto o usuário arrasta (0 = FEED, 1.5 =
  /// entre BUSCA e HOJE), repassada à navbar para o destaque acompanhar o
  /// dedo. `null` quando não há arraste em curso — aí a navbar anima sozinha,
  /// com a mola dela, como no toque.
  final ValueNotifier<double?> _navbarDragPosition = ValueNotifier(null);

  /// Um arraste do usuário entre destinos está em curso (do toque até a
  /// página assentar, inclusive o "encaixe" depois de soltar).
  bool _userDragging = false;

  final _feedKey = GlobalKey<FeedScreenState>();
  final _exploreKey = GlobalKey<ExploreScreenState>();
  final _todayKey = GlobalKey<TodayScreenState>();
  final _profileKey = GlobalKey<UserProfileScreenState>();

  /// Momento do último toque no voltar do Android, para o padrão "aperte
  /// duas vezes para sair".
  DateTime? _lastBackPress;

  /// Instanciadas uma vez só: trocar de destino não deve descartar o estado
  /// (posição de scroll, imagens já carregadas) do destino anterior.
  ///
  /// Com o `PageView`, isso depende também do [_KeepAlivePage] em volta de
  /// cada uma no `build`: sem ele, a página que sai da tela é descartada.
  /// Diferença para o `IndexedStack` de antes: cada destino só é montado na
  /// primeira vez que aparece (por toque ou arraste), não todos na abertura
  /// do app.
  late final List<Widget> _destinations = [
    FeedScreen(key: _feedKey),
    ExploreScreen(key: _exploreKey),
    TodayScreen(key: _todayKey),
    UserProfileScreen(key: _profileKey),
  ];

  static const _navDestinations = [
    NavbarDestination(
      icon: Icons.dynamic_feed_outlined,
      activeIcon: Icons.dynamic_feed,
      label: 'FEED',
    ),
    NavbarDestination(
      icon: Icons.explore_outlined,
      activeIcon: Icons.explore,
      label: 'BUSCA',
    ),
    NavbarDestination(
      icon: Icons.bolt_outlined,
      activeIcon: Icons.bolt,
      label: 'HOJE',
    ),
    NavbarDestination(
      icon: Icons.person_outline_rounded,
      activeIcon: Icons.person_rounded,
      label: 'VOCÊ',
    ),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // CORREÇÃO: o tracker vive acima da Home (no `MyApp`) e sobrevive a ela.
    // Quem sai da conta estando em VOCÊ — é de lá que se chega aos Ajustes —
    // deixava a flag da aba do feed desligada, e a próxima conta a entrar
    // caía no feed sem medição nenhuma. A Home sempre nasce no feed, então
    // alinha a flag com o destino inicial logo ao montar. `read` (via
    // `maybeInteractionTracker`) não cria dependência e pode ser usado aqui.
    maybeInteractionTracker(
      context,
    )?.setFeedTabActive(_currentIndex == _feedIndex);

    // O contador não vinha de lugar nenhum em quem entrava pelo login: só o
    // boot com sessão salva o buscava, e a troca de destino (que sai cedo
    // quando o índice não muda). Resultado: sino sem selo até o usuário
    // trocar de aba na mão, o que lia como "não chega notificação".
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshUnreadCount();
      _loadBlocks();
    });
  }

  /// Lista de perfis bloqueados, para feed e busca esconderem na hora.
  void _loadBlocks() {
    if (!mounted) return;
    final userId = context.read<UserProvider>().user?.accountId;
    if (userId == null) return;
    context.read<BlockProvider>().load(userId);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    _navbarDragPosition.dispose();
    super.dispose();
  }

  /// O app fica aberto por longos períodos numa aba só. Sem isto o selo
  /// congela no valor de quando a tela montou: quem volta do segundo plano
  /// nunca vê o contador subir.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshUnreadCount();
    }
  }

  /// Leitura leve do contador de não lidas. Não mexe na lista carregada nem
  /// mostra loading, então pode ser chamada sempre que houver chance de o
  /// número ter mudado.
  void _refreshUnreadCount() {
    if (!mounted) return;

    final userId = context.read<UserProvider>().user?.accountId;
    if (userId == null) return;

    context.read<NotificationProvider>().fetchUnreadCount(userId);
  }

  void _handleBackPress() {
    // Qualquer destino que não seja a tela inicial volta pra ela — a tela
    // inicial do produto é uma só, e sair do app nunca acontece por acidente
    // no meio da navegação.
    if (_currentIndex != _homeIndex) {
      // CORREÇÃO: antes trocava `_currentIndex` direto aqui, por fora do
      // caminho que avisa a telemetria — o feed voltava à tela sem medir
      // nada. Agora passa pelo mesmo `_goTo` do toque na navbar.
      _goTo(_homeIndex);
      return;
    }

    final now = DateTime.now();
    final isSecondPress =
        _lastBackPress != null &&
        now.difference(_lastBackPress!) <= const Duration(seconds: 2);

    if (isSecondPress) {
      SystemNavigator.pop();
      return;
    }

    _lastBackPress = now;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Aperte voltar de novo pra sair'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _selectDestination(int index) {
    // Tocar no destino em que já se está reinicia a tela, em vez de não fazer
    // nada: é o atalho de volta ao começo sem precisar rolar nem desfazer
    // filtro por filtro.
    if (index == _currentIndex) {
      _resetDestination(index);
      return;
    }

    _goTo(index);
  }

  /// CORREÇÃO: caminho único de troca de destino.
  ///
  /// Os efeitos abaixo (telemetria, selo, perfil) moravam dentro de
  /// `_selectDestination`, ou seja, só aconteciam no toque na navbar. O voltar
  /// do Android e a volta ao feed depois de publicar trocavam `_currentIndex`
  /// direto, por fora — e o voltar deixava o feed na tela com a medição
  /// desligada. Toda troca de destino passa por aqui agora, então um caminho
  /// novo de navegação não tem como esquecer nenhum desses efeitos.
  ///
  /// Efeito colateral aceito: o voltar e o pós-publicação passam também a
  /// atualizar o selo de não lidas, uma leitura leve e sem loading.
  ///
  /// ARRASTE: o arraste é mais um desses caminhos, e também passa por aqui.
  /// [fromSwipe] diz que a página já está se movendo sob o dedo — então não
  /// há página a mover, e os efeitos de rede esperam ela assentar (ver
  /// [_settledIndex] e [_onScroll]). Nos outros caminhos (toque, voltar,
  /// pós-publicação) a troca é imediata e assenta na hora.
  void _goTo(int index, {bool fromSwipe = false}) {
    final previous = _currentIndex;

    setState(() {
      _currentIndex = index;
      _dockVisible = true;
    });

    // O IndexedStack mantém o destino anterior montado: ele deixa de ser
    // pintado, o detector de visibilidade dos cards do feed congela no último
    // valor, e o post que estava na tela continuaria acumulando atenção fora
    // do feed. O TickerMode acima não cobre isso — ele cala animação, e o
    // VisibilityDetector não depende de ticker, e sim de pintura.
    //
    // CORREÇÃO: a casca só diz se o feed é ou não a aba atual. Se há uma rota
    // por cima é outro interruptor, de responsabilidade do próprio feed — e
    // o tracker só mede com os dois liberados.
    //
    // ARRASTE: com o `PageView` no lugar do `IndexedStack` o raciocínio é o
    // mesmo — a página guardada fora da tela também deixa de ser pintada —,
    // e o aviso sai no mesmo ponto em que o destaque da navbar troca: quando
    // a página passa da metade. O tracker não precisou mudar. Durante o
    // arraste, os próprios cards do feed saindo da tela também reportam a
    // fração visível caindo, e o tracker fecha o que sai de vista pela régua
    // de sempre.
    maybeInteractionTracker(context)?.setFeedTabActive(index == _feedIndex);

    // ARRASTE: o teclado aberto na BUSCA ficaria por cima do destino
    // seguinte quando a pessoa arrasta para longe dela. Trocar de destino,
    // por qualquer caminho, fecha o teclado.
    if (index != previous) FocusManager.instance.primaryFocus?.unfocus();

    if (fromSwipe) return;

    _movePage(previous, index);
    _settle(index);
  }

  /// Leva o `PageView` ao destino escolhido por toque, voltar ou publicação.
  ///
  /// Só desliza entre vizinhos. De FEED direto para VOCÊ, a animação passaria
  /// correndo por BUSCA e HOJE — dois destinos piscando na tela sem ninguém
  /// ter pedido — e ainda os montaria à toa. Para destino distante, troca
  /// direto; o destaque da navbar continua deslizando com a mola dele.
  void _movePage(int from, int to) {
    if (from == to || !_pageController.hasClients) return;

    if ((to - from).abs() == 1 && !context.reduceMotion) {
      _pageController.animateToPage(
        to,
        duration: AppMotion.pageTransition,
        curve: AppMotion.standard,
      );
    } else {
      _pageController.jumpToPage(to);
    }
  }

  /// A página chegou à metade de outro destino durante o arraste.
  ///
  /// Toques e o voltar também disparam isto quando movem a página, mas aí
  /// [_goTo] já trocou o destino antes, e o índice chega igual — nada a fazer.
  void _onPageChanged(int page) {
    if (page == _currentIndex) return;
    _goTo(page, fromSwipe: true);
  }

  /// Efeitos que só valem quando a pessoa de fato ficou no destino.
  void _settle(int index) {
    _settledIndex = index;

    // Não há push, então o badge não se atualiza sozinho: uma leitura leve a
    // cada troca de destino é o suficiente e não custa uma tela de loading.
    _refreshUnreadCount();

    // As telas do IndexedStack são montadas uma única vez, então o perfil não
    // busca dados novos sozinho ao voltar a ficar visível.
    //
    // ARRASTE: no `PageView` o perfil só é montado na primeira visita, e numa
    // troca direta (toque em VOCÊ estando no FEED) ele ainda não existe neste
    // instante — nasce no frame seguinte. Por isso a chamada espera o frame.
    if (index == _profileIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _profileKey.currentState?.refreshProfileData();
      });
    }
  }

  /// Cada destino sabe o que "voltar ao começo" significa para ele:
  ///
  /// * FEED — sobe até o topo.
  /// * BUSCA — limpa o termo, fecha o teclado e volta à descoberta.
  /// * HOJE — sobe, tira o filtro de categoria e recarrega tudo.
  /// * VOCÊ — sobe e recarrega perfil e registros.
  void _resetDestination(int index) {
    if (!_dockVisible) setState(() => _dockVisible = true);

    switch (index) {
      case _feedIndex:
        _feedKey.currentState?.scrollToTop();
      case _exploreIndex:
        _exploreKey.currentState?.resetTab();
      case _todayIndex:
        _todayKey.currentState?.resetTab();
      case _profileIndex:
        _profileKey.currentState?.resetTab();
    }
  }

  Future<void> _openComposer() async {
    final published = await Navigator.pushNamed(
      context,
      AppRoutes.newPublication,
    );
    // Fechou sem publicar: fica onde estava.
    if (!mounted || published != true) return;

    // Publicou: leva pro FEED, no topo, onde o composer já colocou o post — a
    // ação termina mostrando o resultado dela. Sem refresh: o feed-service grava
    // o post no feed do autor de forma assíncrona, então a busca feita agora
    // provavelmente ainda viria sem ele.
    //
    // CORREÇÃO: passa pelo `_goTo`, como toda troca de destino.
    _goTo(_feedIndex);
    _feedKey.currentState?.scrollToTop();
  }

  /// Esconde o dock ao descer e devolve ao subir. O gesto é o mesmo em todos
  /// os destinos, então mora aqui e não em cada tela.
  ///
  /// ARRASTE: a mesma escuta também acompanha o arraste entre destinos — as
  /// notificações do `PageView` passam por aqui antes de tudo (profundidade
  /// 0, eixo horizontal). Rolagens horizontais de dentro das telas (carrossel
  /// de fotos, régua de categorias) chegam com profundidade maior e são
  /// ignoradas por [_onPageScroll].
  bool _onScroll(ScrollNotification notification) {
    if (notification.depth == 0 &&
        notification.metrics.axis == Axis.horizontal) {
      _onPageScroll(notification);
      return false;
    }

    if (notification is! ScrollUpdateNotification) return false;
    if (notification.metrics.axis != Axis.vertical) return false;

    // BARRAS FLUTUANTES: desligado, a rolagem não esconde nem devolve o dock
    // — ele fica fixo (ver o `visible` no `build`). Sair aqui também poupa um
    // `setState` a cada quadro de rolagem por um estado que não aparece.
    if (!context.read<PreferencesProvider>().floatingBars) return false;

    final delta = notification.scrollDelta ?? 0;
    if (delta > 3 && _dockVisible) {
      setState(() => _dockVisible = false);
    } else if (delta < -3 && !_dockVisible) {
      setState(() => _dockVisible = true);
    }
    return false;
  }

  /// Rolagem do `PageView` dos destinos.
  ///
  /// * **início** — só conta como arraste se veio de um dedo (`dragDetails`).
  ///   A animação do toque na navbar também rola o `PageView`, mas ali quem
  ///   anima o destaque é a própria navbar.
  /// * **durante** — repassa a posição contínua para o destaque da navbar
  ///   acompanhar o dedo, inclusive no encaixe depois de soltar.
  /// * **fim** — a página assentou: solta o destaque (a navbar assenta no
  ///   destino atual) e roda os efeitos de rede, se o destino mudou mesmo.
  void _onPageScroll(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _userDragging = true;
    }

    final metrics = notification.metrics;

    if (_userDragging &&
        notification is ScrollUpdateNotification &&
        metrics is PageMetrics) {
      _navbarDragPosition.value = metrics.page;
    }

    if (notification is ScrollEndNotification) {
      _userDragging = false;
      _navbarDragPosition.value = null;

      final page = metrics is PageMetrics ? metrics.page?.round() : null;
      if (page != null && page != _settledIndex) _settle(page);
    }
  }

  @override
  Widget build(BuildContext context) {
    final unread = context.watch<NotificationProvider>().unreadCount;

    // PREFERÊNCIA DE ARRASTE: `select` e não `watch` — a Home só reconstrói
    // quando *esta* preferência muda, não quando mexem em qualquer outra da
    // mesma seção dos Ajustes.
    final swipeEnabled = context.select<PreferencesProvider, bool>(
      (p) => p.swipeBetweenTabs,
    );

    // BARRAS FLUTUANTES: mesmo motivo do `select` acima.
    final floatingBars = context.select<PreferencesProvider, bool>(
      (p) => p.floatingBars,
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBackPress();
      },
      child: Scaffold(
        backgroundColor: context.colors.noturno,
        extendBody: true,
        body: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          // Aba escondida fica montada (preserva estado e rolagem), mas com
          // o ticker mudo: nada anima fora da tela, e o vídeo do feed pausa.
          //
          // ARRASTE: `PageView` no lugar do `IndexedStack`. O "fica montada"
          // agora vem do [_KeepAlivePage]; o ticker mudo continua valendo para
          // tudo que não é o destino atual — no meio do arraste, a página que
          // está entrando só ganha animação quando passa da metade.
          child: PageView(
            controller: _pageController,
            onPageChanged: _onPageChanged,
            // PREFERÊNCIA DE ARRASTE: desligado, o dedo não move mais o
            // `PageView` — mas o código continua movendo: toque na navbar,
            // voltar e pós-publicação usam `animateToPage`/`jumpToPage`, que
            // ignoram esta física. Nada mais precisou mudar por isso.
            //
            // Ligado, `null` mantém exatamente a física de antes (a de página
            // do próprio `PageView`, sobre a sem-bounce do app). Os carrosséis
            // de dentro das telas não são afetados em nenhum dos dois casos:
            // cada um tem a própria física.
            physics: swipeEnabled ? null : const NeverScrollableScrollPhysics(),
            children: [
              for (final (i, destination) in _destinations.indexed)
                _KeepAlivePage(
                  child: TickerMode(
                    enabled: i == _currentIndex,
                    child: destination,
                  ),
                ),
            ],
          ),
        ),
        // Esconder/mostrar no scroll é intenção declarada aqui; a coreografia
        // (deslocamento, opacidade, duração) vive dentro da navbar.
        bottomNavigationBar: VibesterNavbar(
          destinations: _navDestinations,
          currentIndex: _currentIndex,
          onDestinationSelected: _selectDestination,
          onCreate: _openComposer,
          // As notificações moram no sino do cabeçalho de HOJE. O selo estava
          // apontando para VOCÊ — sobra de quando elas ficavam dentro do
          // perfil, e que mandava o usuário procurar no lugar errado.
          badgeIndex: _todayIndex,
          badgeCount: unread,
          // BARRAS FLUTUANTES: desligado, sempre à vista. Se a preferência
          // for desligada com o dock escondido, ele volta com a animação de
          // sempre da navbar.
          visible: _dockVisible || !floatingBars,
          // ARRASTE: posição da página enquanto o usuário arrasta, para o
          // destaque acompanhar o dedo.
          dragPosition: _navbarDragPosition,
        ),
      ),
    );
  }
}

/// ARRASTE: mantém um destino vivo quando a página dele sai da tela.
///
/// O `PageView` descarta por padrão a página que não está visível. Aqui isso
/// jogaria fora a rolagem do feed, as imagens já carregadas e o filtro
/// escolhido em HOJE a cada troca — o mesmo estado que o `IndexedStack`
/// preservava antes. Continua não sendo pintada fora da tela.
class _KeepAlivePage extends StatefulWidget {
  final Widget child;

  const _KeepAlivePage({required this.child});

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}