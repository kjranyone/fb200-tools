import 'dart:async';

import 'package:fb200_nam/connection_recovery.dart';
import 'package:fb200_nam/protocol.dart';
import 'package:fb200_nam/model_page.dart';
import 'package:fb200_nam/nam_client.dart';
import 'package:fb200_nam/widgets/knob.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'studio_test.dart' show studio;
import 'support/studio_harness.dart';

void main() {
  for (final size in [const Size(360, 640), const Size(844, 390)]) {
    testWidgets('recovery status keeps the editor fixed at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = StudioHarness();
      final recovery = ConnectionRecovery(
        h.pedal.wire,
        () async => throw StateError('cancelled recovery must not open'),
        heartbeatInterval: Duration.zero,
      );
      await tester.pumpWidget(studio(h, recovery: recovery));
      await tester.pumpAndSettle();
      final editor = find.byKey(const ValueKey('fixed-editor'));
      final before = tester.getRect(editor);
      h.pedal.link.incoming.addError(Exception('lost'));
      await tester.pump();
      recovery.cancelRecovery();
      await tester.pumpAndSettle();
      expect(tester.getRect(editor), before);
      expect(find.text('同じ本体に再接続'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(recovery.close);
      recovery.dispose();
      await tester.runAsync(h.close);
    });
  }
  testWidgets(
    'an open borrowed library follows the recovered connection and releases no owner',
    (tester) async {
      final h = StudioHarness(), fresh = StudioHarness();
      fresh.names[2] = 'RecoveredBass';
      final recovery = ConnectionRecovery(
        h.pedal.wire,
        () async => fresh.pedal.link,
        retryDelays: const [Duration.zero],
        heartbeatInterval: Duration.zero,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ModelPage(
            sharedClient: h.client,
            initialState: DeviceState(1, [const ModelSlot(1, 'Studio Clean')]),
            recovery: recovery,
          ),
        ),
      );
      await tester.pumpAndSettle();
      h.pedal.link.incoming.addError(Exception('lost in library'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      for (var i = 0; i < 80 && !recovery.connected; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(recovery.connected, isTrue);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('RecoveredBass'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('RecoveredBass'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(h.pedal.wire.isClosed, isFalse);
      await tester.runAsync(recovery.close);
      recovery.dispose();
      await tester.runAsync(h.close);
    },
  );

  testWidgets('a draft retained by firmware needs no restore or write', (
    tester,
  ) async {
    final h = StudioHarness(), fresh = StudioHarness();
    final recovery = ConnectionRecovery(
      h.pedal.wire,
      () async => fresh.pedal.link,
      retryDelays: const [Duration.zero],
      heartbeatInterval: Duration.zero,
    );
    await tester.pumpWidget(studio(h, recovery: recovery));
    await tester.pumpAndSettle();
    tester
        .widget<Knob>(
          find.byWidgetPredicate((w) => w is Knob && w.label == 'GAIN'),
        )
        .onChanged(75);
    await tester.pumpAndSettle();
    fresh.edit = h.edit.sublist(0);
    h.pedal.link.incoming.addError(Exception('lost'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    for (var i = 0; i < 80 && !recovery.connected; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(recovery.connected, isTrue);
    await tester.pumpAndSettle();
    expect(recovery.draft, isNull);
    expect(find.text('下書きを本体へ戻す'), findsNothing);
    expect(read16(fresh.edit, 0x30), 75);
    expect(fresh.pedal.writes, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(recovery.close);
    recovery.dispose();
    await tester.runAsync(h.close);
  });

  for (final interrupted in [false, true]) {
    testWidgets(
      'reconnection preserves ${interrupted ? 'interrupted' : 'confirmed'} edits for explicit restore',
      (tester) async {
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
        if (interrupted) {
          final before = h.pedal.link.sent!;
          h.pedal.link.sent = (bytes) async {
            if (FrameDecoder().add(bytes).single.command == 0x82) {
              h.pedal.link.incoming.addError(Exception('lost while writing'));
            } else {
              await before(bytes);
            }
          };
        }
        tester
            .widget<Knob>(
              find.byWidgetPredicate((w) => w is Knob && w.label == 'GAIN'),
            )
            .onChanged(75);
        await tester.pump(const Duration(milliseconds: 20));
        if (!interrupted) {
          await tester.pumpAndSettle();
          h.pedal.link.incoming.addError(Exception('lost after editing'));
        }
        await tester.pump(const Duration(milliseconds: 20));
        expect(recovery.draft, isNotNull);
        expect(
          find.byWidgetPredicate(
            (w) => w is ModalBarrier && w.color != null && w.color!.a > 0,
          ),
          findsNothing,
        );
        expect(find.byType(Knob), findsWidgets);
        expect(read16(recovery.draft!.bytes, 0x30), 75);
        expect(
          tester.widgetList<Knob>(find.byType(Knob)).every((k) => !k.enabled),
          isTrue,
        );
        opening.complete(fresh.pedal.link);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        for (var i = 0; i < 80 && !recovery.connected; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(
          recovery.connected,
          isTrue,
          reason:
              'phase=${recovery.phase}, error=${recovery.error}, reads=${fresh.pedal.link.writes.map((b) => FrameDecoder().add(b).single.command).toList()}',
        );
        await tester.pumpAndSettle();
        expect(find.text('下書きを本体へ戻す'), findsOneWidget);
        expect(read16(fresh.edit, 0x30), 50);
        expect(fresh.pedal.writes, 0);
        expect(
          fresh.pedal.link.writes.map(
            (b) => FrameDecoder().add(b).single.command,
          ),
          isNot(contains(0x97)),
        );
        await tester.tap(find.text('下書きを本体へ戻す'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('編集を戻す'));
        await tester.pumpAndSettle();
        expect(read16(fresh.edit, 0x30), 75);
        expect(fresh.pedal.writes, 0);
        expect(recovery.draft, isNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(recovery.close);
        recovery.dispose();
        await tester.runAsync(h.close);
      },
    );
  }
}
