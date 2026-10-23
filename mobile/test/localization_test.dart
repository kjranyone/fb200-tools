import 'package:fb200_nam/effect_parameters.dart';
import 'package:fb200_nam/l10n/catalog.dart';
import 'package:fb200_nam/localization.dart';
import 'package:fb200_nam/main.dart';
import 'package:fb200_nam/model_page.dart';
import 'package:fb200_nam/pedal_client.dart';
import 'package:fb200_nam/widgets/chain_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'studio_test.dart' show studio;
import 'support/studio_harness.dart';

Future<void> chooseLanguage(WidgetTester tester, AppLanguage language) async {
  await tester.tap(find.byType(DropdownButtonFormField<AppLanguage>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(language.nativeName).last);
  await tester.pumpAndSettle();
}

void main() {
  test('every message has complete translations and matching placeholders', () {
    final placeholders = RegExp(r'\{\d+\}');
    Set<String> slots(String text) =>
        placeholders.allMatches(text).map((match) => match[0]!).toSet();
    expect(translations.length, greaterThanOrEqualTo(446));
    for (final entry in translations.entries) {
      expect(entry.value.length, 2, reason: entry.key);
      for (final text in entry.value) {
        expect(text.trim(), isNotEmpty, reason: entry.key);
        expect(slots(text), slots(entry.key), reason: entry.key);
      }
      expect(
        RegExp(r'[ぁ-んァ-ヶ一-龠]').hasMatch(entry.value[0]),
        isFalse,
        reason: entry.key,
      );
    }
  });

  test(
    'substitution preserves model names including placeholder-like text',
    () {
      for (final language in AppLanguage.values) {
        AppText.language = language;
        const first = '日本語 {1} / 中文', second = 'IR {0} “Bass”';
        final message = tr(
          '「{0}」を「{1}」に置き換えます。このスロットを使う他のプリセットも、次回の読み込みから新しいモデルを使用します。',
          [first, second],
        );
        expect(message, contains(first));
        expect(message, contains(second));
        expect(
          EffectParameters.cabName(11, [IrSlotInfo(1, true, first)]),
          'IR1 · $first',
        );
      }
    },
  );

  testWidgets('first launch is English even on a Japanese device', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.platformDispatcher.localeTestValue = const Locale('ja');
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    await tester.pumpWidget(const MainApp());
    await tester.pumpAndSettle();
    expect(find.text('Language'), findsOneWidget);
    expect(find.text('Connect your FB200'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    final context = tester.element(find.byType(ModelPage));
    expect(Localizations.localeOf(context), const Locale('en'));
    expect(MaterialLocalizations.of(context).cancelButtonLabel, 'Cancel');
  });

  testWidgets('all three choices persist after a full app remount', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MainApp());
    await tester.pumpAndSettle();
    for (final (language, title, materialCancel) in [
      (AppLanguage.japanese, 'FB200を接続', 'キャンセル'),
      (AppLanguage.simplifiedChinese, '连接 FB200', '取消'),
      (AppLanguage.english, 'Connect your FB200', 'Cancel'),
    ]) {
      await chooseLanguage(tester, language);
      expect(find.text(title), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getString('app_language'),
        language.code,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(const MainApp());
      await tester.pumpAndSettle();
      expect(find.text(title), findsOneWidget);
      expect(find.text(language.nativeName), findsOneWidget);
      final context = tester.element(find.byType(ModelPage));
      expect(Localizations.localeOf(context), language.locale);
      expect(
        MaterialLocalizations.of(context).cancelButtonLabel,
        materialCancel,
      );
    }
  });

  testWidgets('unsupported stored locale falls back to English', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'app_language': 'fr'});
    await tester.pumpWidget(const MainApp());
    await tester.pumpAndSettle();
    expect(find.text('Language'), findsOneWidget);
    expect(find.text('Connect your FB200'), findsOneWidget);
  });

  for (final language in AppLanguage.values) {
    for (final size in [
      const Size(360, 640),
      const Size(640, 360),
      const Size(1280, 800),
    ]) {
      testWidgets('${language.code} launch and all effect layouts at $size', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({'app_language': language.code});
        await tester.pumpWidget(const MainApp());
        await tester.pumpAndSettle();
        expect(find.text(language.nativeName), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byType(DropdownButtonFormField<AppLanguage>));
        await tester.pumpAndSettle();
        expect(find.text('English'), findsWidgets);
        expect(find.text('日本語'), findsWidgets);
        expect(find.text('简体中文'), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());

        final harness = StudioHarness();
        await tester.pumpWidget(studio(harness));
        await tester.pumpAndSettle();
        for (var module = 0; module < 7; module++) {
          if (find.byType(ChainStrip).evaluate().isNotEmpty) {
            final chain = tester.widget<ChainStrip>(find.byType(ChainStrip));
            chain.onTap(chain.order.indexOf(module));
          } else {
            final menu = tester.widget<PopupMenuButton<int>>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is PopupMenuButton<int> &&
                    widget.tooltip == tr('エフェクトを選ぶ'),
              ),
            );
            menu.onSelected!(module);
          }
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: '${language.code} module $module at $size',
          );
        }
        expect(find.text(tr('リバーブ')), findsWidgets);
        tester
            .widget<PopupMenuButton<int>>(
              find.byType(PopupMenuButton<int>).first,
            )
            .onSelected!(-2);
        await tester.pumpAndSettle();
        expect(find.text(tr('音作りの操作')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text(tr('閉じる')));
        await tester.pumpAndSettle();
        for (final tab in ['プリセット', 'ドラム', 'チューナー', 'ルーパー', 'IR', '設定']) {
          await tester.tap(find.text(tab == 'IR' ? tab : tr(tab)).last);
          await tester.pumpAndSettle();
          final error = tester.takeException();
          expect(
            error,
            isNull,
            reason: '${language.code} tab $tab at $size: $error',
          );
        }
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(harness.close);
      });
    }
  }
}
