import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/models/interaction/interaction_event_model.dart';
import 'package:mobile/service/interaction/interaction_service.dart';
import 'package:mobile/service/interaction/interaction_tracker.dart';

/// Captura os lotes em vez de enviá-los. Também sabe falhar, para provar que a
/// telemetria descarta em vez de insistir.
class _FakeInteractionService implements InteractionService {
  final List<List<InteractionEvent>> batches = [];
  final List<String> sessionIds = [];
  bool shouldFail = false;

  @override
  Future<void> sendBatch({
    required String sessionId,
    required List<InteractionEvent> events,
  }) async {
    if (shouldFail) throw Exception('rede fora');

    sessionIds.add(sessionId);
    batches.add(events);
  }
}

void main() {
  late _FakeInteractionService service;
  late InteractionTracker tracker;
  late DateTime agora;

  /// Sábado, 23h04 — o horário em que o feed do Vibester importa.
  final inicio = DateTime.utc(2026, 9, 19, 23, 4, 12);

  const item = TrackedItem(
    itemId: 'post-green-valley',
    itemType: InteractionItemType.post,
    source: InteractionSource.feed,
    position: 2,
    authorId: 'autor-green-valley',
  );

  /// Mostra o item por [duracao] e o tira da tela.
  void mostrarPor(Duration duracao, {TrackedItem alvo = item}) {
    tracker.onVisibilityChanged(alvo, 1.0);
    agora = agora.add(duracao);
    tracker.onVisibilityChanged(alvo, 0.0);
  }

  List<InteractionType> tiposNoBuffer() =>
      tracker.bufferedEvents.map((e) => e.type).toList();

  setUp(() {
    service = _FakeInteractionService();
    agora = inicio;
    tracker = InteractionTracker(service: service, clock: () => agora);
  });

  tearDown(() => tracker.dispose());

  group('régua de visibilidade', () {
    test('piscada de rolagem (<300ms) não registra nada', () {
      mostrarPor(const Duration(milliseconds: 80));

      expect(tracker.bufferedEvents, isEmpty);
    });

    test('descarte rápido (300ms–1s) vira impressão e skip', () {
      mostrarPor(const Duration(milliseconds: 300));

      expect(
        tiposNoBuffer(),
        containsAll([InteractionType.impression, InteractionType.skip]),
      );
      expect(tiposNoBuffer(), isNot(contains(InteractionType.dwell)));
    });

    test('entre 1s e 5s vira só impressão', () {
      mostrarPor(const Duration(milliseconds: 2500));

      expect(tiposNoBuffer(), [InteractionType.impression]);
    });

    test('a partir de 5s vira impressão e dwell', () {
      mostrarPor(const Duration(seconds: 16));

      expect(
        tiposNoBuffer(),
        containsAll([InteractionType.impression, InteractionType.dwell]),
      );
      expect(tiposNoBuffer(), isNot(contains(InteractionType.skip)));
    });

    test('a duração viaja só na impressão, não no dwell', () {
      mostrarPor(const Duration(seconds: 16));

      final impressao = tracker.bufferedEvents
          .firstWhere((e) => e.type == InteractionType.impression);
      final dwell = tracker.bufferedEvents
          .firstWhere((e) => e.type == InteractionType.dwell);

      expect(impressao.dwellMs, 16000);
      expect(dwell.dwellMs, isNull);
    });

    test('tremido entre as duas frações não fecha o episódio', () {
      tracker.onVisibilityChanged(item, 1.0);
      agora = agora.add(const Duration(seconds: 2));

      // Abaixo da fração de entrada, acima da de saída: ainda está na tela.
      tracker.onVisibilityChanged(item, 0.4);

      expect(tracker.bufferedEvents, isEmpty);

      agora = agora.add(const Duration(seconds: 2));
      tracker.onVisibilityChanged(item, 0.0);

      expect(tracker.bufferedEvents.single.dwellMs, 4000);
    });

    test('impressão é carimbada quando o item apareceu, não quando saiu', () {
      mostrarPor(const Duration(seconds: 6));

      // Se fosse o instante da saída, a curtida dada durante a exibição
      // precederia a impressão e o dado diria que alguém curtiu um post que
      // nunca foi mostrado.
      expect(tracker.bufferedEvents.first.occurredAt, inicio);
    });

    test('item removido da árvore ainda rende a impressão', () {
      tracker.onVisibilityChanged(item, 1.0);
      agora = agora.add(const Duration(seconds: 3));

      tracker.onItemDetached(item.itemId);

      expect(tiposNoBuffer(), [InteractionType.impression]);
    });

    test('episódio parado é cortado no teto de atenção', () {
      mostrarPor(const Duration(hours: 2));

      // Celular esquecido aberto não é atenção — e um dwell acima de 1h
      // reprovaria o lote inteiro no schema do serviço.
      expect(
        tracker.bufferedEvents.first.dwellMs,
        const Duration(minutes: 5).inMilliseconds,
      );
    });
  });

  group('superfície fora da frente do usuário', () {
    // CORREÇÃO: os testes deste grupo usavam `pauseSurface`/`resumeSurface`,
    // que viraram `setFeedTabActive` (troca de aba, dono: a Home) e
    // `setCoveredByRoute` (rota por cima, dono: o feed). O que cada teste
    // prova continua igual; só a chamada mudou para o interruptor certo.

    test('tempo em outra aba não conta como atenção', () {
      tracker.onVisibilityChanged(item, 1.0);
      agora = agora.add(const Duration(seconds: 2));

      tracker.setFeedTabActive(false);
      agora = agora.add(const Duration(minutes: 3));
      tracker.setFeedTabActive(true);

      agora = agora.add(const Duration(seconds: 2));
      tracker.onVisibilityChanged(item, 0.0);

      expect(tracker.bufferedEvents.single.dwellMs, 4000);
    });

    test('nenhum episódio começa com a superfície pausada', () {
      tracker.setFeedTabActive(false);
      mostrarPor(const Duration(seconds: 3));

      expect(tracker.bufferedEvents, isEmpty);
    });

    test('ir para segundo plano fecha e envia o que estava na tela', () async {
      tracker.onVisibilityChanged(item, 1.0);
      agora = agora.add(const Duration(seconds: 7));

      tracker.onAppPaused();
      await Future<void>.delayed(Duration.zero);

      expect(
        service.batches.single.map((e) => e.type),
        containsAll([InteractionType.impression, InteractionType.dwell]),
      );
    });

    test('voltar do segundo plano retoma sem duplicar a impressão', () async {
      tracker.onVisibilityChanged(item, 1.0);
      agora = agora.add(const Duration(seconds: 7));

      tracker.onAppPaused();
      await Future<void>.delayed(Duration.zero);

      agora = agora.add(const Duration(minutes: 10));
      tracker.onAppResumed();

      // O detector não dispara callback na volta — a fração não mudou. A
      // contagem precisa retomar mesmo assim, e sem recontar os 7s já enviados.
      agora = agora.add(const Duration(seconds: 3));
      tracker.onVisibilityChanged(item, 0.0);

      expect(tiposNoBuffer(), [InteractionType.impression]);
      expect(tracker.bufferedEvents.single.dwellMs, 3000);
    });

    test('voltar do segundo plano em outra aba não retoma a contagem', () {
      tracker.onVisibilityChanged(item, 1.0);
      agora = agora.add(const Duration(seconds: 2));

      // Sai do feed pela navbar, e só então manda o app para segundo plano.
      tracker.setFeedTabActive(false);
      tracker.onAppPaused();

      agora = agora.add(const Duration(minutes: 10));
      tracker.onAppResumed();
      agora = agora.add(const Duration(minutes: 4));

      // O usuário voltou para a aba de busca, não para o feed: nada do que
      // ficou congelado atrás dela pode contar como atenção.
      tracker.setFeedTabActive(true);
      agora = agora.add(const Duration(seconds: 3));
      tracker.onVisibilityChanged(item, 0.0);

      expect(tracker.bufferedEvents.single.dwellMs, 3000);
    });

    // CORREÇÃO: os três testes abaixo cobrem os dois interruptores juntos —
    // exatamente onde o booleano único errava.

    test('tela aberta por cima do feed pausa, e fechá-la retoma', () {
      tracker.onVisibilityChanged(item, 1.0);
      agora = agora.add(const Duration(seconds: 2));

      // Perfil do autor aberto a partir do próprio feed.
      tracker.setCoveredByRoute(true);
      agora = agora.add(const Duration(minutes: 1));
      tracker.setCoveredByRoute(false);

      agora = agora.add(const Duration(seconds: 2));
      tracker.onVisibilityChanged(item, 0.0);

      expect(tracker.bufferedEvents.single.dwellMs, 4000);
    });

    test('fechar uma tela aberta a partir de outra aba não religa o feed', () {
      tracker.onVisibilityChanged(item, 1.0);
      agora = agora.add(const Duration(seconds: 2));

      // Sai do feed pela navbar e, em HOJE, abre um evento. A rota do feed é a
      // mesma da casca, então o feed também recebe o aviso de "coberto".
      tracker.setFeedTabActive(false);
      tracker.setCoveredByRoute(true);
      agora = agora.add(const Duration(minutes: 1));

      // Fecha o evento, mas continua em HOJE. Com o booleano único, este
      // passo religava a medição e os 3 minutos seguintes contavam como
      // atenção num post que ninguém estava vendo.
      tracker.setCoveredByRoute(false);
      agora = agora.add(const Duration(minutes: 3));

      // Só agora volta ao feed.
      tracker.setFeedTabActive(true);
      agora = agora.add(const Duration(seconds: 2));
      tracker.onVisibilityChanged(item, 0.0);

      expect(tracker.bufferedEvents.single.dwellMs, 4000);
    });

    test('voltar à aba do feed com uma tela ainda por cima não retoma', () {
      tracker.onVisibilityChanged(item, 1.0);
      agora = agora.add(const Duration(seconds: 2));

      // Cada interruptor só libera o seu motivo: a aba voltar a ser o feed não
      // passa por cima de uma rota que ainda está cobrindo a tela.
      tracker.setFeedTabActive(false);
      tracker.setCoveredByRoute(true);
      tracker.setFeedTabActive(true);
      agora = agora.add(const Duration(minutes: 2));

      tracker.setCoveredByRoute(false);
      agora = agora.add(const Duration(seconds: 2));
      tracker.onVisibilityChanged(item, 0.0);

      expect(tracker.bufferedEvents.single.dwellMs, 4000);
    });

    test('voltar do segundo plano começa uma sessão nova', () {
      final anterior = tracker.sessionId;

      tracker.onAppPaused();
      tracker.onAppResumed();

      expect(tracker.sessionId, isNot(anterior));
    });
  });

  group('envio em lote', () {
    test('nenhum lote passa do teto aceito pela API', () async {
      for (var i = 0; i < 120; i++) {
        tracker.recordTap(item, InteractionType.profileOpen);
      }

      await tracker.flush();
      await Future<void>.delayed(Duration.zero);
      await tracker.flush();

      expect(service.batches, isNotEmpty);
      expect(service.batches.every((lote) => lote.length <= 50), isTrue);
      expect(
        service.batches.fold<int>(0, (total, lote) => total + lote.length),
        120,
      );
    });

    test('falha de envio descarta o lote em vez de reenfileirar', () async {
      service.shouldFail = true;
      mostrarPor(const Duration(seconds: 3));

      await tracker.flush();

      expect(tracker.bufferedEvents, isEmpty);

      // Uma segunda tentativa não tem o que reenviar: o dado foi perdido de
      // propósito, para a telemetria nunca crescer fila nem travar o app.
      service.shouldFail = false;
      await tracker.flush();

      expect(service.batches, isEmpty);
    });

    test('todo evento do lote carrega posição e autor', () async {
      mostrarPor(const Duration(seconds: 3));
      await tracker.flush();

      final enviado = service.batches.single.single;

      expect(enviado.position, 2);
      expect(enviado.authorId, 'autor-green-valley');
      expect(enviado.toJson()['source'], 'FEED');
      expect(enviado.toJson()['itemType'], 'POST');
    });
  });
}