import 'package:fb200_nam/main.dart';
import 'package:fb200_nam/nam_client.dart';
import 'package:fb200_nam/nam_tone.dart';
import 'package:fb200_nam/pedal_page.dart';
import 'package:fb200_nam/protocol.dart';
import 'package:fb200_nam/studio_theme.dart';
import 'package:fb200_nam/widgets/knob.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/studio_harness.dart';

Widget studio(StudioHarness h, {Future<void> Function()? openModels}) =>
    MaterialApp(
      theme: StudioTheme.theme,
      home: PedalPage(
        transport: h.pedal.wire,
        restrictedNam: true,
        toolsAvailable: true,
        effectsAvailable: true,
        btAudioAvailable: true,
        namClient: h.client,
        onOpenModels: openModels,
        // The page must refresh this initial stale name from the device.
        namModel: 'Stale model',
      ),
    );

void main() {
  test('NAM display units follow the firmware mapping', () {
    expect(NamTone.format(2, 0), '0.50×');
    expect(NamTone.format(2, 50), '1.00×');
    expect(NamTone.format(2, 100), '2.00×');
    expect(NamTone.format(3, 0), '-12.0 dB');
    expect(NamTone.format(4, 50), '+0.0 dB');
    expect(NamTone.format(6, 100), '+12.0 dB');
    expect(NamTone.format(5, 0), '200 Hz');
    expect(NamTone.format(5, 100), '2000 Hz');
    expect(NamTone.format(7, 50), '1.00×');
    expect(NamTone.format(7, 100), '2.00×');
  });

  testWidgets(
    'audition, tone edit and explicit save preserve the NAM binding',
    (tester) async {
      final h = StudioHarness();
      await tester.pumpWidget(studio(h));
      await tester.pumpAndSettle();
      expect(find.text('NAM A2 LITE'), findsOneWidget);
      expect(find.byType(Knob), findsNWidgets(6));
      expect(find.text('Stale model'), findsNothing);
      expect(find.textContaining('Studio Clean'), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const ValueKey('choose-nam-model')),
      );
      await tester.tap(find.byKey(const ValueKey('choose-nam-model')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nam-slot-2')));
      await tester.pumpAndSettle();
      expect(h.selections, [
        [2, 0],
      ]); // audition never writes flash
      expect(h.pedal.writes, 0);
      expect(find.textContaining('Bass Crunch'), findsOneWidget);
      expect(find.textContaining('EDITED'), findsOneWidget);

      final gain = find.byWidgetPredicate(
        (w) => w is Knob && w.label == 'GAIN',
      );
      final number = find.descendant(of: gain, matching: find.text('1.00×'));
      await tester.ensureVisible(number);
      await tester.tap(number);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '75');
      await tester.tap(find.text('適用'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));
      expect(read16(h.edit, 0x30), 75);
      expect(h.pedal.writes, 0);

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存する'));
      await tester.pumpAndSettle();
      expect(h.pedal.writes, 1);
      expect(read16(h.pedal.presets[0], 0xe0), 2);
      expect(read16(h.pedal.presets[0], 0x30), 75);
      expect(find.textContaining('EDITED'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(h.close);
    },
  );

  testWidgets(
    'bypass, preset notifications and library return refresh the model',
    (tester) async {
      final h = StudioHarness();
      await tester.pumpWidget(
        studio(
          h,
          openModels: () async {
            h.names[2] = 'RenamedBass';
          },
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('choose-nam-model')),
      );
      await tester.tap(find.byKey(const ValueKey('choose-nam-model')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nam-slot-0')));
      await tester.pumpAndSettle();
      expect(h.selections, [
        [0, 0],
      ]);
      expect(h.selected, 0);
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
      h.selectPreset(1); // front-panel change: update model as well as preset
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.textContaining('Bass Crunch'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('open-nam-library')),
      );
      await tester.tap(find.byKey(const ValueKey('open-nam-library')));
      await tester.pumpAndSettle();
      expect(find.textContaining('RenamedBass'), findsOneWidget);
      expect(h.pedal.writes, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(h.close);
    },
  );

  testWidgets(
    'older firmware exposes drive/level but disables unimplemented tone EQ',
    (tester) async {
      final h = StudioHarness();
      h.client.capabilityFlags &= ~512;
      await tester.pumpWidget(studio(h));
      await tester.pumpAndSettle();
      final knobs = tester.widgetList<Knob>(find.byType(Knob)).toList();
      expect(knobs.where((k) => k.enabled).map((k) => k.label), [
        'GAIN',
        'VOLUME',
      ]);
      expect(find.text('このファームウェアではGAIN / VOLUMEのみ対応'), findsOneWidget);
      expect(h.pedal.writes, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(h.close);
    },
  );

  testWidgets(
    'a rejected model selection retains the current model and is visible',
    (tester) async {
      final h = StudioHarness()..failSelection = true;
      await tester.pumpWidget(studio(h));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('choose-nam-model')),
      );
      await tester.tap(find.byKey(const ValueKey('choose-nam-model')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nam-slot-2')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Studio Clean'), findsOneWidget);
      expect(find.textContaining('本体の保存・読み込みに失敗しました'), findsOneWidget);
      expect(h.selected, 1);
      expect(h.pedal.writes, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(h.close);
    },
  );

  for (final initial in [0, 3]) {
    testWidgets('controller can select a model from initial slot $initial', (
      tester,
    ) async {
      final h = StudioHarness()..selected = initial;
      await tester.pumpWidget(studio(h));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (initial == 3) {
        expect(find.textContaining('選択したスロットは空です'), findsOneWidget);
      }
      await tester.ensureVisible(
        find.byKey(const ValueKey('choose-nam-model')),
      );
      await tester.tap(find.byKey(const ValueKey('choose-nam-model')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nam-slot-2')));
      await tester.pumpAndSettle();
      expect(h.selected, 2);
      expect(h.selections, [
        [2, 0],
      ]);
      expect(h.pedal.writes, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(h.close);
    });
  }

  testWidgets('empty model store explains transfer and still offers bypass', (
    tester,
  ) async {
    final h = StudioHarness()
      ..selected = 0
      ..names.clear();
    await tester.pumpWidget(studio(h));
    await tester.pumpAndSettle();
    expect(find.textContaining('保存済みモデルなし'), findsOneWidget);
    expect(find.text('00  BYPASS'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(h.pedal.writes, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(h.close);
  });

  testWidgets('panel model notification updates the open controller', (
    tester,
  ) async {
    final h = StudioHarness();
    await tester.pumpWidget(studio(h));
    await tester.pumpAndSettle();
    // AMP knob changes the NAM binding without changing the preset index.
    h.selected = 2;
    h.edit[0xe0] = 2;
    h.pedal.link.incoming.add(frame(0x98, [0]));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(find.textContaining('Bass Crunch'), findsOneWidget);
    expect(h.selections, isEmpty);
    expect(h.pedal.writes, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(h.close);
  });

  testWidgets(
    'leaving a borrowed model library keeps the controller connection alive',
    (tester) async {
      final transport = DemoTransport();
      final client = NamClient(transport);
      await tester.runAsync(client.handshake);
      final state = await tester.runAsync(client.readState);
      await tester.pumpWidget(
        MaterialApp(
          theme: StudioTheme.theme,
          home: ModelPage(sharedClient: client, initialState: state),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('NAM LIBRARY'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(transport.closed, isFalse);
      expect(await tester.runAsync(client.readState), isNotNull);
      await tester.runAsync(client.close);
    },
  );

  for (final size in [
    const Size(360, 640),
    const Size(844, 390),
    const Size(1280, 800),
  ]) {
    testWidgets('NAM stage remains usable at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = StudioHarness();
      await tester.pumpWidget(studio(h));
      await tester.pumpAndSettle();
      expect(find.byType(Knob), findsNWidgets(6));
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('VOLUME'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(h.close);
    });
  }
}
