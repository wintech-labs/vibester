import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mobile/models/event/event_model.dart';
import 'package:mobile/models/place/place_model.dart';
import 'package:mobile/models/user/interest_model.dart';
import 'package:mobile/providers/events/events_list_provider.dart';
import 'package:mobile/providers/notification/notification_provider.dart';
import 'package:mobile/providers/place/nearby_provider.dart';
import 'package:mobile/providers/place/place_list_provider.dart';
import 'package:mobile/providers/user/user_provider.dart';
import 'package:mobile/routes/app_routes.dart';
import 'package:mobile/service/user/interests_storage.dart';
import 'package:mobile/theme/app_spacing.dart';
import 'package:mobile/theme/theme_extensions.dart';
import 'package:mobile/utils/event_time.dart';
import 'package:mobile/widgets/cards/event/event_poster_card.dart';
import 'package:mobile/widgets/cards/place/place_tile.dart';
import 'package:mobile/widgets/common/section_header.dart';
import 'package:mobile/widgets/common/vibester_chip.dart';
import 'package:mobile/widgets/common/vibester_skeleton.dart';
import 'package:mobile/widgets/common/vibester_state.dart';
import 'package:mobile/widgets/common/vibester_tag.dart';
import 'package:mobile/widgets/graffiti/scribble_mark.dart';
import 'package:mobile/widgets/graffiti/spray_glow.dart';
import 'package:mobile/widgets/motion/staggered_entrance.dart';
import 'package:mobile/widgets/motion/vibester_pressable.dart';
import 'package:provider/provider.dart';

