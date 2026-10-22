import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fb200_nam/model_page.dart';
import 'package:fb200_nam/nam_model.dart';
import 'package:fb200_nam/tone3000.dart';
import 'package:fb200_nam/tone3000_page.dart';
import 'package:fb200_nam/tone_library.dart';

import 'tone3000_test.dart'
    show ToneHarness, acceptBrowser, modelFixture, toneFixture, variant;

MemoryToneSessionStore signedIn() => MemoryToneSessionStore()
  ..clientId = 'publishable-test'
  ..refreshToken = 'refresh-test';

ImportedTone importedTone(String name, int id) => ImportedTone(
  TonePack(
    id: 7,
    title: 'Bass Full Rig',
    gear: 'amp-cab',
    creator: ToneCreator('creator', null),
    image: null,
  ),
  ToneModel(
    id,
    7,
    name,
    Uri.https('www.tone3000.com', '/api/v1/models/$id/download'),
  ),
  NamModel.parse(
    File('test/fixtures/synthetic.nam').readAsBytesSync(),
    '$name.nam',
  ),
);

/// Pumps the demo pedal's per-chunk timers until [done] holds.
Future<void> pumpTransfer(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pumpAndSettle();
}

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'tone3000_client_id': 'publishable-test',
    }),
  );

  Future<Future<List<ImportedTone>?> Function()> openPage(
    WidgetTester tester,
    Tone3000Page page,
  ) async {
    List<ImportedTone>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await Navigator.push<List<ImportedTone>>(
                  context,
                  MaterialPageRoute(builder: (_) => page),
                );
              },
              child: const Text('開く'),
            ),
          ),
        ),
      ),
    );
    return () async => result;
  }

  testWidgets(
    'Select signs in, then saves the chosen variants to the device library',
    (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = ToneHarness();
      final library = ToneLibrary(MemoryLibraryStorage());
      final result = await openPage(
        tester,
        Tone3000Page(
          apiFactory: (_) => h.api,
          browser: acceptBrowser,
          library: library,
        ),
      );
      await tester.pump();
      await tester.tap(find.text('開く'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('TONE3000で探す'));
      await tester.pumpAndSettle();
      // The chosen tone opens over the signed-in favorites list.
      expect(find.text('@listener でログイン中'), findsOneWidget);
      expect(find.text('Bass Clean'), findsOneWidget);
      expect(find.text('@creator'), findsWidgets);
      expect(h.downloads, 0);
      expect(find.text('1 件を保存して転送へ'), findsNothing);
      await tester.tap(find.text('1 件を端末に保存'));
      await tester.pumpAndSettle();
      expect(h.downloads, 1);
      expect(library.has(11), isTrue);
      expect(find.textContaining('端末に保存 1 件'), findsOneWidget);
      expect(h.sessions.refreshToken, 'refresh-test');

      await tester.tap(find.text('端末（1）'));
      await tester.pumpAndSettle();
      expect(find.text('Bass Clean'), findsOneWidget);
      await tester.tap(find.text('Bass Clean'));
      await tester.pumpAndSettle();
      // Without a connected pedal, a selection cannot be sent anywhere.
      expect(find.text('本体に接続すると転送できます'), findsOneWidget);
      expect(await result(), isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a transfer visit saves and returns the chosen variant', (
    tester,
  ) async {
    final h = ToneHarness();
    final result = await openPage(
      tester,
      Tone3000Page(
        apiFactory: (_) => h.api,
        browser: acceptBrowser,
        library: ToneLibrary(MemoryLibraryStorage()),
        freeSlots: 1,
      ),
    );
    await tester.pump();
    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TONE3000で探す'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 件を保存して転送へ'));
    await tester.pumpAndSettle();
    final imported = await result();
    expect(imported?.single.model.packet.length, 7548);
    expect(imported?.single.tone.creator.username, 'creator');
    expect(find.text('開く'), findsOneWidget);
  });

  testWidgets(
    'a stored session lists A2 favorites and saves a whole tone in one tap',
    (tester) async {
      final h = ToneHarness(sessions: signedIn())
        ..extraModels = [variant(13, 'Bass Drive')];
      final library = ToneLibrary(MemoryLibraryStorage());
      await tester.pumpWidget(
        MaterialApp(
          home: Tone3000Page(apiFactory: (_) => h.api, library: library),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('@listener でログイン中'), findsOneWidget);
      expect(find.text('Bass Full Rig'), findsOneWidget);
      expect(find.textContaining('2 モデル'), findsOneWidget);
      expect(find.text('Spring IR'), findsNothing);
      expect(find.text('Old A1 Amp'), findsNothing);
      expect(find.text('全カタログから選ぶ'), findsOneWidget);

      await tester.tap(find.byTooltip('すべてダウンロード'));
      await tester.pumpAndSettle();
      expect(library.storedFor(7), 2);
      expect(find.text('端末（2）'), findsOneWidget);
      expect(find.byTooltip('すべて端末に保存済み'), findsOneWidget);

      await tester.tap(find.text('ダウンロード履歴'));
      await tester.pumpAndSettle();
      expect(h.requests.last.url.path, endsWith('/tones/downloaded'));
      await tester.enterText(
        find.byKey(const ValueKey('tone-remote-query')),
        'bass',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(h.requests.last.url.queryParameters['query'], 'bass');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('signing out forgets the stored session', (tester) async {
    final h = ToneHarness(sessions: signedIn());
    await tester.pumpWidget(
      MaterialApp(
        home: Tone3000Page(
          apiFactory: (_) => h.api,
          library: ToneLibrary(MemoryLibraryStorage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('ログアウト'));
    await tester.pumpAndSettle();
    expect(h.sessions.refreshToken, isNull);
    expect(find.text('TONE3000で探す'), findsOneWidget);
    expect(find.textContaining('ログアウトしました'), findsOneWidget);
  });

  testWidgets('device tab searches locally and returns every selected model', (
    tester,
  ) async {
    final library = ToneLibrary(MemoryLibraryStorage());
    final tone = TonePack.parse(toneFixture);
    final bytes = File('test/fixtures/synthetic.nam').readAsBytesSync();
    await library.store(tone, ToneModel.parse(modelFixture), bytes);
    await library.store(tone, ToneModel.parse(variant(13, 'Drive')), bytes);
    final result = await openPage(
      tester,
      Tone3000Page(
        apiFactory: (_) => ToneHarness().api,
        library: library,
        freeSlots: 5,
      ),
    );
    await tester.pump();
    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();
    // A transfer visit with stored models opens the device tab first.
    expect(find.text('Bass Clean'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('tone-local-query')),
      'drive',
    );
    await tester.pumpAndSettle();
    expect(find.text('Bass Clean'), findsNothing);
    await tester.tap(find.text('Drive'));
    await tester.enterText(
      find.byKey(const ValueKey('tone-local-query')),
      '@creator',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bass Clean'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2 件を転送へ（空き 5）'));
    await tester.pumpAndSettle();
    final imported = await result();
    expect(imported?.map((i) => i.variant.id).toSet(), {11, 13});
  });

  testWidgets(
    'keyboard Go starts the explicit login flow and saves the public key',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final h = ToneHarness();
      var browserCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Tone3000Page(
            apiFactory: (_) => h.api,
            library: ToneLibrary(MemoryLibraryStorage()),
            browser: (url) async {
              browserCalls++;
              return acceptBrowser(url);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('キーの設定だけではログインは完了しません'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'publishable-test');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      expect(browserCalls, 1);
      expect(find.text('@listener でログイン中'), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getString('tone3000_client_id'),
        'publishable-test',
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final cancel in [ToneCancelled(), PlatformException(code: 'CANCELED')]) {
    testWidgets(
      'browser cancellation explains how to continue: ${cancel.runtimeType}',
      (tester) async {
        final h = ToneHarness();
        await tester.pumpWidget(
          MaterialApp(
            home: Tone3000Page(
              apiFactory: (_) => h.api,
              library: ToneLibrary(MemoryLibraryStorage()),
              browser: (_) async => throw cancel,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('TONE3000で探す'));
        await tester.pumpAndSettle();
        expect(find.textContaining('ログイン・トーン選択を中止しました'), findsOneWidget);
        expect(h.requests, isEmpty);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('first setup rejects a secret key without contacting TONE3000', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Tone3000Page(
          apiFactory: (_) {
            calls++;
            return ToneHarness().api;
          },
          library: ToneLibrary(MemoryLibraryStorage()),
          browser: acceptBrowser,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(toneCallback), findsOneWidget);
    await tester.enterText(find.byType(TextField), 't3k_cs_must-not-be-used');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.tap(find.text('TONE3000で探す'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Secret Keyは使用できません'), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets('an incompatible variant is reported and never stored', (
    tester,
  ) async {
    final h = ToneHarness()
      ..bytes = File('test/fixtures/synthetic.fbnm').readAsBytesSync();
    final library = ToneLibrary(MemoryLibraryStorage());
    await tester.pumpWidget(
      MaterialApp(
        home: Tone3000Page(
          apiFactory: (_) => h.api,
          browser: acceptBrowser,
          library: library,
          freeSlots: 3,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('TONE3000で探す'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 件を保存して転送へ'));
    await tester.pumpAndSettle();
    expect(find.textContaining('FB200対応外 1 件'), findsOneWidget);
    expect(library.entries, isEmpty);
    expect(find.byType(Tone3000Page), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a single import feeds the existing demo transfer without automatically selecting',
    (tester) async {
      int? offered;
      await tester.pumpWidget(
        MaterialApp(
          home: ModelPage(
            pickTone: (_, free) async {
              offered = free;
              return [importedTone('BassClean', 11)];
            },
          ),
        ),
      );
      // Connect to demo, then enter model management to reach the slots.
      await tester.scrollUntilVisible(find.text('接続せず試す'), 180);
      await tester.tap(find.text('接続せず試す'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('モデル管理'));
      await tester.pumpAndSettle();
      // The TONE3000 import is available inside model management.
      await tester.ensureVisible(find.text('TONE3000から探す'));
      await tester.tap(find.text('TONE3000から探す'));
      await tester.pumpAndSettle();
      expect(offered, 1);
      expect(find.text('Bass Full Rig'), findsOneWidget);
      await tester.ensureVisible(find.text('転送先を選ぶ'));
      await tester.tap(find.text('転送先を選ぶ'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nam-slot-3')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('03'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      final card = find.ancestor(
        of: find.text('03'),
        matching: find.byType(Card),
      );
      await pumpTransfer(
        tester,
        () => find
            .descendant(of: card, matching: find.text('BassClean'))
            .evaluate()
            .isNotEmpty,
      );
      expect(
        find.descendant(of: card, matching: find.text('BassClean')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('選択中')),
        findsNothing,
      );
      expect(
        find.descendant(of: card, matching: find.text('@creator')),
        findsOneWidget,
      );
      await tester.tap(find.text('ロードして試聴'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: card, matching: find.text('選択中')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a batch fills only empty slots after confirmation', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ModelPage(
          pickTone: (_, _) async => [
            importedTone('BassClean', 11),
            importedTone('BassDrive', 13),
          ],
        ),
      ),
    );
    await tester.scrollUntilVisible(find.text('接続せず試す'), 180);
    await tester.tap(find.text('接続せず試す'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('モデル管理'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('TONE3000から探す'));
    await tester.tap(find.text('TONE3000から探す'));
    await tester.pumpAndSettle();
    // The demo pedal has one empty slot (03); slots 01 and 02 are kept.
    expect(find.text('1 件をまとめて転送'), findsOneWidget);
    expect(find.text('03  ←  BassClean'), findsOneWidget);
    expect(find.textContaining('残り 1 件は転送しません'), findsOneWidget);
    await tester.tap(find.text('転送'));
    await pumpTransfer(
      tester,
      () => find.text('1 件を空きスロットへ転送しました。').evaluate().isNotEmpty,
    );
    expect(find.text('1 件を空きスロットへ転送しました。'), findsOneWidget);
    expect(find.text('Demo Clean'), findsOneWidget);
    expect(find.text('Demo Crunch'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('BassClean'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('BassClean'), findsOneWidget);
    expect(find.text('BassDrive'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
