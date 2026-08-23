import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motari/screens/splash_screen.dart';

/// The opening animation has one job beyond looking right: it must end, and it
/// must say so. A splash that never calls back is an app that never starts.
void main() {
  testWidgets('the ride ends and hands over', (tester) async {
    var done = false;
    await tester.pumpWidget(MaterialApp(
      home: SplashScreen(onDone: () => done = true),
    ));

    // Part way through it is still riding.
    await tester.pump(const Duration(milliseconds: 800));
    expect(done, isFalse);

    // And by the end it has handed over exactly once.
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(done, isTrue);
  });

  testWidgets('it paints without overflowing on a small phone', (tester) async {
    tester.view.physicalSize = const Size(320 * 3, 480 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: SplashScreen(onDone: () {}),
    ));
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  });
}
