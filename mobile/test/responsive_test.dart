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

Future<void> scrollTo(WidgetTester tester, Finder f) => tester
    .scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).first);

void main() {
  for (final (name, size) in screenSizes) {
    testWidgets('home renders at $name', (tester) async {
      setScreen(tester, size);
      await tester.pumpWidget(const MainApp());
      await tester.pumpAndSettle();
      // The headline (a two-line Text) is at the top on every size.
      expect(find.textContaining('いつもの音を'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: name);
      // The demo entry is reachable by scrolling on small screens.
      await scrollTo(tester, find.text('接続せず試す'));
      expect(tester.takeException(), isNull, reason: '$name scrolled');
    });
  }

  for (final (name, size) in screenSizes) {
    testWidgets('demo (NAM manager) renders at $name', (tester) async {
      setScreen(tester, size);
      await tester.pumpWidget(const MainApp());
      await tester.pumpAndSettle();
      await scrollTo(tester, find.text('接続せず試す'));
      await tester.tap(find.text('接続せず試す'));
      await tester.pumpAndSettle();
      expect(find.text('DEMO'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: name);
      // The model slot cards and the pedal entry build without overflow.
      await scrollTo(tester, find.text('プリセット・エフェクト・ツール'));
      expect(tester.takeException(), isNull, reason: '$name scrolled');
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
      expect(find.text('0A  PRESET'), findsWidgets);
      expect(tester.takeException(), isNull, reason: name);
      for (final tab in ['エフェクト', 'ツール', 'IR', '設定']) {
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$name on $tab');
      }
      // The chain strip renders with the stock module set.
      await tester.tap(find.text('エフェクト'));
      await tester.pumpAndSettle();
      expect(find.text('モジュールの接続順'), findsOneWidget);
      expect(tester.takeException(), isNull);
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
      await tester.tap(find.text('COMP'));
      await tester.pumpAndSettle();
      expect(find.text('コンプレッサー'), findsOneWidget);
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
      await tester.tap(find.text('モジュールの接続順'));
      await tester.pumpAndSettle();
      expect(find.text('変更'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: name);
      await tester.tap(find.text('キャンセル').last);
      await tester.pumpAndSettle();
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
      await scrollTo(tester, find.text('名前').first);
      await tester.tap(find.text('名前').first);
      await tester.pumpAndSettle();
      expect(find.text('次へ'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: name);
      await tester.tap(find.text('キャンセル').last);
      await tester.pumpAndSettle();
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
      await scrollTo(tester, find.text('Bluetooth名の変更'));
      await tester.tap(find.text('Bluetooth名の変更'));
      await tester.pumpAndSettle();
      expect(find.text('次へ'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: name);
      await tester.tap(find.text('キャンセル').last);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(h.close);
    });
  }
}
