import 'package:fb200_nam/widgets/chain_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fb200_nam/widgets/knob.dart';

void main() {
  testWidgets('vertical drag supports fine adjustment and cancellation', (
    tester,
  ) async {
    var result = -1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Knob(
              label: 'GAIN',
              value: 50,
              min: 0,
              max: 100,
              onChanged: (v) => result = v,
            ),
          ),
        ),
      ),
    );
    final dial = find
        .descendant(
          of: find.byType(Knob),
          matching: find.byType(RawGestureDetector),
        )
        .first;
    var gesture = await tester.startGesture(tester.getCenter(dial));
    await gesture.moveBy(
      const Offset(100, 0),
    ); // move sideways: quarter sensitivity
    await gesture.moveBy(const Offset(0, -80));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(result, 60);
    result = -1;
    gesture = await tester.startGesture(tester.getCenter(dial));
    await gesture.moveBy(const Offset(0, 80));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(result, -1);
    expect(find.text('50'), findsOneWidget);
  });

  testWidgets(
    'numeric entry rejects invalid values and restores the standard value',
    (tester) async {
      var result = -1;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Knob(
              label: 'GAIN',
              value: 75,
              min: 0,
              max: 100,
              defaultValue: 50,
              format: (v) => '$v units',
              onChanged: (v) => result = v,
            ),
          ),
        ),
      );
      await tester.tap(find.text('75 units'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '999');
      await tester.pump();
      expect(find.text('0〜100の整数を入力してください'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '適用'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('標準に戻す'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));
      expect(result, 50);
    },
  );

  testWidgets('knob drag clockwise increases and commits on release', (
    tester,
  ) async {
    var value = 50;
    var committed = -1;
    late StateSetter setOuter;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            setOuter = setState;
            return Scaffold(
              body: Center(
                child: Knob(
                  label: 'LEVEL',
                  value: value,
                  min: 0,
                  max: 100,
                  onChanged: (v) => setOuter(() {
                    value = v;
                    committed = v;
                  }),
                ),
              ),
            );
          },
        ),
      ),
    );
    final knob = tester.getCenter(
      find
          .descendant(
            of: find.byType(Knob),
            matching: find.byType(RawGestureDetector),
          )
          .first,
    );
    // Clockwise arc: start at the 9 o'clock edge and drag up along the rim.
    final gesture = await tester.startGesture(Offset(knob.dx - 20, knob.dy));
    await gesture.moveBy(const Offset(5, -20));
    await gesture.moveBy(const Offset(8, -15));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(committed, greaterThan(50));
  });

  testWidgets('knob ignores gestures when disabled', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Knob(
              label: 'LEVEL',
              value: 50,
              min: 0,
              max: 100,
              enabled: false,
              onChanged: (_) => calls++,
            ),
          ),
        ),
      ),
    );
    final center = tester.getCenter(find.byType(Knob));
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(20, 10));
    await gesture.moveBy(const Offset(10, 18));
    await gesture.up();
    await tester.pump();
    expect(calls, 0);
  });

  testWidgets('chain strip renders buffer order, NAM label and selection', (
    tester,
  ) async {
    var tapped = -1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChainStrip(
            order: const [1, 0, 2, 3, 4, 5, 6],
            enabled: const {1, 2},
            selected: 2,
            restrictedNam: true,
            namModel: 'BassGuy',
            onTap: (i) => tapped = i,
          ),
        ),
      ),
    );
    expect(find.text('GATE'), findsOneWidget);
    expect(find.text('NAM'), findsOneWidget);
    expect(find.text('BassGuy'), findsOneWidget);
    expect(find.text('REV'), findsOneWidget);
    await tester.tap(find.text('NAM'));
    await tester.pump();
    expect(tapped, 2);
    expect(find.text('COMP'), findsOneWidget);
  });
}
