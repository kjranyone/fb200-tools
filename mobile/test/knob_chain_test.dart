import 'package:fb200_nam/widgets/chain_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fb200_nam/widgets/knob.dart';

void main() {
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
    final center = tester.getCenter(find.byType(Knob));
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(20, 10));
    await gesture.moveBy(const Offset(10, 18));
    await gesture.moveBy(const Offset(-4, 20));
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
