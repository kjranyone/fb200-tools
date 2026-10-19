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
      await tester.ensureVisible(find.text('接続せず試す'));
      await tester.tap(find.text('接続せず試す'));
      await tester.pumpAndSettle();
      expect(find.text('DEMO'), findsOneWidget);
      // Demo has no BLE wire, so no controller button; model management
      // is the demo's entry into the slot cards.
      expect(find.textContaining('モデル管理'), findsOneWidget);
      // Enter model management to see the slot cards.
      await tester.tap(find.textContaining('モデル管理'));
      await tester.pumpAndSettle();
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
      await tester.pumpAndSettle();
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
      // Back to hub, disconnect.
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('接続を終了'));
      await tester.pumpAndSettle();
      expect(find.text('接続せず試す'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('demo slot rename updates the list after refresh', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MainApp());
    await tester.tap(find.text('接続せず試す'));
    await tester.pumpAndSettle();
    // Enter model management to see the slot cards.
    await tester.tap(find.textContaining('モデル管理'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Demo Clean'), 250);
    // Bring the card up from the bottom edge so its menu fits on screen.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 320));
    await tester.pumpAndSettle();
    final card = find.ancestor(
      of: find.text('Demo Clean'),
      matching: find.byType(Card),
    );
    await tester.tap(
      find.descendant(of: card, matching: find.byType(PopupMenuButton<String>)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('名前の変更'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'DemoLead');
    await tester.tap(find.text('変更'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600)); // dialog outro timer
    expect(find.text('DemoLead'), findsOneWidget);
    expect(find.text('Demo Clean'), findsNothing);
    await tester.scrollUntilVisible(find.text('スロット 1 の名前を変更しました。'), 250);
    expect(find.text('スロット 1 の名前を変更しました。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
