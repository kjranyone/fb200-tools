import 'localization.dart';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'model_page.dart';
import 'studio_theme.dart';

void main() => runApp(const MainApp());

class MainApp extends StatefulWidget {
  const MainApp({super.key});
  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> {
  static const languageKey = 'app_language';
  SharedPreferences? _preferences;
  AppLanguage _language = AppLanguage.english;
  bool _ready = false, _savingLanguage = false;
  final _messenger = GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    _loadLanguage();
  }

  Future<void> _loadLanguage() async {
    var language = AppLanguage.english;
    try {
      final preferences = await SharedPreferences.getInstance();
      _preferences = preferences;
      language = AppLanguage.fromCode(preferences.getString(languageKey));
    } catch (_) {
      // Storage failure must not prevent connecting to the pedal.
    }
    if (!mounted) return;
    setState(() {
      _language = AppText.language = language;
      _ready = true;
    });
  }

  Future<void> _changeLanguage(AppLanguage language) async {
    if (_savingLanguage || language == _language) return;
    setState(() => _savingLanguage = true);
    try {
      final preferences = _preferences ??=
          await SharedPreferences.getInstance();
      if (!await preferences.setString(languageKey, language.code)) {
        throw StateError('Language preference not saved');
      }
      if (!mounted) return;
      setState(() => _language = AppText.language = language);
    } catch (_) {
      if (mounted) {
        _messenger.currentState?.showSnackBar(
          SnackBar(content: Text(tr('言語設定を保存できませんでした。もう一度お試しください。'))),
        );
      }
    } finally {
      if (mounted) setState(() => _savingLanguage = false);
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'FB200 Studio',
    scaffoldMessengerKey: _messenger,
    debugShowCheckedModeBanner: false,
    theme: StudioTheme.theme,
    locale: _language.locale,
    supportedLocales: AppLanguage.values.map((language) => language.locale),
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: !_ready
        ? const Scaffold(body: Center(child: CircularProgressIndicator()))
        : ModelPage(
            key: ValueKey(_language),
            language: _language,
            savingLanguage: _savingLanguage,
            onLanguageChanged: _changeLanguage,
          ),
  );
}
