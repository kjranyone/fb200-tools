import 'package:fb200_nam/tone3000.dart';
import 'package:fb200_nam/tone3000_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('QR accepts a trimmed public identifier and refuses other payloads', () {
    expect(parsePublishableKeyQr('  public-test_123\n'), 'public-test_123');
    for (final value in [
      '',
      't3k_cs_private',
      'https://example.com',
      '{"key":"public"}',
      'two keys',
      'abc\u0000def',
      'x' * 513,
    ]) {
      expect(() => parsePublishableKeyQr(value), throwsA(isA<ToneError>()));
    }
  });

  testWidgets('QR fills setup without starting OAuth or saving yet', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Tone3000Page(
          scanKey: (_) async => ' public-qr-key\n',
          apiFactory: (_) {
            calls++;
            throw StateError('must not authenticate');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('QRコードから入力'));
    await tester.tap(find.text('QRコードから入力'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'public-qr-key',
    );
    expect(calls, 0);
    expect(
      (await SharedPreferences.getInstance()).getString('tone3000_client_id'),
      isNull,
    );
  });

  for (final result in <String?>[
    null,
    't3k_cs_private',
    'https://example.com',
  ]) {
    testWidgets('cancel or invalid QR retains existing key: $result', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'tone3000_client_id': 'existing-public',
      });
      await tester.pumpWidget(
        MaterialApp(home: Tone3000Page(scanKey: (_) async => result)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('TONE3000連携設定'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('QRコードから入力'));
      await tester.tap(find.text('QRコードから入力'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'existing-public',
      );
      if (result != null) {
        expect(
          find.textContaining(
            result.startsWith('t3k_cs_') ? 'Secret Keyは使用できません' : '文字列を含むQRコード',
          ),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}