/// HOJE — a tela de descoberta do Vibester.
///
/// A Home anterior era um `TabBar` de três abas (FEED / DESTAQUES / EM ALTA)
/// onde a pergunta central do produto — *o que eu faço hoje?* — não era
/// respondida por nenhuma delas isoladamente: destaques trazia carrossel
/// automático de eventos da semana misturado com ofertas fictícias, e "em
/// alta" era uma lista de estabelecimentos com busca.
///
/// Aqui a tela é uma sequência editorial numerada, e cada bloco responde uma
/// pergunta concreta, na ordem em que ela ocorre a quem está decidindo o
/// rolê:
///
/// ```text
/// 01  ACONTECENDO AGORA   → dá pra sair agora?
/// 02  AINDA HOJE          → e mais tarde?
/// 03  PERTO DE VOCÊ       → o que tem do meu lado?
/// 04  EM ALTA             → onde tem gente?
/// 05  ESSA SEMANA         → e se eu quiser planejar?
/// ```
///
/// As seções que não têm dado real simplesmente não aparecem, e a numeração
/// se ajusta — a tela nunca mostra um trilho vazio nem uma promessa que os
/// dados não sustentam. A seção de "ofertas exclusivas" da versão anterior
/// foi removida: ela era alimentada por uma lista fixa no código (descontos,
/// nomes de bares e condições inventados), e conteúdo fabricado apresentado
/// como oferta real não é opção.
///
/// **Quando o dia está vazio**, o bloco 02 não vira uma tela de "nada por
/// aqui": a semana sobe pro lugar dele, em carrossel, e o estado vazio de
/// verdade só aparece se a semana também estiver vazia. O aviso de que hoje
/// não tem nada continua sendo dado — vai no subtítulo da seção, senão o
/// usuário lê os cards da semana como se fossem de hoje.
class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  /// Categoria selecionada na régua de filtros. Nula = tudo.
  String? _category;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool force = false}) async {
    if (!mounted) return;
    await Future.wait([
      context.read<EventsListProvider>().fetchEvents(force: force),
      context.read<EventsListProvider>().fetchWeekEvents(force: force),
      context.read<PlaceListProvider>().fetchPlaces(force: force),
      context.read<NearbyProvider>().load(force: force),
    ]);
  }

  /// Filtro por categoria, aplicado do lado do cliente sobre o que já está em
  /// memória: o backend não expõe filtro combinado de evento por categoria, e
  /// uma ida à rede a cada toque de chip deixaria o filtro lento justamente
  /// no gesto que precisa parecer instantâneo.
  bool _matches(String categoria) =>
      _category == null ||
      categoria.toLowerCase().contains(_category!.toLowerCase());

  List<EventModel> _filterEvents(List<EventModel> source) =>
      source.where((e) => _matches(e.categoria)).toList();

  List<PlaceModel> _filterPlaces(List<PlaceModel> source) =>
      source.where((p) => _matches(p.categoria)).toList();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final events = context.watch<EventsListProvider>();
    final places = context.watch<PlaceListProvider>();
    final nearby = context.watch<NearbyProvider>();

    final all = _filterEvents(events.events);
    final happeningNow = all.where((e) => e.isHappeningNow).toList();
    final laterToday =
        all
            .where((e) => e.isToday && !e.isHappeningNow && e.isUpcoming)
            .toList()
          ..sort((a, b) => a.dataDoEvento.compareTo(b.dataDoEvento));

    // A semana sai da união de duas fontes, não só do endpoint /events/week:
    // ele responde por uma janela de datas que a tela não controla (pode
    // começar na segunda e vir cheio de coisa já passada, que o isUpcoming
    // corta), enquanto events.events já está em memória e costuma trazer bem
    // mais. Juntar as duas e deduplicar por id dá o que realmente existe de
    // futuro, sem depender do recorte que o backend escolheu.
    final seenWeek = <String>{};
    final week =
        _filterEvents([...events.weekEvents, ...events.events])
            .where((e) => e.isUpcoming && !e.isToday)
            .where(
              (e) => seenWeek.add(e.id ?? '${e.titulo}|${e.dataDoEvento}'),
            )
            .toList()
          ..sort((a, b) => a.dataDoEvento.compareTo(b.dataDoEvento));

    final hot =
        _filterPlaces(places.places).where((p) => p.nivelMovimento > 0).toList()
          ..sort((a, b) => b.nivelMovimento.compareTo(a.nivelMovimento));

    final nearbyPlaces = _filterPlaces(nearby.places);

    final firstLoad =
        events.isLoading && events.events.isEmpty && places.places.isEmpty;

    // A condicional do bloco 02: nada hoje → a semana assume o lugar; nada
    // hoje **e** nada na semana → aí sim o estado vazio com a lua. E quando a
    // semana assume aqui em cima, ela não pode aparecer de novo lá embaixo.
    final nothingToday = happeningNow.isEmpty && laterToday.isEmpty;
    final weekTakesOver = nothingToday && week.isNotEmpty;

    // Numeração corrida: só conta as seções que realmente vão à tela.
    var section = 0;
    int next() => ++section;

    return Scaffold(
      backgroundColor: colors.noturno,
      body: RefreshIndicator(
        color: colors.ambar,
        backgroundColor: colors.surface,
        onRefresh: () => _load(force: true),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: _Masthead(happeningNow: happeningNow.length),
            ),

            SliverPersistentHeader(
              pinned: true,
              delegate: _CategoryRailDelegate(
                selected: _category,
                onSelected: (value) => setState(() => _category = value),
                background: colors.noturno,
              ),
            ),

            if (firstLoad)
              const SliverToBoxAdapter(child: _HomeSkeleton())
            else ...[
              if (happeningNow.isNotEmpty)
                _rail(
                  index: next(),
                  eyebrow: 'ACONTECENDO AGORA',
                  title: 'Tá rolando',
                  items: happeningNow,
                ),

              if (laterToday.isNotEmpty)
                _rail(
                  index: next(),
                  eyebrow: 'AINDA HOJE',
                  title: 'Seu próximo rolê',
                  items: laterToday,
                ),

              if (weekTakesOver)
                _WeekCarousel(
                  index: next(),
                  events: week.take(12).toList(),
                  subtitle: _category == null
                      ? 'Isso é o que vem aí.'
                      : 'Isso é o que vem aí em $_category.',
                )
              else if (nothingToday)
                SliverToBoxAdapter(child: _NothingToday(category: _category)),

              if (nearby.status != LocationStatus.unavailable ||
                  nearbyPlaces.isNotEmpty)
                _NearbySection(
                  index: next(),
                  places: nearbyPlaces,
                  provider: nearby,
                ),

              if (hot.isNotEmpty)
                _HotSection(index: next(), places: hot.take(5).toList()),

              if (week.isNotEmpty && !weekTakesOver)
                _WeekSection(index: next(), events: week.take(6).toList()),
            ],

            const SliverToBoxAdapter(child: _Colophon()),
            const SliverPadding(
              padding: EdgeInsets.only(bottom: AppSpacing.dockGap),
            ),
          ],
        ),
      ),
    );
  }

  /// Trilho horizontal de cartazes de evento.
  Widget _rail({
    required int index,
    required String eyebrow,
    required String title,
    required List<EventModel> items,
  }) {
    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            index: index,
            eyebrow: eyebrow,
            title: title,
            brush: index == 1,
            onActionTap: () =>
                Navigator.pushNamed(context, AppRoutes.eventList),
          ),
          // O cartaz acompanha a largura da tela (com o próximo aparecendo
          // pela metade na borda, que é o que convida a arrastar) em vez de
          // uma largura fixa em pixel, que em aparelho estreito não deixa
          // espaço pro "espia" e em tela larga fica pequena demais.
          _HeroRail(items: items, hero: index == 1),
        ],
      ),
    );
  }
}

