import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'tone3000.dart';
import 'tone_key_scanner.dart';

typedef ToneApiFactory = Tone3000Api Function(String clientId);

class Tone3000Logo extends StatelessWidget {
  const Tone3000Logo({super.key});
  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/branding/tone3000.png',
    height: 32,
    alignment: Alignment.centerLeft,
    semanticLabel: 'TONE3000',
  );
}

class ToneAttribution extends StatelessWidget {
  final TonePack tone;
  const ToneAttribution(this.tone, {super.key});
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (tone.image != null) ...[
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.network(
            tone.image.toString(),
            width: 64,
            height: 64,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox(
              width: 64,
              height: 64,
              child: Icon(Icons.graphic_eq),
            ),
          ),
        ),
        const SizedBox(width: 12),
      ],
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tone.title, style: Theme.of(context).textTheme.titleMedium),
            Text('${tone.gearLabel} · NAM A2'),
            Text(
              '@${tone.creator.username}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    ],
  );
}

class Tone3000Page extends StatefulWidget {
  final ToneApiFactory? apiFactory;
  final ToneBrowser? browser;
  final Future<String?> Function(BuildContext)? scanKey;
  const Tone3000Page({super.key, this.apiFactory, this.browser, this.scanKey});
  @override
  State<Tone3000Page> createState() => _Tone3000PageState();
}

