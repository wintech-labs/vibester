import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/models/notification/notification_model.dart';
import 'package:mobile/widgets/cards/notification/notification_card.dart';
import 'package:mobile/widgets/common/vibester_image.dart';

import '../helpers/pump_app.dart';

NotificationModel _notificacao({
  required String tipo,
  String conteudo = '',
  int outrosCount = 0,
  String? atorNome,
  String? postImagemUrl,
  bool postApagado = false,
}) {
  return NotificationModel(
    id: 'n-1',
    tipo: tipo,
    referenciaId: 'post-1',
    outrosCount: outrosCount,
    totalCount: outrosCount + 1,
    conteudo: conteudo,
    lida: false,
    criadoEm: DateTime.now().subtract(const Duration(minutes: 5)),
    atorNome: atorNome,
    postImagemUrl: postImagemUrl,
    postApagado: postApagado,
  );
}

Finder _miniatura(String url) => find.byWidgetPredicate(
  (widget) => widget is VibesterImage && widget.source == url,
);

Finder _texto(String trecho) => find.textContaining(trecho, findRichText: true);

void main() {
  setUpAll(setUpTestEnvironment);

  group('NotificationCard — aviso de post reprovado', () {
    const motivo =
        'Sua publicação não segue as diretrizes da comunidade: há links demais '
        'na publicação. Você pode excluí-la pelo menu da publicação.';

    /// Antes desta correção o `switch` não conhecia `post_rejected`: a linha
    /// saía "Alguém" e nada mais, sem o motivo.
    testWidgets('mostra o Vibester como autor e o motivo completo', (tester) async {
      await pumpComponent(
        tester,
        NotificationCard(
          notification: _notificacao(tipo: 'post_rejected', conteudo: motivo),
        ),
      );

      expect(_texto('Vibester'), findsOneWidget);
      expect(_texto('há links demais na publicação'), findsOneWidget);
      expect(_texto('Alguém'), findsNothing);
    });

    testWidgets('nao mostra "e mais N" para aviso duplicado', (tester) async {
      await pumpComponent(
        tester,
        NotificationCard(
          notification: _notificacao(
            tipo: 'post_rejected',
            conteudo: motivo,
            outrosCount: 1,
          ),
        ),
      );

      expect(_texto('e mais'), findsNothing);
    });

    testWidgets('usa texto padrao quando o servidor manda conteudo vazio', (tester) async {
      await pumpComponent(
        tester,
        NotificationCard(notification: _notificacao(tipo: 'post_rejected')),
      );

      expect(_texto('diretrizes da comunidade'), findsOneWidget);
    });

    /// O motivo pode ser longo (vários motivos juntos). Na tela pequena, um
    /// estouro de layout reprova o teste — é o que `pumpComponent` verifica.
    for (final entrada in TestScreens.all.entries) {
      testWidgets('nao estoura o layout com motivo longo na tela ${entrada.key}', (
        tester,
      ) async {
        await pumpComponent(
          tester,
          NotificationCard(
            notification: _notificacao(
              tipo: 'post_rejected',
              conteudo: '$motivo $motivo',
            ),
          ),
          size: entrada.value,
        );

        expect(tester.takeException(), isNull);
      });
    }
  });

  group('NotificationCard — tipos existentes continuam iguais', () {
    testWidgets('curtida mostra o ator e a acao', (tester) async {
      await pumpComponent(
        tester,
        NotificationCard(notification: _notificacao(tipo: 'like', atorNome: 'Ana')),
      );

      expect(_texto('Ana'), findsOneWidget);
      expect(_texto('curtiu sua publicação'), findsOneWidget);
    });

    testWidgets('curtida agrupada ainda mostra "e mais N"', (tester) async {
      await pumpComponent(
        tester,
        NotificationCard(
          notification: _notificacao(tipo: 'like', atorNome: 'Ana', outrosCount: 2),
        ),
      );

      expect(_texto('e mais 2'), findsOneWidget);
    });
  });

  group('NotificationCard — miniatura de post apagado', () {
    const foto = 'https://media.test/posts/autor/foto.jpg';

    testWidgets('mostra a miniatura do post reprovado que continua no ar', (tester) async {
      await pumpComponent(
        tester,
        NotificationCard(
          notification: _notificacao(
            tipo: 'post_rejected',
            conteudo: 'aviso',
            postImagemUrl: foto,
          ),
        ),
      );

      expect(_miniatura(foto), findsOneWidget);
    });

    /// Quando quem apagou foi a moderação de imagem, a foto é o que foi
    /// removido — ela não pode voltar dentro da própria notificação.
    testWidgets('nunca mostra a miniatura de post apagado', (tester) async {
      await pumpComponent(
        tester,
        NotificationCard(
          notification: _notificacao(
            tipo: 'post_rejected',
            conteudo: 'Sua publicação foi removida.',
            postImagemUrl: foto,
            postApagado: true,
          ),
        ),
      );

      expect(_miniatura(foto), findsNothing);
    });

    testWidgets('vale tambem para curtida antiga de post apagado', (tester) async {
      await pumpComponent(
        tester,
        NotificationCard(
          notification: _notificacao(
            tipo: 'like',
            atorNome: 'Ana',
            postImagemUrl: foto,
            postApagado: true,
          ),
        ),
      );

      expect(_miniatura(foto), findsNothing);
    });
  });
}
