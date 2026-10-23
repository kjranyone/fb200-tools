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
}