class _Tone3000PageState extends State<Tone3000Page> {
  static const _settingsKey = 'tone3000_client_id';
  final _key = TextEditingController();
  Tone3000Api? _api;
  ToneSelection? _selection;
  final _models = <ToneModel>[];
  int _page = 0, _totalPages = 0;
  bool _loadingSettings = true, _busy = false, _editing = false;
  String _error = '', _status = '', _notice = '';

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      _key.text =
          prefs.getString(_settingsKey) ??
          const String.fromEnvironment('TONE3000_CLIENT_ID');
    } catch (_) {
      if (!mounted) return;
      _key.text = const String.fromEnvironment('TONE3000_CLIENT_ID');
    }
    if (mounted) {
      setState(() {
        _loadingSettings = false;
        _editing = _key.text.isEmpty;
      });
    }
  }

  Future<void> _run(String label, Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = label;
      _error = '';
      _notice = '';
    });
    try {
      await action();
    } on ToneCancelled {
      _showCancellation();
    } on ToneError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on PlatformException catch (e) {
      if (e.code == 'CANCELED') {
        _showCancellation();
      } else if (mounted) {
        setState(() => _error = 'ブラウザーを開けませんでした。対応ブラウザーを確認してください。');
      }
    } catch (_) {
      if (mounted) setState(() => _error = '取得できませんでした。接続を確認して再試行してください。');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '';
        });
      }
    }
  }

  void _showCancellation() {
    if (mounted) {
      setState(
        () => _notice = 'TONE3000のログイン・トーン選択を中止しました。もう一度「TONE3000で探す」から続けられます。',
      );
    }
  }

  Future<Uri> _openBrowser(Uri url) async {
    final result = await const MethodChannel('dev.fb200/tone3000')
        .invokeMethod<String>('select', {'url': url.toString()});
    if (result == null) throw ToneCancelled();
    return Uri.parse(result);
  }

  Future<void> _browse() => _run('TONE3000でトーンを選択中', () async {
    final key = validatePublishableKey(_key.text);
    FocusManager.instance.primaryFocus?.unfocus();
    // Only the public application identifier is saved. Tokens remain in memory.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_settingsKey, key);
    if (!mounted) return;
    _api?.close();
    final api = (widget.apiFactory ?? Tone3000Api.new)(key);
    _api = api;
    setState(() {
      _selection = null;
      _models.clear();
      _editing = false;
    });
    final selection = await api.select(widget.browser ?? _openBrowser);
    if (!mounted) return;
    setState(() {
      _selection = selection;
      _models.addAll(selection.firstPage.models);
      _page = selection.firstPage.page;
      _totalPages = selection.firstPage.totalPages;
    });
  });

  Future<void> _scanKey() async {
    final value =
        await (widget.scanKey?.call(context) ??
            Navigator.push<String>(
              context,
              MaterialPageRoute(builder: (_) => const ToneKeyScanner()),
            ));
    if (!mounted || value == null) return;
    try {
      final key = parsePublishableKeyQr(value);
      setState(() {
        _key.text = key;
        _error = '';
      });
    } on ToneError catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _more() => _run('モデル一覧を読み込み中', () async {
    final page = await _api!.listModels(_selection!.tone.id, page: _page + 1);
    if (mounted) {
      setState(() {
        final ids = _models.map((m) => m.id).toSet();
        _models.addAll(page.models.where((m) => ids.add(m.id)));
        _page = page.page;
        _totalPages = page.totalPages;
      });
    }
  });

  Future<void> _import(ToneModel model) => _run('A2-Lite対応を確認中', () async {
    final imported = await _api!.download(_selection!.tone, model);
    if (mounted) Navigator.pop(context, imported);
  });

  @override
  void dispose() {
    _api?.close();
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('TONE3000から読み込む'),
      actions: [
        IconButton(
          tooltip: 'TONE3000連携設定',
          onPressed: _busy ? null : () => setState(() => _editing = !_editing),
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    ),
    bottomNavigationBar: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_busy) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(_status),
                  const SizedBox(height: 8),
                ],
                if (_error.isNotEmpty || _notice.isNotEmpty) ...[
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _error.isNotEmpty ? _error : _notice,
                      style: TextStyle(
                        color: _error.isNotEmpty
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                FilledButton.icon(
                  onPressed:
                      _busy ||
                          _loadingSettings ||
                          (!_supported && widget.browser == null)
                      ? null
                      : _browse,
                  icon: const Icon(Icons.travel_explore),
                  label: Text(_selection == null ? 'TONE3000で探す' : '別のトーンを探す'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Tone3000Logo(),
              const SizedBox(height: 20),
              const Text(
                '世界のキャプチャを、FB200へ。',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              const Text('Publishable Keyはアプリを識別するキーです。キーの設定だけではログインは完了しません。'),
              const SizedBox(height: 8),
              const Text(
                '「TONE3000で探す」を押すとログイン画面が開きます。TONE3000に登録したメールアドレスを入力し、Send Codeで届くコードを使ってログインすると、トーンを選べます。',
              ),
              if (_loadingSettings) const LinearProgressIndicator(),
              if (_editing && !_loadingSettings) ...[
                const SizedBox(height: 20),
                const Text(
                  '連携の初期設定',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'TONE3000のSettings → API Keysにある公開キーを設定します。Redirect URIを登録する場合は次の値を指定してください。',
                ),
                const SizedBox(height: 8),
                const SelectableText(toneCallback),
                const SizedBox(height: 12),
                TextField(
                  controller: _key,
                  enabled: !_busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.go,
                  onSubmitted:
                      _busy ||
                          _loadingSettings ||
                          (!_supported && widget.browser == null)
                      ? null
                      : (_) => _browse(),
                  decoration: const InputDecoration(
                    labelText: 'Publishable Key（client_id）',
                    helperText: 'Secret Keyは入力しないでください。',
                  ),
                ),
                if (_supported || widget.scanKey != null)
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _scanKey,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('QRコードから入力'),
                  ),
                TextButton(
                  onPressed: () => launchUrl(
                    Uri.https('www.tone3000.com', '/settings'),
                    mode: LaunchMode.externalApplication,
                  ),
                  child: const Text('TONE3000の設定を開く'),
                ),
              ],
              if (!_supported && widget.browser == null)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Text(
                    'TONE3000連携はAndroidアプリで利用できます。Webデモではローカルファイルを選択してください。',
                  ),
                ),
              const SizedBox(height: 20),
              if (_selection != null) ...[
                const SizedBox(height: 24),
                Row(
                  children: [
                    CircleAvatar(
                      backgroundImage: _selection!.account.avatar == null
                          ? null
                          : NetworkImage(_selection!.account.avatar.toString()),
                      child: _selection!.account.avatar == null
                          ? const Icon(Icons.person_outline)
                          : null,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('@${_selection!.account.username} でログイン中'),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                ToneAttribution(_selection!.tone),
                if (_selection!.tone.description.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _selection!.tone.description,
                      maxLines: 6,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                const SizedBox(height: 16),
                const Text(
                  'モデルを選択',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Text('取得後に48 kHz・固定A2-Lite構成を確認します。取り込みだけでは本体へ送信されません。'),
                const SizedBox(height: 12),
                for (final model in _models)
                  Card(
                    child: ListTile(
                      title: Text(model.name),
                      subtitle: const Text('NAM A2'),
                      trailing: const Icon(Icons.download_outlined),
                      enabled: !_busy,
                      onTap: () => _import(model),
                    ),
                  ),
                if (_models.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('A2モデルがありません。別のトーンを選択してください。'),
                  ),
                if (_page < _totalPages)
                  OutlinedButton(
                    onPressed: _busy ? null : _more,
                    child: const Text('さらに読み込む'),
                  ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
