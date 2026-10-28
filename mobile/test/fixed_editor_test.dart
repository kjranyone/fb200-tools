import 'package:fb200_nam/widgets/chain_strip.dart';
import 'package:fb200_nam/widgets/knob.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'studio_test.dart' show studio;
import 'support/studio_harness.dart';

void main() {
  for (final size in [
    const Size(360, 640),
    const Size(390, 844),
    const Size(640, 360),
    const Size(844, 390),
    const Size(768, 1024),
    const Size(1024, 768),
    const Size(1280, 800),
  ]) {
    testWidgets(
      'editor stays fixed and all NAM parameters are reachable at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);
        final h = StudioHarness();
        await tester.pumpWidget(studio(h, openModels: () async {}));
        await tester.pumpAndSettle();
        final editor = find.byKey(const ValueKey('fixed-editor'));
        expect(
          find.descendant(of: editor, matching: find.byType(Scrollable)),
          findsNothing,
        );
        final bounds = tester.getRect(editor);
        final seen = <String>{};
        for (var page = 0; page < 4; page++) {
          for (final element in find.byType(Knob).evaluate()) {
            final knob = element.widget as Knob;
            seen.add(knob.label);
            final rect = tester.getRect(find.byWidget(knob));
            expect(
              bounds.inflate(.1).contains(rect.topLeft),
              isTrue,
              reason: '${knob.label} top',
            );
            expect(
              bounds.inflate(.1).contains(rect.bottomRight),
              isTrue,
              reason: '${knob.label} bottom',
            );
          }
          final next = find.byWidgetPredicate(
            (w) => w is IconButton && w.tooltip == '次のパラメーター',
          );
          if (next.evaluate().isEmpty ||
              tester.widget<IconButton>(next).onPressed == null) {
            break;
          }
          await tester.tap(next);
          await tester.pumpAndSettle();
        }
        expect(
          seen,
          containsAll(['GAIN', 'BASS', 'MID', 'TREBLE', 'MID FREQ', 'VOLUME']),
        );
        if (size.width >= 1000) {
          expect(find.byType(Knob), findsNWidgets(6));
          expect(find.byTooltip('次のパラメーター'), findsNothing);
        }
        expect(tester.takeException(), isNull);
        expect(h.pedal.writes, 0);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(h.close);
      },
    );
  }

  testWidgets('a swipe on the module card steps along the chain', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final h = StudioHarness();
    await tester.pumpWidget(studio(h));
    await tester.pumpAndSettle();
    int selected() =>
        tester.widget<ChainStrip>(find.byType(ChainStrip)).selected!;
    final start = selected();
    // The header icon is no hit target of its own.
    final empty =
        tester.getTopLeft(find.byKey(const ValueKey('module-card'))) +
        const Offset(28, 28);

    await tester.dragFrom(empty, const Offset(-160, 0));
    await tester.pumpAndSettle();
    expect(selected(), start + 1);
    expect(find.text('NAM A2 LITE'), findsNothing);

    await tester.dragFrom(empty, const Offset(160, 0));
    await tester.pumpAndSettle();
    expect(selected(), start);
    expect(find.text('NAM A2 LITE'), findsOneWidget);

    // While the finger is down the card follows it and shows where a
    // release goes; a short, slow pull springs back.
    final card = find.byKey(const ValueKey('module-card'));
    final body = find.descendant(of: card, matching: find.byType(Card));
    final rest = tester.getTopLeft(body);
    final gesture = await tester.startGesture(empty);
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(-8, 0));
      await tester.pump(const Duration(milliseconds: 50));
    }
    final next = find.descendant(
      of: card,
      matching: find.byKey(const ValueKey('swipe-next')),
    );
    expect(next, findsOneWidget);
    expect(
      find.descendant(of: next, matching: find.text('CAB')),
      findsOneWidget,
    );
    expect(tester.getTopLeft(body).dx, lessThan(rest.dx));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selected(), start);
    expect(next, findsNothing);
    expect(tester.getTopLeft(body), rest);

    // A slow pull past the threshold arms the hint and moves on release.
    final slow = await tester.startGesture(empty);
    for (var i = 0; i < 20; i++) {
      await slow.moveBy(const Offset(-8, 0));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(selected(), start);
    await tester.pump(const Duration(milliseconds: 200));
    await slow.up();
    await tester.pumpAndSettle();
    expect(selected(), start + 1);
    await tester.dragFrom(empty, const Offset(160, 0));
    await tester.pumpAndSettle();
    expect(selected(), start);

    // The chain's first module gives way but never wraps around.
    final first = tester.widget<ChainStrip>(find.byType(ChainStrip));
    first.onTap(0);
    await tester.pumpAndSettle();
    await tester.dragFrom(empty, const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(selected(), 0);
    first.onTap(start);
    await tester.pumpAndSettle();

    // A sideways drag on a knob is fine control, never a module change.
    await tester.drag(find.byType(Knob).first, const Offset(-160, 0));
    await tester.pumpAndSettle();
    expect(selected(), start);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(h.close);
  });
}
