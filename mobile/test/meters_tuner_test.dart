import 'dart:typed_data';

import 'package:fb200_nam/nam_tone.dart';
import 'package:fb200_nam/pedal/input_gain.dart';
import 'package:fb200_nam/pedal/level_meter.dart';
import 'package:fb200_nam/pedal/tuner_tab.dart';
import 'package:fb200_nam/widgets/knob.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'studio_test.dart' show studio;
import 'support/studio_harness.dart';

List<int> tunerBytes(
  int note,
  int octave,
  double hz,
  double cents, {
  int valid = 1,
}) {
  final d = ByteData(16)
    ..setUint8(0, 1)
    ..setUint8(1, valid)
    ..setUint8(2, note)
    ..setInt8(3, octave)
    ..setFloat32(4, hz, Endian.little)
    ..setFloat32(8, cents, Endian.little)
    ..setFloat32(12, .9, Endian.little);
  return d.buffer.asUint8List();
}

Uint8List peakBytes(List<double> peaks) {
  final d = ByteData(12);
  for (var i = 0; i < 3; i++) {
    d.setFloat32(i * 4, peaks[i], Endian.little);
  }
  return d.buffer.asUint8List();
}

/// One controller poll (200 ms) and its reply.
Future<void> poll(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  test('input gain shows the stock dB steps', () {
    expect(InputGain.format(0), 'MUTE');
    expect(InputGain.format(1), '-55 dB');
    expect(InputGain.format(10), '-10 dB');
    expect(InputGain.format(12), '0 dB');
    expect(InputGain.format(13), '0 dB');
    expect(InputGain.format(14), '+0.5 dB');
    expect(InputGain.format(25), '+6 dB');
  });

  test('NAM GAIN shows dB only on firmware with the wide range', () {
    expect(NamTone.format(2, 0, wideGain: true), '-18.0 dB');
    expect(NamTone.format(2, 50, wideGain: true), '+0.0 dB');
    expect(NamTone.format(2, 100, wideGain: true), '+18.0 dB');
    expect(NamTone.format(2, 0), '0.50×');
  });

  test('level replies parse three finite peaks', () {
    expect(LevelMeters.parse(peakBytes([.5, .25, 1])), [.5, .25, 1]);
    expect(LevelMeters.parse(Uint8List(8)), isNull);
    expect(LevelMeters.parse(peakBytes([double.nan, 0, 0])), isNull);
  });

  test('meters rise at once, fall steadily, hold the peak and flag clips', () {
    final m = LevelMeters();
    final t0 = DateTime(2026);
    expect(m.update([.5, 0, .96], t0), isTrue);
    expect(m.level[LevelTap.input.index], closeTo(-6.02, .01));
    expect(m.level[LevelTap.nam.index], LevelMeters.floorDb);
    expect(m.clipped(LevelTap.output, t0), isTrue);
    expect(m.clipped(LevelTap.input, t0), isFalse);
    // Half a second later a quiet reading has fallen 12 dB; the peak holds.
    final t1 = t0.add(const Duration(milliseconds: 500));
    m.update([.05, 0, 0], t1);
    expect(m.level[LevelTap.input.index], closeTo(-18.02, .01));
    expect(m.peak[LevelTap.input.index], closeTo(-6.02, .01));
    expect(
      m.clipped(LevelTap.output, t0.add(const Duration(seconds: 3))),
      isFalse,
    );
    // A steady signal needs no redraw.
    final steady = LevelMeters()..update([.5, 0, 0], t0);
    expect(steady.update([.5, 0, 0], t1), isFalse);
  });

  test('tuner snapshots parse, smooth a held note and reset on a new one', () {
    final a = TunerReading.parse(
      Uint8List.fromList(tunerBytes(12, 4, 440, -2)),
    );
    expect(a?.name, 'A');
    expect(a?.octave, 4);
    expect(a?.text, 'A  440.0 Hz  -2.0 cent');
    expect(
      TunerReading.parse(
        Uint8List.fromList(tunerBytes(12, 4, 440, -2, valid: 0)),
      ),
      isNull,
    );
    const held = TunerReading(12, 4, 440, 10);
    expect(const TunerReading(12, 4, 440, 0).smoothed(held).cents, 5);
    expect(const TunerReading(1, 4, 466, 0).smoothed(held).cents, 0);
  });

  testWidgets('wide sidebar meters input, NAM and output on one line', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final h = StudioHarness()..levels = [.5, .25, .97];
    h.client.capabilityFlags |= 1024 | 2048;
    await tester.pumpWidget(studio(h));
    await tester.pumpAndSettle();
    await poll(tester);
    expect(h.levelReads, greaterThan(0));
    expect(find.text('IN'), findsOneWidget);
    expect(find.byTooltip('ギター入力（入力ゲイン前）: -6.0 dBFS'), findsOneWidget);
    expect(
      find.byTooltip('NAMモデルへの入力（入力ゲイン・GAIN後）: -12.0 dBFS'),
      findsOneWidget,
    );
    expect(find.byTooltip('本体の出力: -0.3 dBFS'), findsOneWidget);
    // The three meters share one row.
    expect(
      tester.getCenter(find.text('IN')).dy,
      tester.getCenter(find.text('OUT')).dy,
    );
    expect(find.text('プリセットを管理'), findsNothing);
    expect(find.text('NAMライブラリ'), findsNothing);
    // The NAM GAIN knob follows the firmware's -18..+18 dB range.
    final gain = tester.widget<Knob>(
      find.byWidgetPredicate((w) => w is Knob && w.label == 'GAIN'),
    );
    expect(gain.format!(0), '-18.0 dB');
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(h.close);
  });

  testWidgets('older NAM firmware explains the missing meters', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final h = StudioHarness()..levels = [.5, .25, .97];
    await tester.pumpWidget(studio(h));
    await tester.pumpAndSettle();
    await poll(tester);
    expect(h.levelReads, 0);
    expect(find.text('本体のファームウェアを更新すると、レベルメーターを表示できます。'), findsOneWidget);
    final gain = tester.widget<Knob>(
      find.byWidgetPredicate((w) => w is Knob && w.label == 'GAIN'),
    );
    expect(gain.format!(0), '0.50×');
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(h.close);
  });

  testWidgets('tuner tab shows the note on a needle and the reading', (
    tester,
  ) async {
    final h = StudioHarness()..tuner = tunerBytes(12, 4, 440, -2);
    h.settings[8] = 1;
    await tester.pumpWidget(studio(h));
    await tester.pumpAndSettle();
    await tester.tap(find.text('チューナー'));
    await tester.pumpAndSettle();
    await poll(tester);
    expect(find.byType(TunerIndicator), findsOneWidget);
    expect(find.text('A  440.0 Hz  -2.0 cent'), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(h.close);
  });
}
