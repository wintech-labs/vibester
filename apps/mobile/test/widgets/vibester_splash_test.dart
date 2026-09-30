import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/widgets/motion/vibester_splash.dart';

/// Avança o relógio quadro a quadro: a animação só conta tempo a partir do
/// quadro seguinte ao `forward()`, e um `pump` único pularia esse início.
Future<void> advance(WidgetTester tester, Duration total) async {
  const step = Duration(milliseconds: 50);
  for (var t = Duration.zero; t < total; t += step) {
    await tester.pump(step);
  }
}

void main() {
  Widget gate(Future<String> boot) => SplashGate<String>(
    boot: boot,
    builder: (data) => MaterialApp(home: Text(data)),
  );

  testWidgets('segura o app até o boot terminar e sai depois da entrada', (
    tester,
  ) async {
    final boot = Completer<String>();
    await tester.pumpWidget(gate(boot.future));

    expect(find.byType(VibesterSplash), findsOneWidget);
    expect(find.text('feed'), findsNothing);

    // A entrada acaba, mas o boot não: a abertura continua pulsando.
    await advance(tester, const Duration(milliseconds: 400));
    await advance(tester, VibesterSplash.introDuration);
    await advance(tester, const Duration(seconds: 2));
    expect(find.byType(VibesterSplash), findsOneWidget);

    // Boot pronto: o app é montado embaixo e a abertura sai.
    boot.complete('feed');
    await tester.pump();
    expect(find.text('feed'), findsOneWidget);
    await advance(tester, VibesterSplash.exitDuration);
    await tester.pump();
    expect(find.byType(VibesterSplash), findsNothing);
    expect(find.text('feed'), findsOneWidget);
  });

  testWidgets('boot rápido ainda espera a entrada terminar', (tester) async {
    await tester.pumpWidget(gate(Future.value('feed')));
    await tester.pump();
    expect(find.text('feed'), findsOneWidget);
    expect(find.byType(VibesterSplash), findsOneWidget);

    await advance(tester, const Duration(milliseconds: 400));
    await advance(tester, VibesterSplash.introDuration);
    // Margem de alguns quadros: a saída começa no quadro seguinte ao fim da
    // entrada.
    await advance(tester, VibesterSplash.exitDuration * 1.5);
    expect(find.byType(VibesterSplash), findsNothing);
  });
}
