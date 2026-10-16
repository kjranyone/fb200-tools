import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fb200_nam/main.dart';

void main() {
  testWidgets(
    'explicit demo is usable at narrow phone width, selects, saves and disconnects',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const MainApp());
      expect(find.text('接続せず試す'), findsOneWidget);
      expect(find.text('DEMO'), findsNothing);
      await tester.tap(find.text('接続せず試す'));
      await tester.pumpAndSettle();
      expect(find.text('DEMO'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Demo Crunch'), 250);
      final card = find.ancestor(
        of: find.text('Demo Crunch'),
        matching: find.byType(Card),
      );
      final select = find.descendant(
        of: card,
        matching: find.widgetWithText(OutlinedButton, '選択'),
      );
      await tester.ensureVisible(select);
      await tester.tap(select);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: card, matching: find.text('選択中')),
        findsOneWidget,
      );
      final save = find.text('現在の選択をプリセットに保存');
      await tester.scrollUntilVisible(save, 200);
      await tester.tap(save);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('現在のプリセットに選択を保存しました。'), 200);
      expect(find.text('現在のプリセットに選択を保存しました。'), findsOneWidget);
      await tester.tap(find.byTooltip('接続を終了'));
      await tester.pumpAndSettle();
      expect(find.text('接続せず試す'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
