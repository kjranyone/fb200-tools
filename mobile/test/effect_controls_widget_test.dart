import 'dart:async';

import 'package:fb200_nam/connection_recovery.dart';

import 'package:fb200_nam/pedal_client.dart';
import 'package:fb200_nam/protocol.dart';
import 'package:fb200_nam/widgets/chain_strip.dart';
import 'package:fb200_nam/widgets/effect_choice.dart';
import 'package:fb200_nam/widgets/knob.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'studio_test.dart' show studio;
import 'support/studio_harness.dart';

void large(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> selectModule(WidgetTester tester, int module) async {
  final chain = tester.widget<ChainStrip>(find.byType(ChainStrip));
  chain.onTap(chain.order.indexOf(module));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'a lost live preview keeps the draft and never replays onto the new link',
    (tester) async {
      large(tester);
      final h = StudioHarness(), fresh = StudioHarness();
      final opening = Completer<FrameLink>();
      final recovery = ConnectionRecovery(
        h.pedal.wire,
        () => opening.future,
        retryDelays: const [Duration.zero],
        heartbeatInterval: Duration.zero,
      );
      await tester.pumpWidget(studio(h, recovery: recovery));
      await tester.pumpAndSettle();
      final send = h.pedal.link.sent!;
      h.pedal.link.sent = (bytes) async {
        if (FrameDecoder().add(bytes).single.command == 0x82) {
          h.pedal.link.incoming.addError(Exception('lost during drag'));
        } else {
          await send(bytes);
        }
      };
      tester
          .widget<Knob>(
            find.byWidgetPredicate((w) => w is Knob && w.label == 'GAIN'),
          )
          .onPreview!(75);
      await tester.pump(const Duration(milliseconds: 20));
      expect(read16(recovery.draft!.bytes, 0x30), 75);
      opening.complete(fresh.pedal.link);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      for (var i = 0; i < 80 && !recovery.connected; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      expect(recovery.connected, isTrue);
      expect(
        fresh.pedal.link.writes.map(
          (b) => FrameDecoder().add(b).single.command,
        ),
        isNot(contains(0x82)),
      );
      expect(find.text('下書きを本体へ戻す'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(recovery.close);
      recovery.dispose();
      await tester.runAsync(h.close);
    },
  );

  testWidgets(
    'a footswitch change cancels previews waiting behind another request',
    (tester) async {
      large(tester);
      final h = StudioHarness();
      await tester.pumpWidget(studio(h));
      await tester.pumpAndSettle();
      final gate = Completer<void>();
      final send = h.pedal.link.sent!;
      final commands = <int>[];
      h.pedal.link.sent = (bytes) async {
        final f = FrameDecoder().add(bytes).single;
        commands.add(f.command);
        if (f.command == 0) {
          await gate.future;
        }
        await send(bytes);
      };
      final probe = h.pedal.wire.exchange(0, [], 1);
      tester
          .widget<Knob>(
            find.byWidgetPredicate((w) => w is Knob && w.label == 'GAIN'),
          )
          .onPreview!(90);
      await tester.pump();
      h.selectPreset(1);
      await tester.pump();
      gate.complete();
      await tester.pumpAndSettle();
      await probe;
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(commands, isNot(contains(0x82)));
      expect(read16(h.edit, 0x30), 50);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(h.close);
    },
  );
  for (final size in [
    const Size(360, 640),
    const Size(640, 360),
    const Size(1280, 800),
  ]) {
    testWidgets('named controls fit every module at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = StudioHarness();
      await tester.pumpWidget(studio(h));
      await tester.pumpAndSettle();
      for (var module = 0; module < 7; module++) {
        if (find.byType(ChainStrip).evaluate().isNotEmpty) {
          final chain = tester.widget<ChainStrip>(find.byType(ChainStrip));
          chain.onTap(chain.order.indexOf(module));
        } else {
          final menu = tester.widget<PopupMenuButton<int>>(
            find.byWidgetPredicate(
              (w) => w is PopupMenuButton<int> && w.tooltip == 'エフェクトを選ぶ',
            ),
          );
          menu.onSelected!(module);
        }
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: 'module $module at $size',
        );
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(h.close);
    });
  }

  testWidgets(
    'NAM preview sends while held, coalesces queued values, then verifies release',
    (tester) async {
      large(tester);
      final h = StudioHarness();
      await tester.pumpWidget(studio(h));
      await tester.pumpAndSettle();
      final gate = Completer<void>();
      final send = h.pedal.link.sent!;
      final values = <int>[];
      var reads = 0;
      h.pedal.link.sent = (bytes) async {
        final f = FrameDecoder().add(bytes).single;
        if (f.command == 0x94) reads++;
        if (f.command == 0x82) {
          values.add(read16(f.payload, 4));
          if (values.length == 1) await gate.future;
        }
        await send(bytes);
      };
      final knob = tester.widget<Knob>(
        find.byWidgetPredicate((w) => w is Knob && w.label == 'GAIN'),
      );
      knob.onPreview!(60);
      await tester.pump();
      knob.onPreview!(70);
      knob.onPreview!(90);
      await tester.pump();
      expect(values, [60]);
      gate.complete();
      await tester.pumpAndSettle();
      expect(values, [60, 90]);
      expect(reads, 0);
      expect(read16(h.edit, 0x30), 90);
      knob.onChanged(92);
      await tester.pumpAndSettle();
      expect(values.last, 92);
      expect(reads, 1);
      expect(
        tester
            .widget<Knob>(
              find.byWidgetPredicate((w) => w is Knob && w.label == 'GAIN'),
            )
            .value,
        92,
      );
      expect(h.pedal.writes, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(h.close);
    },
  );

  testWidgets(
    'CAB shows actual IR names and selecting one preserves unused fields',
    (tester) async {
      large(tester);
      final h = StudioHarness();
      h.pedal.irUsed[0] = true;
      const name = '01_EBS_PL_410_by_Shift_Line';
      h.pedal.irNames[0].setRange(0, name.length, name.codeUnits);
      h.edit = PedalPreset(h.edit)
          .setWord(0x46, 11)
          .setWord(0x48, 3)
          .setWord(0x4a, 67)
          .bytes;
      await tester.pumpWidget(studio(h));
      await tester.pumpAndSettle();
      await selectModule(tester, 3);
      expect(find.text('IR1 · $name'), findsOneWidget);
      expect(find.byType(Knob), findsNothing);
      await tester.tap(find.byType(EffectChoice));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('IR3 · Cab IR'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('IR3 · Cab IR'));
      await tester.pumpAndSettle();
      expect(read16(h.edit, 0x46), 13);
      expect(read16(h.edit, 0x48), 3);
      expect(read16(h.edit, 0x4a), 67);
      const renamed = 'Actual_IR3_Name';
      h.pedal.link.incoming.add(
        frame(0x69, [
          1,
          ...u16(3),
          1,
          2,
          ...renamed.codeUnits,
          ...List.filled(50 - renamed.length, 0),
          50,
          0,
          0,
          0,
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.text('IR3 · $renamed'), findsOneWidget);
      expect(h.pedal.writes, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(h.close);
    },
  );

  testWidgets('MOD choices update the audible per-type controls', (
    tester,
  ) async {
    large(tester);
    final h = StudioHarness();
    await tester.pumpWidget(studio(h));
    await tester.pumpAndSettle();
    await selectModule(tester, 4);
    expect(find.text('Phaser'), findsOneWidget);
    expect(find.text('スイープ幅'), findsOneWidget);
    await tester.tap(find.byType(EffectChoice));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Analog Chorus').last,
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Analog Chorus').last);
    await tester.pumpAndSettle();
    expect(find.text('コーラスの深さ'), findsOneWidget);
    expect(find.text('トーン'), findsOneWidget);
    expect(read16(h.edit, 0x76), 8);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(h.close);
  });

  testWidgets('NAM bypass visibly disables tone controls', (tester) async {
    final h = StudioHarness()..selected = 0;
    await tester.pumpWidget(studio(h));
    await tester.pumpAndSettle();
    expect(
      tester.widgetList<Knob>(find.byType(Knob)).every((k) => !k.enabled),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(h.close);
  });
}
