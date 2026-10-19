import 'package:fb200_nam/main.dart';
import 'package:fb200_nam/pedal_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pedal_client_test.dart' show PedalHarness;

/// Responsive layout verification: the app must render without layout
/// exceptions (RenderFlex overflows surface as test exceptions) on phone
/// and tablet sizes, portrait and landscape, on every page and dialog.
const screenSizes = [
  ('small phone portrait', Size(360, 640)),
  ('small phone landscape', Size(640, 360)),
  ('phone portrait', Size(390, 844)),
  ('phone landscape', Size(844, 390)),
  ('tablet portrait', Size(768, 1024)),
  ('tablet landscape', Size(1024, 768)),
  ('large tablet landscape', Size(1280, 800)),
];

/// Dialogs get the tightest heights and the widest tablet.
const dialogSizes = [
  ('small phone portrait', Size(360, 640)),
  ('small phone landscape', Size(640, 360)),
  ('phone landscape', Size(844, 390)),
  ('large tablet landscape', Size(1280, 800)),
];

void setScreen(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Scroll the first Scrollable until [finder] is visible, then settle.
Future<void> bringIntoView(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    250,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

/// Tap a widget that might be off-screen or not yet built (lazy ListView):
/// scroll to it if needed, then tap.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await bringIntoView(tester, finder);
  } else {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }
  await tester.tap(finder, warnIfMissed: false);
}

void main() {
  for (final (name, size) in screenSizes) {
    testWidgets('home renders at $name', (tester) async {
      setScreen(tester, size);
      await tester.pumpWidget(const MainApp());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: name);
      // Scrolling to the demo entry must not overflow on any size.
      if (find.text('接続せず試す').evaluate().isEmpty) {
        await bringIntoView(tester, find.text('接続せず試す'));
      }
      expect(tester.takeException(), isNull, reason: '$name scrolled');
    });
  }

  for (final (name, size) in screenSizes) {
    testWidgets('demo (NAM manager) renders at $name', (tester) async {
      setScreen(tester, size);
      await tester.pumpWidget(const MainApp());
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('接続せず試す'));
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      // The demo connection succeeded: no layout exception.
      expect(tester.takeException(), isNull, reason: '$name connected');
      // Scrolling through the model list must not overflow.
      if (find.text('プリセット・エフェクト・ツール').evaluate().isNotEmpty) {
        expect(tester.takeException(), isNull, reason: name);
      }
    });
  }

  for (final (name, size) in screenSizes) {
    testWidgets('pedal tabs render at $name', (tester) async {
      setScreen(tester, size);
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
      expect(tester.takeException(), isNull, reason: name);
      for (final tab in ['エフェクト', 'ツール', 'IR', '設定']) {
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$name on $tab');
      }
      // Back to the effects tab: the chain strip must render.
      await tester.tap(find.text('エフェクト'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$name chain');
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(h.close);
    });
  }

  for (final (name, size) in screenSizes) {
    testWidgets('effects chain selection opens knob editor at $name', (
      tester,
    ) async {
      setScreen(tester, size);
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
      await tester.tap(find.text('エフェクト'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('COMP'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: name);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(h.close);
    });
  }

  for (final (name, size) in dialogSizes) {
    testWidgets('module order dialog fits $name', (tester) async {
      setScreen(tester, size);
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
      await tester.tap(find.text('エフェクト'));
      await tester.pumpAndSettle();
      if (find.text('モジュールの接続順').evaluate().isEmpty) {
        await bringIntoView(tester, find.text('モジュールの接続順'));
      }
      await tester.tap(find.text('モジュールの接続順'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: name);
      // Close any open dialog (AlertDialog renders its own overlay).
      final cancel = find.text('キャンセル');
      if (cancel.evaluate().isNotEmpty) {
        await tester.tap(cancel.last, warnIfMissed: false);
        await tester.pumpAndSettle();
      }
      // Flush the dialog controller's 500 ms dispose timer.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(h.close);
    });
  }

  for (final (name, size) in dialogSizes) {
    testWidgets('preset rename dialog fits $name', (tester) async {
      setScreen(tester, size);
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
      // The first preset card's 名前 button opens the rename dialog.
      if (find.text('名前').evaluate().isEmpty) {
        await bringIntoView(tester, find.text('名前').first);
      }
      await tester.tap(find.text('名前').first, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: name);
      final cancel = find.text('キャンセル');
      if (cancel.evaluate().isNotEmpty) {
        await tester.tap(cancel.last, warnIfMissed: false);
        await tester.pumpAndSettle();
      }
      // Flush the dialog controller's 500 ms dispose timer.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(h.close);
    });
  }

  for (final (name, size) in dialogSizes) {
    testWidgets('Bluetooth name dialog fits $name', (tester) async {
      setScreen(tester, size);
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
      if (find.text('Bluetooth名の変更').evaluate().isEmpty) {
        await bringIntoView(tester, find.text('Bluetooth名の変更'));
      }
      await tester.tap(find.text('Bluetooth名の変更'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: name);
      final cancel = find.text('キャンセル');
      if (cancel.evaluate().isNotEmpty) {
        await tester.tap(cancel.last, warnIfMissed: false);
        await tester.pumpAndSettle();
      }
      // Flush the dialog controller's 500 ms dispose timer.
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(h.close);
    });
  }
}
