import 'package:fb200_nam/effect_parameters.dart';
import 'package:fb200_nam/pedal/nam_pre_selector.dart';
import 'package:fb200_nam/pedal_client.dart';
import 'package:fb200_nam/protocol.dart';
import 'package:fb200_nam/widgets/knob.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'studio_test.dart' show studio;
import 'support/studio_harness.dart';

void main() {
  test('the delay knob stops at the firmware limit', () {
    final preset = PedalPreset(List.filled(256, 0));
    final delay = pedalModules.firstWhere((m) => m.command == 0x85);
    int max(int? limit) => EffectParameters.forModule(
      delay,
      preset,
      delayMax: limit,
    ).firstWhere((p) => p.field == 4).max;
    expect(max(null), 2500);
    expect(max(300), 300);
  });

  testWidgets('a pre NAM is chosen into the preset tail and gets its knobs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final h = StudioHarness();
    h.addFlags(8192);
    await tester.pumpWidget(studio(h));
    await tester.pumpAndSettle();
    expect(find.text('PRE'), findsOneWidget);
    expect(find.text('なし（NAMを1段で使用）'), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) => w is Knob && w.label == 'PRE GAIN'),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('choose-nam-pre')));
    await tester.pumpAndSettle();
    // The pre picker marks its own (empty) choice, not the first NAM's.
    expect(find.text('プリ段を使わない'), findsOneWidget);
    expect(find.text('本体で選択中'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('nam-slot-2')));
    await tester.pumpAndSettle();
    expect(read16(h.edit, NamPre.mark), NamPre.marker);
    expect(read16(h.edit, NamPre.slot), 2);
    expect(read16(h.edit, NamPre.gain), 50);
    expect(read16(h.edit, NamPre.level), 50);
    // The first NAM's binding is untouched.
    expect(read16(h.edit, 0xe0), 1);
    expect(find.text('02  Bass Crunch'), findsOneWidget);
    final gain = tester.widget<Knob>(
      find.byWidgetPredicate((w) => w is Knob && w.label == 'PRE GAIN'),
    );
    expect(gain.format!(0), '-18.0 dB');
    expect(gain.value, 50);
    expect(
      find.byWidgetPredicate((w) => w is Knob && w.label == 'PRE LEVEL'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(h.close);
  });

  testWidgets('firmware without the second NAM shows no pre row', (
    tester,
  ) async {
    final h = StudioHarness();
    await tester.pumpWidget(studio(h));
    await tester.pumpAndSettle();
    expect(find.text('PRE'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(h.close);
  });
}
