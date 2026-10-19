import 'dart:convert';

import 'package:fb200_nam/pedal_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pedal_client_test.dart' show PedalHarness;

void main() {
  testWidgets('narrow editor reads bank and gates unsupported NAM tools', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final h = PedalHarness();
    await tester.pumpWidget(
      MaterialApp(
        home: PedalPage(
          transport: h.wire,
          restrictedNam: true,
          toolsAvailable: false,
          effectsAvailable: false,
          btAudioAvailable: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('0A  PRESET'), findsWidgets);
    expect(h.writes, 0);
    await tester.tap(find.text('チューナー'));
    await tester.pumpAndSettle();
    expect(find.text('チューナーは本体の更新後に利用できます。'), findsOneWidget);
    // Gated tools render no interactive controls.
    expect(find.byType(Switch), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(h.close);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stock editor exposes controls without requiring NAM RPC', (
    tester,
  ) async {
    final h = PedalHarness();
    await tester.pumpWidget(
      MaterialApp(
        home: PedalPage(
          transport: h.wire,
          restrictedNam: false,
          toolsAvailable: true,
          effectsAvailable: true,
          btAudioAvailable: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('チューナー'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SwitchListTile>(find.byType(SwitchListTile).first)
          .onChanged,
      isNotNull,
    );
    expect(find.text('チューナーは本体の更新後に利用できます。'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(h.close);
    expect(h.writes, 0);
  });

  testWidgets('IR tab lists slots, notes the NAM gap and renames', (
    tester,
  ) async {
    final h = PedalHarness();
    await tester.pumpWidget(
      MaterialApp(
        home: PedalPage(
          transport: h.wire,
          restrictedNam: true,
          toolsAvailable: false,
          effectsAvailable: false,
          btAudioAvailable: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('IR'));
    await tester.pumpAndSettle();
    expect(find.text('IR3'), findsOneWidget);
    expect(find.text('Cab IR'), findsOneWidget);
    expect(find.text('空き'), findsWidgets);
    expect(
      find.text(
        '現在のNAMファームウェアではキャビネットIRは音声処理に使われません。保存したIRはストックファームウェアで利用できます。',
      ),
      findsOneWidget,
    );
    // Renaming IR3 through the sheet menu updates the slot name.
    await tester.tap(find.text('Cab IR'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('名前の変更'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Cab IR v2');
    await tester.tap(find.text('次へ'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600)); // dialog outro timer
    expect(latin1.decode(h.irNames[2]).split('\x00').first, 'Cab IR v2');
    expect(h.writes, 0); // legacy preset writes must not happen
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(h.close);
  });

  testWidgets('stock IR tab shows no NAM notice and deletes with confirm', (
    tester,
  ) async {
    final h = PedalHarness();
    await tester.pumpWidget(
      MaterialApp(
        home: PedalPage(
          transport: h.wire,
          restrictedNam: false,
          toolsAvailable: true,
          effectsAvailable: true,
          btAudioAvailable: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('IR'));
    await tester.pumpAndSettle();
    expect(find.text('IR3'), findsOneWidget);
    expect(find.text('Cab IR'), findsOneWidget);
    expect(
      find.text(
        '現在のNAMファームウェアではキャビネットIRは音声処理に使われません。保存したIRはストックファームウェアで利用できます。',
      ),
      findsNothing,
    );
    await tester.tap(find.text('Cab IR'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('削除'));
    await tester.pumpAndSettle();
    expect(find.text('IRを削除'), findsOneWidget);
    await tester.tap(find.text('削除する'));
    await tester.pumpAndSettle();
    expect(h.irUsed[2], isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(h.close);
    expect(h.writes, 0);
  });

  testWidgets('Bluetooth rename dialog sends exactly twenty bytes', (
    tester,
  ) async {
    final h = PedalHarness();
    await tester.pumpWidget(
      MaterialApp(
        home: PedalPage(
          transport: h.wire,
          restrictedNam: false,
          toolsAvailable: true,
          effectsAvailable: true,
          btAudioAvailable: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('設定'));
    await tester.pumpAndSettle();
    // The settings tab is a fixed layout; the entry is always visible.
    await tester.tap(find.text('Bluetooth名の変更'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'FB200 KJ');
    await tester.tap(find.text('次へ'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 600)); // dialog outro timer
    expect(h.btName, isNotNull);
    expect(h.btName!.length, 20);
    expect(h.btName!.sublist(0, 8), 'FB200 KJ'.codeUnits);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(h.close);
    expect(h.writes, 0);
  });

  testWidgets('tools tab shows the looper when the probe answers', (
    tester,
  ) async {
    final h = PedalHarness();
    await tester.pumpWidget(
      MaterialApp(
        home: PedalPage(
          transport: h.wire,
          restrictedNam: false,
          toolsAvailable: true,
          effectsAvailable: true,
          btAudioAvailable: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('ルーパー'));
    await tester.pumpAndSettle();
    expect(find.text('タップ'), findsOneWidget);
    expect(find.text('録音'), findsOneWidget);
    expect(h.writes, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(h.close);
  });
}
