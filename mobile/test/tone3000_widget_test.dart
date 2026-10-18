import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fb200_nam/main.dart';
import 'package:fb200_nam/nam_model.dart';
import 'package:fb200_nam/tone3000.dart';
import 'package:fb200_nam/tone3000_page.dart';

import 'tone3000_test.dart' show ToneHarness, acceptBrowser;

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'tone3000_client_id': 'publishable-test',
    }),
  );

  testWidgets(
    'Select browser returns to variants and import returns a validated model',
    (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = ToneHarness();
      ImportedTone? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await Navigator.push<ImportedTone>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => Tone3000Page(
                        apiFactory: (_) => h.api,
                        browser: acceptBrowser,
                      ),
                    ),
                  );
                },
                child: const Text('開く'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('開く'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('TONE3000で探す'));
      await tester.tap(find.text('TONE3000で探す'));
      await tester.pumpAndSettle();
      expect(find.text('Bass Full Rig'), findsOneWidget);
      expect(find.text('@creator'), findsOneWidget);
      expect(find.text('@listener でログイン中'), findsOneWidget);
      expect(h.downloads, 0);
      await tester.scrollUntilVisible(find.text('Bass Clean'), 180);
      await tester.tap(find.text('Bass Clean'));
      await tester.pumpAndSettle();
      expect(result?.model.packet.length, 7548);
      expect(result?.tone.creator.username, 'creator');
      expect(h.downloads, 1);
      expect(find.text('開く'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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
          browser: acceptBrowser,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(toneCallback), findsOneWidget);
    await tester.enterText(find.byType(TextField), 't3k_cs_must-not-be-used');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('TONE3000で探す'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TONE3000で探す'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Secret Keyは使用できません'), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets(
    'incompatible download remains in the picker and never returns a model',
    (tester) async {
      final h = ToneHarness()
        ..bytes = File('test/fixtures/synthetic.fbnm').readAsBytesSync();
      await tester.pumpWidget(
        MaterialApp(
          home: Tone3000Page(apiFactory: (_) => h.api, browser: acceptBrowser),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('TONE3000で探す'));
      await tester.tap(find.text('TONE3000で探す'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Bass Clean'), 150);
      await tester.tap(find.text('Bass Clean'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.textContaining('FB200で使用できません'),
        -150,
      );
      expect(find.textContaining('FB200で使用できません'), findsOneWidget);
      expect(find.byType(Tone3000Page), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'offline import feeds the existing demo transfer without automatically selecting',
    (tester) async {
      final model = NamModel.parse(
        File('test/fixtures/synthetic.nam').readAsBytesSync(),
        'BassClean.nam',
      );
      final tone = TonePack(
        id: 7,
        title: 'Bass Full Rig',
        gear: 'amp-cab',
        creator: ToneCreator('creator', null),
        image: null,
      );
      final imported = ImportedTone(
        tone,
        ToneModel(
          11,
          7,
          'Bass Clean',
          Uri.https('www.tone3000.com', '/api/v1/models/11/download'),
        ),
        model,
      );
      await tester.pumpWidget(
        MaterialApp(home: ModelPage(pickTone: (_) async => imported)),
      );
      await tester.ensureVisible(find.text('TONE3000から探す'));
      await tester.tap(find.text('TONE3000から探す'));
      await tester.pumpAndSettle();
      expect(find.text('Bass Full Rig'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('接続せず試す'), 180);
      await tester.tap(find.text('接続せず試す'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('03'), 180);
      final card = find.ancestor(
        of: find.text('03'),
        matching: find.byType(Card),
      );
      final upload = find.descendant(of: card, matching: find.text('ここへ転送'));
      await tester.ensureVisible(upload);
      await tester.pumpAndSettle();
      await tester.tap(upload);
      // The simulated radio has a timer per chunk; advance all chunks even
      // when no animation frame is scheduled between acknowledgements.
      for (
        var i = 0;
        i < 150 &&
            find
                .descendant(of: card, matching: find.text('BassClean'))
                .evaluate()
                .isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
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
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
