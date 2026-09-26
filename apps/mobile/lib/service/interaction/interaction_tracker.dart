import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:mobile/models/interaction/interaction_event_model.dart';
import 'package:mobile/service/interaction/interaction_service.dart';
import 'package:uuid/uuid.dart';

/// O tracker da árvore, ou `null` se não houver nenhum acima deste contexto.
///
/// Telemetria não pode derrubar tela. Uma árvore sem o provider — teste de
/// widget que monta a tela isolada, preview, a tela reaproveitada fora do app —
/// renderiza exatamente igual, só não mede. Com `context.read` direto, esquecer
/// o provider em qualquer um desses lugares vira tela branca em vez de um dado
/// a menos, e esse é o troco errado.
InteractionTracker? maybeInteractionTracker(BuildContext context) {
  try {
    return context.read<InteractionTracker>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// Um item rastreado na tela: o mínimo que o tracker precisa para descrever um
/// evento sem consultar mais nada.
@immutable
class TrackedItem {
  const TrackedItem({
    required this.itemId,
    required this.itemType,
    required this.source,
    required this.position,
    this.authorId,
  });

  final String itemId;
  final InteractionItemType itemType;
  final InteractionSource source;
  final int position;
  final String? authorId;
}

/// Uma passagem contínua de um item pela tela.
///
/// O tempo é acumulado em vez de medido do início ao fim porque a contagem
/// **pausa** quando a superfície sai da frente do usuário (troca de aba, rota
/// empilhada, app em segundo plano) e volta quando ele retorna.
class _Episode {
  _Episode(this.item, this.startedAt) : _runningSince = startedAt;

  final TrackedItem item;

  /// Quando o item apareceu.
  ///
  /// É este o `occurredAt` da impressão, e não o instante em que ele saiu da
  /// tela: a impressão precisa **preceder** a curtida que aconteceu durante ela.
  /// Com o carimbo da saída, o like (cronometrado no toque) viria antes da
  /// impressão, e o dado diria que alguém curtiu um post que nunca foi mostrado.
  final DateTime startedAt;

  Duration _accumulated = Duration.zero;
  DateTime? _runningSince;

  void pause(DateTime now) {
    final since = _runningSince;

    if (since == null) return;

    _accumulated += _elapsed(since, now);
    _runningSince = null;
  }

  void resume(DateTime now) => _runningSince ??= now;

  Duration visibleFor(DateTime now) {
    final since = _runningSince;

    return since == null ? _accumulated : _accumulated + _elapsed(since, now);
  }

  /// Relógio de celular anda para trás (fuso, NTP, usuário mexendo na hora).
  /// Duração negativa viraria dwell negativo e seria cortada para zero adiante
  /// de qualquer forma — melhor tratar aqui, onde o motivo está escrito.
  static Duration _elapsed(DateTime from, DateTime to) {
    final delta = to.difference(from);

    return delta.isNegative ? Duration.zero : delta;
  }
}

/// Coleta dos sinais implícitos do feed — a fase 0 do ranking.
///
/// Hoje o feed é um monólogo: o backend manda 20 posts e nunca fica sabendo o
/// que aconteceu com eles. Este tracker é o caminho de volta.
///
/// ## O que ele observa
///
/// Recebe a fração visível de cada card (via `VisibilityDetector`) e traduz em
/// sinal segundo a régua abaixo, medida em tempo contínuo de exibição:
///
/// | Tempo visível | O que é registrado     | Por quê |
/// |---------------|------------------------|---------|
/// | `< 300ms`     | nada                   | Rolagem rápida: o card cruzou a borda, ninguém viu |
/// | `300ms – 1s`  | `IMPRESSION` + `SKIP`  | Ocupou a tela e foi descartado: é julgamento |
/// | `1s – 5s`     | `IMPRESSION`           | A régua de "foi visto": ≥50% visível por ≥1s |
/// | `≥ 5s`        | `IMPRESSION` + `DWELL` | Atenção sem compromisso |
///
/// O descarte abaixo de 300ms não é economia: contar a piscada como impressão
/// **envenenaria o denominador** de todo item por cima do qual o usuário rolou
/// sem chance de ver, e a taxa de engajamento passaria a medir a velocidade do
/// polegar.
///
/// O skip, ao contrário, **entra** no denominador. Tirá-lo de lá inflaria a
/// qualidade justamente dos itens que todo mundo pula.
///
/// ## Por que em lote
///
/// Uma requisição por impressão dá ~3 req/s por usuário rolando — 30.000 req/s
/// com 10 mil simultâneos, só de telemetria, mais que o resto do app somado.
/// Em lote de 15s isso cai para ~670 req/s.
///
/// ## Telemetria nunca trava nem insiste
///
/// Falha de envio **descarta** o lote em vez de reenfileirar. Perder 0,1% das
/// impressões é irrelevante; deixar o feed lento, ou um buffer crescer sem
/// teto, porque a telemetria engasgou é inaceitável.
class InteractionTracker {
  InteractionTracker({
    InteractionService? service,
    DateTime Function()? clock,
    Uuid uuid = const Uuid(),
  })  : _service = service ?? InteractionService(),
        _now = clock ?? DateTime.now,
        _uuid = uuid {
    _sessionId = _uuid.v4();
  }

  final InteractionService _service;
  final DateTime Function() _now;
  final Uuid _uuid;

  /// Fração visível a partir da qual o item conta como "na tela".
  ///
  /// 50% é a convenção da indústria para separar "apareceu" de "foi visto".
  static const double _visibilityEnter = 0.5;

  /// Fração abaixo da qual o item conta como "fora da tela".
  ///
  /// É menor que a de entrada de propósito: um card parado exatamente em 50%,
  /// com o mínimo de tremido, geraria episódios em sequência sem fim.
  static const double _visibilityExit = 0.35;

  static const Duration _minRendered = Duration(milliseconds: 300);
  static const Duration _seenThreshold = Duration(seconds: 1);
  static const Duration _dwellThreshold = Duration(seconds: 5);

  /// Teto de um episódio.
  ///
  /// Acima disso não é atenção, é celular esquecido aberto. O corte também
  /// garante que nunca se produza um `dwellMs` acima do teto de 1h do schema do
  /// serviço, que reprovaria o lote inteiro.
  static const Duration _maxDwell = Duration(minutes: 5);

  static const Duration _flushInterval = Duration(seconds: 15);

  /// Igual ao `MAX_BATCH_SIZE` do interaction-service. Acima disso a API
  /// responde 400 e o lote se perde, então o corte é obrigatório aqui.
  static const int _maxBatchSize = 50;

  /// Teto de memória do buffer, para que uma sessão longa sem rede não cresça
  /// sem fim. Ao estourar, o evento **mais antigo** sai: sinal velho vale menos.
  static const int _maxBufferedEvents = 500;

  final Map<String, _Episode> _open = {};
  final List<InteractionEvent> _buffer = [];

  late String _sessionId;
  Timer? _flushTimer;
  bool _sending = false;
  bool _disposed = false;

  /// Duas razões independentes para o feed não estar diante do usuário: o app
  /// saiu de cena, ou a superfície saiu (outra aba, rota por cima).
  ///
  /// São campos separados porque se combinam: voltar do segundo plano com o
  /// usuário parado na aba de busca não pode fazer o feed voltar a contar
  /// atenção. Um único booleano perdia exatamente esse caso.
  ///
  /// CORREÇÃO (navegação × telemetria) — a mesma lição valeu para a própria
  /// "superfície", que era um campo só (`_surfaceOnScreen`) com **dois donos**
  /// que não combinavam entre si: a casca da Home, que o desligava e religava
  /// na troca de aba, e o próprio feed, que fazia o mesmo quando uma rota era
  /// empilhada por cima dele. Um desfazia o que o outro tinha feito:
  ///
  /// * em HOJE, abrir um evento e voltar fazia o feed religar a flag, e os
  ///   posts congelados atrás daquela aba acumulavam atenção que ninguém deu;
  /// * voltar ao feed pelo botão voltar do Android não passava pelo único
  ///   ponto da casca que religava a flag, e o feed ficava na tela sem medir.
  ///
  /// Agora são dois campos, um por motivo, cada um com um único dono. O feed
  /// só mede com o app na frente **e** o feed na aba atual **e** nada por cima.
  bool _appForeground = true;

  /// O feed é a aba atual da navbar. Dono: a `HomeScreen`, pelo
  /// [setFeedTabActive].
  ///
  /// Nasce verdadeiro porque o feed também pode ser montado fora da casca (a
  /// rota `/feed`, testes de widget), e aí não existe aba a considerar.
  bool _feedTabActive = true;

  /// Há uma rota empilhada por cima do feed (perfil do autor, detalhe, um
  /// evento aberto a partir de outra aba). Dono: a `FeedScreen`, pelo
  /// [setCoveredByRoute].
  bool _coveredByRoute = false;

  bool get _visible => _appForeground && _feedTabActive && !_coveredByRoute;

  @visibleForTesting
  String get sessionId => _sessionId;

  @visibleForTesting
  List<InteractionEvent> get bufferedEvents => List.unmodifiable(_buffer);

  // ------------------------------------------------------------- visibilidade

  /// Chamado a cada mudança de fração visível de um card.
  void onVisibilityChanged(TrackedItem item, double visibleFraction) {
    if (_disposed) return;

    final episode = _open[item.itemId];

    if (episode == null) {
      // Só abre episódio com a superfície na frente do usuário. Sem esta
      // guarda, um card que continua "visível" para o detector enquanto o app
      // está em outra aba começaria a acumular atenção que ninguém deu.
      if (visibleFraction >= _visibilityEnter && _visible) {
        _open[item.itemId] = _Episode(item, _now());
      }

      return;
    }

    if (visibleFraction < _visibilityExit) {
      _closeEpisode(item.itemId, _now());
    }
  }

  /// O card saiu da árvore: lista recarregada, tela desmontada.
  ///
  /// Sem isto, um episódio aberto ficaria pendurado e a impressão nunca sairia.
  void onItemDetached(String itemId) {
    if (_disposed) return;

    _closeEpisode(itemId, _now());
  }

  /// Sinal disparado por toque — abrir perfil, abrir detalhe, pedir rota.
  ///
  /// Não aceita `IMPRESSION`/`DWELL`/`SKIP`: esses nascem da visibilidade, e
  /// deixá-los entrar por aqui abriria caminho para contá-los duas vezes.
  void recordTap(TrackedItem item, InteractionType type) {
    assert(
      type != InteractionType.impression &&
          type != InteractionType.dwell &&
          type != InteractionType.skip,
      'Sinais de visibilidade vêm de onVisibilityChanged, não de recordTap',
    );

    if (_disposed) return;

    _buffer.add(_event(item, type, _now()));
    _afterBuffer();
  }

  // -------------------------------------------------------------- ciclo de vida

  /// A aba do feed passou (ou deixou de ser) a aba atual da navbar. Chamado
  /// só pela `HomeScreen`, em toda troca de destino.
  ///
  /// Junto com [setCoveredByRoute], cobre a superfície saindo da frente do
  /// usuário sem que o app saia: troca de aba da navbar, ou rota empilhada por
  /// cima.
  ///
  /// Apenas **pausa** os episódios, não os fecha. O `VisibilityDetector` não é
  /// notificado nesses casos — os cards continuam montados, só não são
  /// pintados — e ele só dispara o callback quando a fração **muda**. Fechar
  /// aqui faria o episódio nunca reabrir na volta, porque a fração continuaria
  /// a mesma e nenhum callback viria.
  ///
  /// CORREÇÃO: o par antigo `pauseSurface`/`resumeSurface` virou dois setters,
  /// um para cada motivo (ver [_feedTabActive] e [_coveredByRoute]). Quem
  /// chama diz só o que mudou do lado dele; a decisão de medir ou não é sempre
  /// a combinação dos dois, feita em [_visible]. Assim nenhum dos donos
  /// consegue religar a contagem por cima de um motivo que é do outro.
  void setFeedTabActive(bool active) {
    if (_disposed || _feedTabActive == active) return;

    final estavaVisivel = _visible;

    _feedTabActive = active;
    _applyVisibility(estavaVisivel);
  }

  /// Uma rota foi empilhada por cima do feed ([covered] verdadeiro) ou a que
  /// estava por cima saiu. Chamado só pela `FeedScreen`, pelo `RouteAware`.
  ///
  /// Mesma regra do [setFeedTabActive]: pausa os episódios, não os fecha.
  void setCoveredByRoute(bool covered) {
    if (_disposed || _coveredByRoute == covered) return;

    final estavaVisivel = _visible;

    _coveredByRoute = covered;
    _applyVisibility(estavaVisivel);
  }

  /// Aplica aos episódios abertos a transição de visibilidade que acabou de
  /// acontecer, se é que aconteceu alguma.
  void _applyVisibility(bool estavaVisivel) {
    final agoraVisivel = _visible;

    if (estavaVisivel == agoraVisivel) return;

    final now = _now();

    for (final episode in _open.values) {
      if (agoraVisivel) {
        episode.resume(now);
      } else {
        episode.pause(now);
      }
    }
  }

  /// O app foi para segundo plano.
  ///
  /// Diferente de [setFeedTabActive] e [setCoveredByRoute], aqui os episódios
  /// são **fechados e enviados**: o app pode nunca mais voltar, e o fim da
  /// sessão é justamente onde está a informação mais valiosa — o que fez a
  /// pessoa sair. Os mesmos itens são reabertos pausados, para que a volta
  /// retome a contagem sem depender de um callback de visibilidade que não
  /// virá.
  void onAppPaused() {
    if (_disposed) return;

    final now = _now();
    final visible = _open.values.map((episode) => episode.item).toList();

    for (final itemId in _open.keys.toList()) {
      _closeEpisode(itemId, now);
    }

    _appForeground = false;

    for (final item in visible) {
      _open[item.itemId] = _Episode(item, now)..pause(now);
    }

    unawaited(flush());
  }

  /// O app voltou.
  ///
  /// Começa uma sessão nova: o `sessionId` agrupa uma visita, e é ele que
  /// permite saber quantos posts a pessoa viu antes de sair.
  void onAppResumed() {
    if (_disposed) return;

    _sessionId = _uuid.v4();

    final estavaVisivel = _visible;

    _appForeground = true;
    _applyVisibility(estavaVisivel);
  }

  void dispose() {
    if (_disposed) return;

    final now = _now();

    for (final itemId in _open.keys.toList()) {
      _closeEpisode(itemId, now);
    }

    _disposed = true;
    _flushTimer?.cancel();
    _flushTimer = null;

    unawaited(flush());
  }

  // --------------------------------------------------------------------- envio

  /// Envia o que estiver no buffer, em lotes do tamanho aceito pela API.
  ///
  /// O lote sai do buffer **antes** da requisição: uma falha o perde, e é essa
  /// a intenção — sem reenvio, sem fila crescendo, sem duplicata.
  Future<void> flush() async {
    if (_sending || _buffer.isEmpty) return;

    _sending = true;

    try {
      while (_buffer.isNotEmpty) {
        final size =
            _buffer.length < _maxBatchSize ? _buffer.length : _maxBatchSize;
        final batch = _buffer.sublist(0, size);

        _buffer.removeRange(0, size);

        try {
          await _service.sendBatch(sessionId: _sessionId, events: batch);
        } catch (e) {
          // Rede fora: insistir com os lotes seguintes só gastaria bateria para
          // falhar igual. O que já saiu do buffer está perdido, de propósito.
          debugPrint('Telemetria descartada (${batch.length} eventos): $e');
          break;
        }
      }
    } finally {
      _sending = false;

      if (_buffer.isEmpty) {
        _flushTimer?.cancel();
        _flushTimer = null;
      }
    }
  }

  // ------------------------------------------------------------------ internos

  void _closeEpisode(String itemId, DateTime now) {
    final episode = _open.remove(itemId);

    if (episode == null) return;

    var visibleFor = episode.visibleFor(now);

    // Piscada de rolagem: o card cruzou a tela rápido demais para ter sido
    // visto. Não é impressão nem julgamento — é nada.
    if (visibleFor < _minRendered) return;

    if (visibleFor > _maxDwell) visibleFor = _maxDwell;

    _buffer.add(
      _event(
        episode.item,
        InteractionType.impression,
        episode.startedAt,
        dwellMs: visibleFor.inMilliseconds,
      ),
    );

    // A duração viaja na impressão, não aqui: o serviço soma `dwellMs` apenas
    // dos eventos de impressão, para que numerador e denominador do tempo médio
    // falem da mesma população. Repetir o valor no DWELL não somaria duas vezes
    // hoje, mas registraria uma segunda verdade sobre o mesmo fato.
    if (visibleFor >= _dwellThreshold) {
      _buffer.add(
        _event(episode.item, InteractionType.dwell, episode.startedAt),
      );
    }

    if (visibleFor < _seenThreshold) {
      _buffer.add(
        _event(episode.item, InteractionType.skip, episode.startedAt),
      );
    }

    _afterBuffer();
  }

  InteractionEvent _event(
    TrackedItem item,
    InteractionType type,
    DateTime occurredAt, {
    int? dwellMs,
  }) {
    return InteractionEvent(
      eventId: _uuid.v4(),
      type: type,
      itemId: item.itemId,
      itemType: item.itemType,
      occurredAt: occurredAt,
      authorId: item.authorId,
      position: item.position,
      dwellMs: dwellMs,
      source: item.source,
    );
  }

  void _afterBuffer() {
    if (_buffer.length > _maxBufferedEvents) {
      _buffer.removeRange(0, _buffer.length - _maxBufferedEvents);
    }

    if (_buffer.length >= _maxBatchSize) {
      unawaited(flush());
      return;
    }

    _flushTimer ??= Timer.periodic(_flushInterval, (_) => unawaited(flush()));
  }
}