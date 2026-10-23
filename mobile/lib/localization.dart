import 'dart:ui' show Locale;

import 'l10n/catalog.dart';

enum AppLanguage {
  english('en', 'English', Locale('en')),
  japanese('ja', '日本語', Locale('ja')),
  simplifiedChinese(
    'zh-Hans',
    '简体中文',
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
  );

  final String code, nativeName;
  final Locale locale;
  const AppLanguage(this.code, this.nativeName, this.locale);

  static AppLanguage fromCode(String? code) => values.firstWhere(
    (language) => language.code == code,
    orElse: () => english,
  );
}

/// The app has one language, including asynchronous transport/model errors.
/// MainApp loads this before creating a page. Language can be changed only
/// at the disconnected launch screen, which recreates that page so retained
/// messages and metadata cannot keep the previous language.
abstract final class AppText {
  static AppLanguage language = AppLanguage.english;
}

/// Explicit source keys, never automatic matching against rendered text.
/// Placeholders are substituted once, preserving arbitrary device/user names.
String tr(String key, [List<Object?> arguments = const []]) {
  final values = translations[key];
  assert(values != null, 'Missing translation: $key');
  final template = switch (AppText.language) {
    AppLanguage.english => values?[0] ?? key,
    AppLanguage.japanese => key,
    AppLanguage.simplifiedChinese => values?[1] ?? key,
  };
  return template.replaceAllMapped(RegExp(r'\{(\d+)\}'), (match) {
    final index = int.parse(match[1]!);
    assert(index < arguments.length, 'Missing argument $index for $key');
    return index < arguments.length ? '${arguments[index]}' : match[0]!;
  });
}
