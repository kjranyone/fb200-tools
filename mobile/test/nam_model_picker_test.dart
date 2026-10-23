import 'package:fb200_nam/nam_client.dart';
import 'package:fb200_nam/studio_theme.dart';
import 'package:fb200_nam/widgets/nam_model_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final size in [const Size(360, 640), const Size(844, 390)]) {
    testWidgets('64-slot picker searches and selects at $size with keyboard', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      int? selected;
      final state = DeviceState(1, [
        for (var n = 1; n <= 64; n++) ModelSlot(n, 'Capture $n'),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          theme: StudioTheme.theme,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async =>
                    selected = await pickNamModel(context, state),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 150);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('nam-model-search')),
        '64',
      );
      await tester.pumpAndSettle();
      expect(find.text('Capture 64'), findsOneWidget);
      expect(find.text('Capture 1'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('nam-slot-64')));
      await tester.pumpAndSettle();
      expect(selected, 64);
    });
  }

  testWidgets(
    'cancel is read-only and transfer includes empty slots without bypass',
    (tester) async {
      int? choice;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => choice = await pickNamModel(
                  context,
                  DeviceState(1, [
                    const ModelSlot(1, 'Clean'),
                    const ModelSlot(2, null),
                  ]),
                  transfer: true,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('空きスロット'), findsOneWidget);
      expect(find.text('BYPASS'), findsNothing);
      await tester.tap(find.byTooltip('閉じる'));
      await tester.pumpAndSettle();
      expect(choice, isNull);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nam-slot-2')));
      await tester.pumpAndSettle();
      expect(choice, 2);
    },
  );
}