class _HeroRail extends StatelessWidget {
  final List<EventModel> items;
  final bool hero;

  const _HeroRail({required this.items, required this.hero});

  @override
  Widget build(BuildContext context) {
    // Largura e altura vêm do próprio card: o trilho não tem opinião sobre o
    // tamanho do cartaz, só reserva a altura que ele declara.
    final width = EventPosterCard.railWidth(context);

    return SizedBox(
      height: EventPosterCard.railHeight(context),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screen),
        physics: const BouncingScrollPhysics(),
        itemCount: items.length,
        clipBehavior: Clip.none,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.md),
        itemBuilder: (context, i) => StaggeredEntrance(
          index: i,
          child: EventPosterCard(
            event: items[i],
            width: width,
            // Dois cartazes do mesmo evento em trilhos diferentes da mesma
            // tela dariam duas tags de Hero iguais e quebrariam a transição;
            // só o primeiro trilho participa dela.
            hero: hero,
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------
// Cabeçalho editorial
// -----------------------------------------------------------------------

/// A manchete da Home. É o primeiro contato do usuário com o produto no dia,
/// e o único lugar do app onde a tipografia ocupa a tela inteira sem pedir
/// licença — é ela que responde "o que é o Vibester?" nos primeiros segundos.
class _Masthead extends StatelessWidget {
  final int happeningNow;

  const _Masthead({required this.happeningNow});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final type = context.typography;
    final user = context.watch<UserProvider>().user;
    final unread = context.watch<NotificationProvider>().unreadCount;

    final city = (user?.cidade ?? '').trim();
    final stamp = [
      todayStamp(),
      if (city.isNotEmpty) city.toUpperCase(),
    ].join('  ·  ');

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.screen,
          AppSpacing.md,
          AppSpacing.screen,
          AppSpacing.lg,
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Mancha de spray atrás da manchete: profundidade sem blur.
            Positioned(
              left: -90,
              top: -70,
              child: SprayGlow(color: colors.ambar, size: 240, intensity: 0.2),
            ),

            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(
                        stamp,
                        style: type.monoEyebrow.copyWith(
                          color: colors.textMuted,
                        ),
                      ),
                    ),
                    _BellButton(unread: unread),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),

                // "O QUE TEM HOJE?" em três linhas, com o mascote ocupando o
                // espaço morto à direita na altura exata do bloco.
                const _Headline(),

                const SizedBox(height: AppSpacing.lg),
                if (happeningNow > 0)
                  VibesterTag(
                    happeningNow == 1
                        ? '1 ROLÊ ACONTECENDO AGORA'
                        : '$happeningNow ROLÊS ACONTECENDO AGORA',
                    tone: TagTone.live,
                  )
                else
                  Text(
                    greetingForNow(),
                    style: type.monoSmall.copyWith(color: colors.textDisabled),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A manchete em três linhas com o mascote ao lado.
///
/// O tamanho do mascote não é uma constante chutada: as três linhas são
/// medidas com [TextPainter] na fonte real e no fator de acessibilidade em
/// uso, e a imagem recebe exatamente essa altura. Se o usuário aumentar a
/// fonte do sistema, o mascote cresce junto em vez de descolar da manchete.
///
/// A largura é o que sobra da linha mais longa (incluindo o risco embaixo do
/// "HOJE?", que é mais largo que a palavra) — ou seja, o mascote nunca
/// empurra nem espreme a tipografia, que é a dona da tela. Em aparelho
/// estreito demais pra caber os dois, o mascote sai de cena em vez de virar
/// uma tirinha.
class _Headline extends StatelessWidget {
  const _Headline();

  /// Precisa estar declarado no `pubspec.yaml` (ver `flutter: assets:`).
  static const _asset = 'assets/img/mascote/mascote.png';

  /// Versão fria do mascote, para o tema claro.
  ///
  /// Não é um arquivo solto: os três tons do fogo são exatamente `brasa`,
  /// `ambar` e a interpolação entre os dois na paleta clara. Trocar aqui é o
  /// que impede o mascote de ser a única coisa quente numa tela fria.
  static const _assetLight = 'assets/img/mascote/mascote_azul.png';

  /// Abaixo disso o mascote fica irreconhecível — melhor não desenhar.
  static const _minWidth = 64.0;

  /// Largura útil do [ScribbleMark] sob o "HOJE?" (168 de traço deslocado
  /// 4px pra esquerda). Entra na conta pro mascote não encostar no risco.
  static const _scribbleWidth = 164.0;

  /// Respiro entre a manchete e o mascote. É só aqui que se mexe.
  static const _gap = AppSpacing.xxl;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final style = context.typography.displayHuge;
    final scaler = MediaQuery.textScalerOf(context);
    // Segue o brilho efetivo do tema, não o `ThemeMode` do provider: assim
    // `ThemeMode.system` também acerta o mascote.
    final mascote = Theme.of(context).brightness == Brightness.light
        ? _assetLight
        : _asset;
    final direction = Directionality.of(context);

    Size measure(String text) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: direction,
        textScaler: scaler,
      )..layout();
      final size = painter.size;
      painter.dispose();
      return size;
    }

    final first = measure('O QUE');
    final second = measure('TEM');
    final third = measure('HOJE?');

    final blockHeight = first.height + second.height + third.height;
    final blockWidth = math.max(
      math.max(first.width, math.max(second.width, third.width)),
      _scribbleWidth,
    );

    final available = MediaQuery.sizeOf(context).width - AppSpacing.screen * 2;
    final room = available - blockWidth - _gap;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'O QUE\nTEM',
              style: style.copyWith(color: colors.textPrimary),
            ),
            Stack(
              clipBehavior: Clip.none,
              children: [
                Text('HOJE?', style: style.copyWith(color: colors.ambar)),
                Positioned(
                  left: -4,
                  bottom: -2,
                  child: ScribbleMark(
                    shape: ScribbleShape.underline,
                    color: colors.brasa,
                    size: const Size(168, 14),
                    strokeWidth: 3,
                  ),
                ),
              ],
            ),
          ],
        ),

        if (room >= _minWidth) ...[
          const SizedBox(width: _gap),
          // Expanded em vez de largura fixa: o slot toma todo o resto da
          // linha, e o centerRight encosta o mascote na borda. O contain
          // mantém a altura travada na da manchete.
          Expanded(
            child: SizedBox(
              height: blockHeight,
              child: Image.asset(
                mascote,
                fit: BoxFit.contain,
                alignment: Alignment.centerRight,
                filterQuality: FilterQuality.medium,
                // Decorativo: quem lê por leitor de tela já ouviu a manchete.
                excludeFromSemantics: true,
                // Asset faltando não derruba o cabeçalho inteiro.
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _BellButton extends StatelessWidget {
  final int unread;

  const _BellButton({required this.unread});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;

    return Semantics(
      button: true,
      label: unread > 0 ? 'Notificações, $unread não lidas' : 'Notificações',
      child: VibesterPressable(
        borderRadius: AppRadius.pillAll,
        onTap: () => Navigator.pushNamed(context, AppRoutes.notifications),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Icon(
                Icons.notifications_none_rounded,
                size: 24,
                color: colors.textSecondary,
              ),
              if (unread > 0)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: colors.brasa,
                      shape: BoxShape.circle,
                      border: Border.all(color: colors.noturno, width: 1.5),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------
// Régua de categorias (fixa no topo ao rolar)
// -----------------------------------------------------------------------

class _CategoryRailDelegate extends SliverPersistentHeaderDelegate {
  final String? selected;
  final ValueChanged<String?> onSelected;
  final Color background;

  const _CategoryRailDelegate({
    required this.selected,
    required this.onSelected,
    required this.background,
  });

  /// Altura declarada da régua. O filho **precisa** preencher exatamente
  /// isto: um `SliverPersistentHeader` fixo que pinta menos do que declara
  /// dispara `layoutExtent exceeds paintExtent` e derruba o viewport inteiro.
  static const _extent = 60.0;

  @override
  double get minExtent => _extent;

  @override
  double get maxExtent => _extent;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    return SizedBox.expand(
      child: ColoredBox(
        color: background,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            VibesterChipRail(
              children: [
                VibesterChip(
                  label: 'Tudo',
                  selected: selected == null,
                  onTap: () => onSelected(null),
                ),
                // Interesses do usuário primeiro (escolhidos no onboarding e
                // guardados localmente), depois o resto — a régua abre no que
                // ele curte sem esconder nada.
                for (final interest in [
                  ...InterestsStorage.selected,
                  ...defaultInterests.where((i) => !i.selected),
                ])
                  VibesterChip(
                    label: interest.label,
                    emoji: interest.emoji,
                    selected: selected == interest.label,
                    onTap: () => onSelected(
                      selected == interest.label ? null : interest.label,
                    ),
                  ),
              ],
            ),
            // Fio que só aparece quando há conteúdo passando por baixo — marca
            // que a régua está fixa, sem sombra pesada.
            AnimatedOpacity(
              opacity: overlaps || shrinkOffset > 0 ? 1 : 0,
              duration: const Duration(milliseconds: 160),
              child: Container(height: 1, color: context.colors.hairline),
            ),
          ],
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_CategoryRailDelegate old) =>
      old.selected != selected || old.background != background;
}

// -----------------------------------------------------------------------
// Seções
// -----------------------------------------------------------------------

/// "Essa semana" em carrossel — só aparece no lugar do dia vazio.
///
/// O card é o mesmo [EventPosterCard] usado nos trilhos de "Acontecendo
/// agora"/"Ainda hoje" (variante `hero`, cartaz com imagem e texto por cima),
/// em vez de um cartão próprio: o carrossel é só um *layout* diferente
/// (`PageView` de um item por vez) para o mesmo componente de evento do
/// resto do app, não uma composição visual à parte.
///
/// `PageView` com `viewportFraction` abaixo de 1 e `padEnds: false` é o que
/// deixa a borda do próximo card à mostra e convida a arrastar.
///
/// O avanço automático foi mantido, com três diferenças em relação ao
/// original: o timer é anulável e cancelado no `dispose` (não explode se a
/// tela morrer antes do primeiro tick), ele reinicia a contagem quando o
/// usuário arrasta — em vez de puxar o card da mão dele no meio do gesto — e
/// a volta pro começo é `jumpToPage`, não `animateToPage`: animar do último
/// pro primeiro é o que fazia o carrossel rebobinar passando por todos os
/// cards de trás pra frente.
class _WeekCarousel extends StatefulWidget {
  final int index;
  final List<EventModel> events;
  final String subtitle;

  const _WeekCarousel({
    required this.index,
    required this.events,
    required this.subtitle,
  });

  @override
  State<_WeekCarousel> createState() => _WeekCarouselState();
}

class _WeekCarouselState extends State<_WeekCarousel> {
  /// Fração da viewport que cada página ocupa. É o valor que faz o cartaz da
  /// semana sair com a mesma largura do cartaz dos trilhos
  /// (`EventPosterCard.railWidth`, 74% da tela) — a semana é a mesma fileira
  /// de opções das outras seções, só que andando sozinha. O que sobra à
  /// direita é o próximo cartaz espiando.
  static const _viewportFraction = 0.82;

  /// Teto de largura do cartaz. O `viewportFraction` é relativo à tela, e sem
  /// isso o card viraria um pôster de 600pt em tablet.
  static const _maxCardWidth = 340.0;

  static const _cardGap = AppSpacing.md;
  static const _interval = Duration(seconds: 4);
  static const _transition = Duration(milliseconds: 700);

  final _controller = PageController(viewportFraction: _viewportFraction);
  Timer? _timer;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _restart();
  }

  @override
  void didUpdateWidget(covariant _WeekCarousel old) {
    super.didUpdateWidget(old);
    // A lista muda quando o filtro de categoria muda, e o índice atual pode
    // acabar apontando pra fora dela.
    if (old.events.length != widget.events.length) {
      _page = _page.clamp(0, math.max(0, widget.events.length - 1));
      _restart();
    }
  }

  void _restart() {
    _timer?.cancel();
    if (widget.events.length < 2) return;
    _timer = Timer.periodic(_interval, (_) => _advance());
  }

  void _advance() {
    if (!mounted || !_controller.hasClients) return;
    // Quem desligou animações no sistema não quer carrossel andando sozinho.
    if (MediaQuery.disableAnimationsOf(context)) return;

    final next = _page + 1;
    if (next >= widget.events.length) {
      _controller.jumpToPage(0);
      _page = 0;
      return;
    }
    _controller.animateToPage(
      next,
      duration: _transition,
      curve: Curves.easeInOut,
    );
    _page = next;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A conta parte do que sobra depois da margem lateral padrão de tela: o
    // primeiro card encosta no mesmo lugar que todo o resto do conteúdo, e o
    // `viewportFraction` abaixo de 1 é o que deixa o próximo espiar na borda
    // direita. A proporção do cartaz é a mesma do card em qualquer trilho.
    final pageWidth =
        (MediaQuery.sizeOf(context).width - AppSpacing.screen) *
        _viewportFraction;
    final cardWidth = math.min(pageWidth - _cardGap, _maxCardWidth);
    final cardHeight = cardWidth / EventPosterCard.posterAspect;

    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            index: widget.index,
            eyebrow: 'ESSA SEMANA',
            title: 'Dá pra se planejar',
            subtitle: widget.subtitle,
            onActionTap: () =>
                Navigator.pushNamed(context, AppRoutes.eventList),
          ),
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.screen),
            child: SizedBox(
              height: cardHeight,
              child: NotificationListener<UserScrollNotification>(
                // Mão no carrossel zera a contagem: o próximo salto
                // automático só vem 4s depois que a pessoa parou de mexer.
                onNotification: (_) {
                  _restart();
                  return false;
                },
                child: PageView.builder(
                  padEnds: false,
                  controller: _controller,
                  onPageChanged: (i) => _page = i,
                  clipBehavior: Clip.none,
                  itemCount: widget.events.length,
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.only(right: _cardGap),
                    child: EventPosterCard(
                      event: widget.events[i],
                      width: cardWidth,
                      hero: false,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NearbySection extends StatelessWidget {
  final int index;
  final List<PlaceModel> places;
  final NearbyProvider provider;

  const _NearbySection({
    required this.index,
    required this.places,
    required this.provider,
  });

  @override
  Widget build(BuildContext context) {
    final Widget body;

    if (provider.status == LocationStatus.unavailable) {
      body = _InlineNotice(
        icon: Icons.location_off_outlined,
        message:
            'Liga a localização pra gente mostrar o que tá acontecendo do '
            'seu lado.',
        actionLabel: 'PERMITIR',
        onAction: () => provider.load(force: true),
      );
    } else if (provider.isLoading && places.isEmpty) {
      body = const _RailSkeleton(height: 250, itemWidth: 190);
    } else if (provider.error != null && places.isEmpty) {
      body = _InlineNotice(
        icon: Icons.wifi_off_rounded,
        message: provider.error!,
        actionLabel: 'TENTAR DE NOVO',
        onAction: () => provider.load(force: true),
      );
    } else if (places.isEmpty) {
      body = const _InlineNotice(
        icon: Icons.explore_off_outlined,
        message: 'Nada cadastrado num raio de 15km por enquanto.',
      );
    } else {
      body = SizedBox(
        height: 250,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screen),
          physics: const BouncingScrollPhysics(),
          clipBehavior: Clip.none,
          itemCount: places.length,
          separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.md),
          itemBuilder: (context, i) => StaggeredEntrance(
            index: i,
            child: PlaceTile(
              place: places[i],
              variant: PlaceTileVariant.rail,
              hero: false,
            ),
          ),
        ),
      );
    }

    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            index: index,
            eyebrow: 'PERTO DE VOCÊ',
            title: 'Do seu lado',
          ),
          body,
        ],
      ),
    );
  }
}

class _HotSection extends StatelessWidget {
  final int index;
  final List<PlaceModel> places;

  const _HotSection({required this.index, required this.places});

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            index: index,
            eyebrow: 'EM ALTA',
            title: 'Onde tem gente',
            subtitle: 'Movimento medido pelo próprio Vibester.',
            onActionTap: () =>
                Navigator.pushNamed(context, AppRoutes.hotPlaces),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screen),
            child: Column(
              children: [
                for (final (i, place) in places.indexed)
                  StaggeredEntrance(
                    index: i,
                    child: PlaceTile(place: place, hero: false),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WeekSection extends StatelessWidget {
  final int index;
  final List<EventModel> events;

  const _WeekSection({required this.index, required this.events});

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            index: index,
            eyebrow: 'ESSA SEMANA',
            title: 'Dá pra se planejar',
            onActionTap: () =>
                Navigator.pushNamed(context, AppRoutes.eventList),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screen),
            child: Column(
              children: [
                for (final (i, event) in events.indexed)
                  StaggeredEntrance(
                    index: i,
                    child: EventPosterCard(
                      event: event,
                      variant: EventCardVariant.wide,
                      hero: false,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------
// Estados
// -----------------------------------------------------------------------

/// Último recurso: não há nada hoje **nem** na semana (ou nada nessa
/// categoria). O texto muda conforme o motivo, porque "nada por aqui" sem
/// explicar o filtro ativo faz o usuário achar que o app está quebrado.
class _NothingToday extends StatelessWidget {
  final String? category;

  const _NothingToday({required this.category});

  @override
  Widget build(BuildContext context) {
    return VibesterState(
      headline: 'Hoje tá quieto',
      message: category == null
          ? 'Nenhum evento marcado pra hoje nem pra essa semana. Dá uma '
                'olhada nos lugares em alta enquanto isso.'
          : 'Nenhum rolê de $category por aqui. Tira o filtro pra ver o resto '
                'do que tá rolando.',
      icon: Icons.nightlight_outlined,
    );
  }
}

/// Aviso curto dentro de uma seção — não ocupa a tela toda como
/// [VibesterState], porque o resto da Home continua útil.
class _InlineNotice extends StatelessWidget {
  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _InlineNotice({
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screen,
        0,
        AppSpacing.screen,
        AppSpacing.sm,
      ),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: AppRadius.mdAll,
          border: Border.all(color: colors.hairline),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: colors.textMuted),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                message,
                style: context.typography.bodySmall.copyWith(
                  color: colors.textMuted,
                ),
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(width: AppSpacing.sm),
              VibesterPressable(
                onTap: onAction,
                borderRadius: AppRadius.pillAll,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  child: Text(
                    actionLabel!,
                    style: context.typography.monoMicro.copyWith(
                      color: colors.ambar,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Esqueleto da primeira carga: reproduz o ritmo da tela (um trilho de
/// cartazes, um de lugares) pra a página não pular quando os dados chegam.
class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: AppSpacing.xl),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: AppSpacing.screen),
          child: VibesterSkeleton(width: 180, height: 26),
        ),
        const SizedBox(height: AppSpacing.lg),
        // Mesma medida do cartaz de verdade: quando os dados chegam, a
        // página não pula.
        _RailSkeleton(
          height: EventPosterCard.railHeight(context),
          itemWidth: EventPosterCard.railWidth(context),
        ),
        const SizedBox(height: AppSpacing.xxl),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: AppSpacing.screen),
          child: VibesterSkeleton(width: 140, height: 26),
        ),
        const SizedBox(height: AppSpacing.lg),
        const _RailSkeleton(height: 250, itemWidth: 190),
      ],
    );
  }
}

class _RailSkeleton extends StatelessWidget {
  final double height;
  final double itemWidth;

  const _RailSkeleton({required this.height, required this.itemWidth});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screen),
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 3,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.md),
        itemBuilder: (_, _) => VibesterSkeleton(
          width: itemWidth,
          height: height,
          borderRadius: AppRadius.mdAll,
        ),
      ),
    );
  }
}

/// Fecho da página — o "assinado" do cartaz. Encerra o scroll em vez de
/// deixar a lista terminar no vazio.
class _Colophon extends StatelessWidget {
  const _Colophon();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screen,
        AppSpacing.huge,
        AppSpacing.screen,
        AppSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'VIBESTER',
            style: context.typography.displayMedium.copyWith(
              color: colors.grey.withValues(alpha: 0.18),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'CHEGOU ATÉ AQUI  ·  PUXA PRA ATUALIZAR',
            style: context.typography.monoMicro.copyWith(
              color: colors.textDisabled,
            ),
          ),
        ],
      ),
    );
  }
}