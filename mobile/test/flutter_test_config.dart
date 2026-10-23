import 'dart:async';

import 'package:fb200_nam/localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // Existing behavioral fixtures use Japanese. Language tests explicitly
  // override this baseline and verify the production default is English.
  setUp(() {
    AppText.language = AppLanguage.japanese;
    SharedPreferences.setMockInitialValues({'app_language': 'ja'});
  });
  await testMain();
}
