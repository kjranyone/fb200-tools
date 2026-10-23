import 'dart:typed_data';

import 'package:fb200_nam/fx_block.dart';
import 'package:fb200_nam/pedal_client.dart';
import 'package:fb200_nam/protocol.dart';
import 'package:fb200_nam/widgets/chain_strip.dart';
import 'package:fb200_nam/widgets/knob.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'studio_test.dart' show studio;
import 'support/studio_harness.dart';

void main() {
  final pitch = FxMode.parse(Uint8List.fromList(StudioHarness.pitchDescriptor));

  test('a mode descriptor parses into its controls', () {
    expect(pitch.number, 1);
    expect(pitch.name, 'PITCH');
    expect(pitch.heavy, isFalse);
    expect(
      [for (final p in pitch.params) p.name],
      ['SHIFT', 'MIX', 'LEVEL', 'GLIDE', 'RANGE'],
    );
    final shift = pitch.params[0], range = pitch.params[4];
    expect((shift.min, shift.max, shift.def, shift.step), (0, 4800, 3600, 100));
    expect(shift.format(3600), '+12 半音');
    expect(shift.format(1200), '−12 半音');
    expect(shift.format(2400), '±0 半音');
    expect(shift.format(2450), '+0.50 半音');
    expect(pitch.params[1].format(30), '30%');
    expect(pitch.params[2].format(0), '-18.0 dB');
    expect(pitch.params[3].format(120), '120 ms');
    expect(range.unit, FxUnit.choice);
    expect(range.labels, ['Guitar', 'Bass']);
    expect(range.format(0), 'Guitar');
  });

  test('a descriptor of the wrong length is refused', () {
    final short = StudioHarness.pitchDescriptor.sublist(0, 60);
    expect(
      () => FxMode.parse(Uint8List.fromList(short)),
      throwsA(isA<DeviceError>()),
    );
  });

  test('an unset block writes every word, a set one only the change', () {
    var preset = PedalPreset(List.filled(256, 0));
    final unset = FxBlock.of(preset);
    expect(unset.configured, isFalse);
    expect(unset.valuesFor(pitch), [3600, 50, 50, 0, 1]);
    final words = unset.change(pitch, on: true);
    expect(words[FxWords.mark], FxWords.marker);
    expect(words[FxWords.mode], 1);
    expect(words[FxWords.flags], FxWords.on);
    expect(words[FxWords.param(0)], 3600);
    expect(words[FxWords.param(4)], 1);
    expect(words[FxWords.param(5)], 0);
    expect(words.length, 11);
    for (final MapEntry(:key, :value) in words.entries) {
      preset = preset.setWord(key, value);
    }
    final set = FxBlock.of(preset);
    expect((set.configured, set.on, set.post), (true, true, false));
    expect(set.change(pitch, post: true), {
      FxWords.flags: FxWords.on | FxWords.post,
    });
    expect(set.change(pitch, param: (0, 1200)), {FxWords.param(0): 1200});
  });

  testWidgets('the FX block sits in the chain and is set live', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final h = StudioHarness();
    h.addFlags(8192 | 16384);
    await tester.pumpWidget(studio(h));
    await tester.pumpAndSettle();
    List<int> order() =>
        tester.widget<ChainStrip>(find.byType(ChainStrip)).order;
    // before the NAMs while unset, and off
    expect(order(), [1, 0, 7, 2, 3, 4, 5, 6]);
    expect(
      tester.widget<ChainStrip>(find.byType(ChainStrip)).enabled,
      isNot(contains(7)),
    );

    await tester.tap(find.text('FX'));
    await tester.pumpAndSettle();
    expect(find.text('PITCH'), findsOneWidget);
    final shift = find.byWidgetPredicate(
      (w) => w is Knob && w.label == 'SHIFT',
    );
    expect(tester.widget<Knob>(shift).value, 3600);

    // switching on configures the whole block with one edit-buffer write
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(read16(h.edit, FxWords.mark), FxWords.marker);
    expect(read16(h.edit, FxWords.mode), 1);
    expect(read16(h.edit, FxWords.flags), FxWords.on);
    expect(read16(h.edit, FxWords.param(0)), 3600);
    expect(h.tailWrites, isEmpty);
    expect(
      tester.widget<ChainStrip>(find.byType(ChainStrip)).enabled,
      contains(7),
    );

    // then single words go out live (op 15)
    await tester.tap(find.text('キャビの後'));
    await tester.pumpAndSettle();
    expect(h.tailWrites, [
      [FxWords.flags, FxWords.on | FxWords.post],
    ]);
    expect(order(), [1, 0, 2, 3, 7, 4, 5, 6]);
    tester.widget<Knob>(shift).onChanged(1200);
    await tester.pumpAndSettle();
    expect(h.tailWrites.last, [FxWords.param(0), 1200]);
    expect(tester.widget<Knob>(shift).value, 1200);
    // nothing reaches the stored preset
    expect(read16(h.pedal.presets[0], FxWords.mark), 0);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(h.close);
  });

  testWidgets('firmware without the FX block shows no FX in the chain', (
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
    expect(
      tester.widget<ChainStrip>(find.byType(ChainStrip)).order,
      isNot(contains(7)),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(h.close);
  });
}
