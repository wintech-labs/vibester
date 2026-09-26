import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/models/feed/publication_model.dart';
import 'package:mobile/routes/app_routes.dart';
import 'package:mobile/theme/app_spacing.dart';
import 'package:mobile/widgets/cards/feed/publication_card.dart';
import 'package:mobile/widgets/motion/double_tap_like.dart';

import '../helpers/pump_app.dart';

/// O ⋯ do cartão do feed é ancorado na borda direita, e é fácil quebrar isso
/// sem perceber: um `Spacer` ao lado de um filho `Flexible` divide o espaço
/// livre entre os dois, e o botão passa a andar junto com o tamanho do @.
void main() {
  setUpAll(setUpTestEnvironment);

  PublicationModel deOutraPessoa(String autor) => PublicationModel(
    id: 'post-1',
    authorId: 'outra-conta',
    autor: autor,
    autorProfileImage: '',
    publicationImage: '',
    description: 'Ontem foi bom demais.',
    publicatedAt: DateTime(2026, 9, 1),
    likes: 4,
  );

  Future<double> bordaDireitaDoMenu(
    WidgetTester tester,
    String autor, {
    Size size = TestScreens.medium,
  }) async {
    await pumpScreen(
      tester,
      Scaffold(body: PublicationCard(publication: deOutraPessoa(autor))),
      user: fakeUser(),
      size: size,
    );

    final menu = find.byIcon(Icons.more_horiz_rounded);
    expect(menu, findsOneWidget, reason: 'post de outra pessoa mostra o ⋯');
    return tester.getTopRight(menu).dx;
  }

  for (final entry in TestScreens.all.entries) {
    testWidgets('⋯ fica na mesma borda com @ curto e longo em ${entry.key}', (
      tester,
    ) async {
      final comCurto = await bordaDireitaDoMenu(
        tester,
        'ana',
        size: entry.value,
      );
      final comLongo = await bordaDireitaDoMenu(
        tester,
        'mariana_fernandes_de_oliveira_2026',
        size: entry.value,
      );

      expect(
        comCurto,
        comLongo,
        reason: 'o ⋯ não pode andar com o tamanho do nome',
      );

      // E está de fato encostado na direita: o que sobra é a margem da tela
      // mais o respiro do próprio alvo de toque, nunca metade da linha.
      final folga = entry.value.width - comCurto;
      expect(folga, lessThan(AppSpacing.screen + 16));
    });
  }

  testWidgets('post do próprio usuário mantém o ⋯ na borda', (tester) async {
    await pumpScreen(
      tester,
      Scaffold(
        body: PublicationCard(
          publication: PublicationModel(
            id: 'post-2',
            authorId: 'account-1',
            autor: 'ana',
            autorProfileImage: '',
            publicationImage: '',
            description: '',
            publicatedAt: DateTime(2026, 9, 1),
          ),
        ),
      ),
      user: fakeUser(),
    );

    final menu = find.byIcon(Icons.more_horiz_rounded);
    expect(menu, findsOneWidget);
    final folga = TestScreens.medium.width - tester.getTopRight(menu).dx;
    expect(folga, lessThan(AppSpacing.screen + 16));
  });

  // LOCAL: o lugar marcado saiu de cima da foto e foi para baixo da linha de
  // autoria (avatar + @).
  group('local marcado', () {
    PublicationModel comLocal(String local, {String? establishmentId}) =>
        PublicationModel(
          id: 'post-3',
          authorId: 'outra-conta',
          autor: 'ana',
          autorProfileImage: '',
          publicationImage: '',
          description: '',
          location: local,
          establishmentId: establishmentId,
          publicatedAt: DateTime(2026, 9, 1),
        );

    testWidgets('fica abaixo do autor e acima da foto, fora dela', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        Scaffold(body: PublicationCard(publication: comLocal('Bar do Zé'))),
        user: fakeUser(),
      );

      final local = find.text('BAR DO ZÉ');
      expect(local, findsOneWidget);

      // Não é mais desenhado dentro da mídia.
      expect(
        find.descendant(of: find.byType(DoubleTapLike), matching: local),
        findsNothing,
      );

      // Abaixo do avatar...
      final avatar = find.byType(ClipOval).first;
      expect(
        tester.getTopLeft(local).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(avatar).dy),
      );

      // ...e acima da foto.
      final foto = find.byType(DoubleTapLike);
      expect(
        tester.getBottomLeft(local).dy,
        lessThan(tester.getTopLeft(foto).dy),
      );
    });

    testWidgets('nome comprido corta em vez de estourar a tela pequena', (
      tester,
    ) async {
      // O `pumpScreen` reprova o teste se houver estouro de layout.
      await pumpScreen(
        tester,
        Scaffold(
          body: PublicationCard(
            publication: comLocal(
              'Espaço Cultural e Gastronômico Recanto das Palmeiras de '
              'Maringá e Região Metropolitana',
            ),
          ),
        ),
        user: fakeUser(),
        size: TestScreens.small,
      );

      expect(find.byIcon(Icons.place_outlined), findsOneWidget);
    });

    // LOCAL CLICÁVEL
    testWidgets('tocar no local abre a página do estabelecimento', (
      tester,
    ) async {
      RouteSettings? aberta;

      await pumpScreen(
        tester,
        Scaffold(
          body: PublicationCard(
            publication: comLocal('Bar do Zé', establishmentId: 'est-9'),
          ),
        ),
        user: fakeUser(),
        onGenerateRoute: (settings) {
          aberta = settings;
          return MaterialPageRoute(builder: (_) => const SizedBox.shrink());
        },
      );

      await tester.tap(find.text('BAR DO ZÉ'));
      await tester.pump();

      expect(aberta?.name, AppRoutes.placeDetail);
      expect(aberta?.arguments, 'est-9');
    });

    testWidgets('sem o id do estabelecimento, o local não navega', (
      tester,
    ) async {
      RouteSettings? aberta;

      await pumpScreen(
        tester,
        Scaffold(body: PublicationCard(publication: comLocal('Bar do Zé'))),
        user: fakeUser(),
        onGenerateRoute: (settings) {
          aberta = settings;
          return MaterialPageRoute(builder: (_) => const SizedBox.shrink());
        },
      );

      await tester.tap(find.text('BAR DO ZÉ'), warnIfMissed: false);
      await tester.pump();

      expect(aberta, isNull);
    });

    testWidgets('sem local, a linha não aparece', (tester) async {
      await pumpScreen(
        tester,
        Scaffold(body: PublicationCard(publication: deOutraPessoa('ana'))),
        user: fakeUser(),
      );

      expect(find.byIcon(Icons.place_outlined), findsNothing);
    });
  });
}