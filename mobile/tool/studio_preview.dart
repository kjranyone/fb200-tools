// Render real Flutter widgets against the in-memory device, with real fonts.
// Run explicitly: flutter test tool/studio_preview.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fb200_nam/studio_theme.dart';

import '../test/studio_test.dart' show studio;
import '../test/support/studio_harness.dart';

void main() {
  testWidgets('render studio phone and tablet previews', (tester) async {
    final config = jsonDecode(
      File('.dart_tool/package_config.json').readAsStringSync(),
    ) as Map;
    final sdk = Uri.parse(config['flutterRoot'] as String).toFilePath();
    final fonts = '$sdk/bin/cache/artifacts/material_fonts';
    await tester.runAsync(() async {
      final loader = FontLoader('Roboto')
        ..addFont(
          File('$fonts/roboto-regular.ttf')
              .readAsBytes()
              .then(ByteData.sublistView),
        )
        ..addFont(
          File('$fonts/roboto-bold.ttf')
              .readAsBytes()
              .then(ByteData.sublistView),
        );
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(
          File('$fonts/materialicons-regular.otf')
              .readAsBytes()
              .then(ByteData.sublistView),
        );
      await icons.load();
      if (Platform.isWindows) {
        await (FontLoader('Yu Gothic')..addFont(
              File('${Platform.environment['WINDIR']}/Fonts/YuGothR.ttc')
                  .readAsBytes()
                  .then(ByteData.sublistView),
            ))
            .load();
      }
    });
    for (final (name, size) in [
      ('phone', const Size(390, 844)),
      ('tablet', const Size(1280, 800)),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final h = StudioHarness();
      final key = GlobalKey();
      final app = studio(h, openModels: () async {});
      final material = app as MaterialApp;
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: StudioTheme.theme.copyWith(
              textTheme: StudioTheme.theme.textTheme.apply(
                fontFamily: 'Roboto',
                fontFamilyFallback: ['Yu Gothic'],
              ),
            ),
            home: material.home,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      Future<void> capture(String suffix) => tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('../out/studio-previews/$name$suffix.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
      await capture('');
      await tester.ensureVisible(
        find.byKey(const ValueKey('choose-nam-model')),
      );
      await tester.tap(find.byKey(const ValueKey('choose-nam-model')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await capture('-picker');
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(h.close);
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
