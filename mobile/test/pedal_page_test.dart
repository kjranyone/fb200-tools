import 'package:fb200_nam/pedal_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pedal_client_test.dart' show PedalHarness;

void main() {
  testWidgets('narrow editor reads bank and gates unsupported NAM tools', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final h = PedalHarness();
    await tester.pumpWidget(
      MaterialApp(
        home: PedalPage(
          transport: h.wire,
          restrictedNam: true,
          toolsAvailable: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('0A  PRESET'), findsWidgets);
    expect(h.writes, 0);
    await tester.tap(find.text('ツール'));
    await tester.pumpAndSettle();
    expect(find.text('ドラムとチューナーは本体の更新後に利用できます。'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(find.byType(SwitchListTile).first)
          .onChanged,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(h.close);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stock editor exposes controls without requiring NAM RPC', (
    tester,
  ) async {
    final h = PedalHarness();
    await tester.pumpWidget(
      MaterialApp(
        home: PedalPage(
          transport: h.wire,
          restrictedNam: false,
          toolsAvailable: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('ツール'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SwitchListTile>(find.byType(SwitchListTile).first)
          .onChanged,
      isNotNull,
    );
    expect(find.text('ドラムとチューナーは本体の更新後に利用できます。'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(h.close);
    expect(h.writes, 0);
  });
}
