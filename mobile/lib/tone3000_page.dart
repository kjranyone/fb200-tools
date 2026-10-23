import 'localization.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'tone3000.dart';
import 'tone_key_scanner.dart';
import 'tone_library.dart';
import 'tone3000/library_view.dart';
import 'tone3000/tone_sheet.dart';
import 'tone3000/widgets.dart';

typedef ToneApiFactory = Tone3000Api Function(String clientId);

const _gears = ['amp', 'amp-cab', 'pedal', 'outboard', 'cab'];

/// TONE3000 browsing, bulk download into the device library, and selection
/// of stored models. Returns the models chosen for transfer; never writes to
/// the pedal itself.
class Tone3000Page extends StatefulWidget {
  final ToneApiFactory? apiFactory;
  final ToneBrowser? browser;
  final Future<String?> Function(BuildContext)? scanKey;
  final ToneLibrary? library;

  /// Empty slots on the connected pedal; null when transfer is unavailable.
  final int? freeSlots;
  const Tone3000Page({
    super.key,
    this.apiFactory,
    this.browser,
    this.scanKey,
    this.library,
    this.freeSlots,
  });
  @override
  State<Tone3000Page> createState() => _Tone3000PageState();
}

class _Tone3000PageState extends State<Tone3000Page>
    with SingleTickerProviderStateMixin {
  static const _settingsKey = 'tone3000_client_id';
  final _key = TextEditingController();
  final _remoteQuery = TextEditingController();
  late final TabController _tabs = TabController(length: 2, vsync: this)
    ..addListener(() => setState(() {}));
  late final ToneLibrary _library = widget.library ?? ToneLibrary.app;
  late final ToneDownloader _downloader = ToneDownloader(_library);
  Tone3000Api? _api;
  ToneCreator? _account;
  ToneShelf _shelf = ToneShelf.favorited;
  String? _gear;
  final _tones = <TonePack>[];
  int _page = 0, _totalPages = 0;
  bool _listed = false;
  String _localQuery = '';
  final _selected = <int>{};
  bool _loadingSettings = true, _busy = false, _editing = false;
  String _error = '', _status = '', _notice = '';

  bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get _canSignIn => _supported || widget.browser != null;
  bool get _working => _busy || _downloader.running;

  @override
  void initState() {
    super.initState();
    _library.addListener(_libraryChanged);
    _downloader.addListener(_libraryChanged);
    _start();
  }

  void _libraryChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    final library = _library.load();
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
    if (!mounted) return;
    setState(() {
      _loadingSettings = false;
      _editing = _key.text.isEmpty;
    });
    // Settings never wait on storage; the tab follows once the index loads.
    unawaited(
      library.then((_) {
        // A transfer visit starts where the stored models are.
        if (mounted &&
            widget.freeSlots != null &&
            _library.entries.isNotEmpty) {
          _tabs.index = 1;
        }
      }),
    );
    if (_key.text.isNotEmpty && _canSignIn) {
      await _run(tr("TONE3000のログイン状態を確認中"), () async {
        final api = _connect(validatePublishableKey(_key.text));
        final account = await api.restore();
        if (!mounted || account == null) return;
        setState(() => _account = account);
        await _list();
      });
    }
  }

  Tone3000Api _connect(String key) {
    if (_api case final api? when api.clientId == key) return api;
    _api?.close();
    return _api =
        widget.apiFactory?.call(key) ??
        Tone3000Api(key, sessions: const SecureToneSessionStore());
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
      if (mounted) {
        setState(() {
          _error = e.message;
          if (_api?.signedIn == false) _account = null;
        });
      }
    } on PlatformException catch (e) {
      if (e.code == 'CANCELED') {
        _showCancellation();
      } else if (mounted) {
        setState(() => _error = tr("ブラウザーを開けませんでした。対応ブラウザーを確認してください。"));
      }
    } catch (_) {
      if (mounted) setState(() => _error = tr("取得できませんでした。接続を確認して再試行してください。"));
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
        () => _notice = tr(
          "TONE3000のログイン・トーン選択を中止しました。もう一度「TONE3000で探す」から続けられます。",
        ),
      );
    }
  }

  Future<Uri> _openBrowser(Uri url) async {
    final result = await const MethodChannel('dev.fb200/tone3000')
        .invokeMethod<String>('select', {'url': url.toString()});
    if (result == null) throw ToneCancelled();
    return Uri.parse(result);
  }

  /// The official Select flow signs in and opens the full catalog.
  Future<void> _browse() => _run(tr("TONE3000でトーンを選択中"), () async {
    final key = validatePublishableKey(_key.text);
    FocusManager.instance.primaryFocus?.unfocus();
    // Only the public application identifier is saved here.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_settingsKey, key);
    if (!mounted) return;
    final api = _connect(key);
    setState(() => _editing = false);
    final selection = await api.select(widget.browser ?? _openBrowser);
    if (!mounted) return;
    final firstListing = !_listed;
    setState(() => _account = selection.account);
    final page = selection.firstPage;
    final models = page.totalPages > 1
        ? await api.listAllModels(selection.tone.id)
        : page.models;
    if (firstListing) {
      try {
        await _list();
      } on ToneError {
        // The chosen tone still opens; the list can be reloaded later.
      }
    }
    if (mounted) unawaited(_openTone(selection.tone, models));
  });

  Future<void> _refreshList() => _run(tr("トーン一覧を読み込み中"), _list);

  Future<void> _list({bool more = false}) async {
    final api = _api;
    if (api == null || !api.signedIn) return;
    final result = await api.listTones(
      _shelf,
      query: _remoteQuery.text,
      gear: _gear,
      page: more ? _page + 1 : 1,
    );
    if (!mounted) return;
    setState(() {
      if (!more) _tones.clear();
      final ids = _tones.map((t) => t.id).toSet();
      _tones.addAll(result.tones.where((t) => ids.add(t.id)));
      _page = result.page;
      _totalPages = result.totalPages;
      _listed = true;
    });
  }

  Future<void> _signOut() async {
    await _api?.signOut();
    if (!mounted) return;
    setState(() {
      _account = null;
      _tones.clear();
      _listed = false;
      _notice = tr("TONE3000からログアウトしました。端末に保存したモデルはそのまま使えます。");
    });
  }

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

  Future<void> _showTone(TonePack tone) => _run(tr("モデル一覧を読み込み中"), () async {
    final models = await _api!.listAllModels(tone.id);
    if (mounted) unawaited(_openTone(tone, models));
  });

  Future<void> _openTone(TonePack tone, List<ToneModel> models) async {
    final choice = await showModalBottomSheet<ToneChoice>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: .9,
        child: ToneSheet(
          tone: tone,
          models: models,
          library: _library,
          canTransfer: widget.freeSlots != null,
        ),
      ),
    );
    if (choice == null || !mounted) return;
    await _download([ToneDownloadJob(tone, choice.models)]);
    if (!choice.transfer || !mounted) return;
    final stored = {for (final e in _library.entries) e.variant.id: e};
    final entries = [for (final model in choice.models) ?stored[model.id]];
    // Nothing compatible: keep the download summary on screen.
    if (entries.isNotEmpty) await _finish(entries);
  }

  Future<void> _download(List<ToneDownloadJob> jobs) async {
    final api = _api;
    if (api == null || _downloader.running) return;
    setState(() {
      _error = '';
      _notice = '';
    });
    try {
      await _downloader.run(api, jobs);
    } catch (_) {
      if (mounted) setState(() => _error = tr("ダウンロードを完了できませんでした。"));
    }
    if (!mounted) return;
    final d = _downloader;
    setState(() {
      if (!api.signedIn) _account = null;
      _notice = tr("端末に保存 {0} 件 · 保存済み {1} 件 · FB200対応外 {2} 件", [
        d.saved,
        d.existing,
        d.incompatible,
      ]);
      if (d.failed > 0) {
        _error = tr("{0} 件を取得できませんでした。{1}", [d.failed, d.lastError]);
      }
    });
  }

  Future<void> _downloadShown() async {
    final tones = _tones
        .where(
          (t) => t.a2Count == null || _library.storedFor(t.id) < t.a2Count!,
        )
        .toList();
    if (tones.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr("まとめてダウンロード")),
        content: Text(
          tr("表示中の {0} 件のトーンから、FB200で使えるA2モデルをすべて端末に保存します。保存済みのモデルは再取得しません。", [
            tones.length,
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr("キャンセル")),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr("ダウンロード")),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await _download([for (final tone in tones) ToneDownloadJob(tone)]);
    }
  }

  Future<void> _finish(List<LibraryEntry> entries) =>
      _run(tr("A2-Lite対応を確認中"), () async {
        final imported = [for (final e in entries) await _library.open(e)];
        if (imported.isNotEmpty && mounted) Navigator.pop(context, imported);
      });

  Future<void> _deleteSelected() async {
    final ids = _selected.toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr("端末から削除")),
        content: Text(
          tr("選択した {0} 件を端末から削除します。本体に転送済みのモデルは削除されません。", [ids.length]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr("キャンセル")),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr("削除")),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run(tr("削除中"), () async {
      await _library.remove(ids);
      if (mounted) setState(_selected.clear);
    });
  }

  @override
  void dispose() {
    _downloader.cancel();
    _library.removeListener(_libraryChanged);
    _downloader.removeListener(_libraryChanged);
    _downloader.dispose();
    _api?.close();
    _key.dispose();
    _remoteQuery.dispose();
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_downloader.running,
    onPopInvokedWithResult: (popped, _) {
      if (!popped) {
        setState(() => _notice = tr("ダウンロード中です。中止してから戻ってください。"));
      }
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(tr("TONE3000から読み込む")),
        actions: [
          if (_tabs.index == 0 && _account != null && _tones.isNotEmpty)
            IconButton(
              tooltip: tr("表示中のトーンをまとめてダウンロード"),
              onPressed: _working ? null : _downloadShown,
              icon: const Icon(Icons.download_for_offline_outlined),
            ),
          IconButton(
            tooltip: tr("TONE3000連携設定"),
            onPressed: _working
                ? null
                : () => setState(() {
                    _editing = !_editing;
                    _tabs.index = 0;
                  }),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            const Tab(text: 'TONE3000'),
            Tab(text: tr("端末（{0}）", [_library.entries.length])),
          ],
        ),
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
                children: _footer(),
              ),
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: TabBarView(controller: _tabs, children: [_remote(), _local()]),
      ),
    ),
  );

  List<Widget> _footer() => [
    if (_downloader.running) ...[
      LinearProgressIndicator(
        value: _downloader.total == 0
            ? null
            : _downloader.finished / _downloader.total,
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: Text(
              tr("ダウンロード中 {0}/{1} · {2}", [
                _downloader.finished,
                _downloader.total,
                _downloader.current,
              ]),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: _downloader.cancelling ? null : _downloader.cancel,
            child: Text(tr("中止")),
          ),
        ],
      ),
      const SizedBox(height: 8),
    ] else if (_busy) ...[
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
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: _error.isNotEmpty
                ? Theme.of(context).colorScheme.error
                : null,
          ),
        ),
      ),
      const SizedBox(height: 8),
    ],
    if (_tabs.index == 0)
      FilledButton.icon(
        onPressed: _working || _loadingSettings || !_canSignIn ? null : _browse,
        icon: const Icon(Icons.travel_explore),
        label: Text(_account == null ? tr("TONE3000で探す") : tr("全カタログから選ぶ")),
      )
    else if (_selected.isNotEmpty)
      Row(
        children: [
          IconButton(
            tooltip: tr("端末から削除"),
            onPressed: _working ? null : _deleteSelected,
            icon: const Icon(Icons.delete_outline),
          ),
          Expanded(
            child: FilledButton.icon(
              onPressed: _working || widget.freeSlots == null
                  ? null
                  : () => _finish([
                      for (final e in _library.entries)
                        if (_selected.contains(e.variant.id)) e,
                    ]),
              icon: const Icon(Icons.upload_outlined),
              label: Text(
                widget.freeSlots == null
                    ? tr("本体に接続すると転送できます")
                    : tr("{0} 件を転送へ（空き {1}）", [
                        _selected.length,
                        widget.freeSlots,
                      ]),
              ),
            ),
          ),
        ],
      ),
  ];

  // ---- TONE3000 tab: sign-in, free-tier lists, bulk download ----

  Widget _remote() => ToneScroll([
    if (_account == null) ..._intro() else ..._browser(),
    if (_editing && !_loadingSettings) ..._setup(),
    if (!_canSignIn)
      Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Text(
          tr("TONE3000連携はAndroidアプリで利用できます。Webデモではローカルファイルを選択してください。"),
        ),
      ),
  ]);

  List<Widget> _intro() => [
    const Tone3000Logo(),
    const SizedBox(height: 20),
    Text(
      tr("世界のキャプチャを、FB200へ。"),
      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
    ),
    const SizedBox(height: 12),
    Text(tr("Publishable Keyはアプリを識別するキーです。キーの設定だけではログインは完了しません。")),
    const SizedBox(height: 8),
    Text(
      tr(
        "「TONE3000で探す」を押すとログイン画面が開きます。TONE3000に登録したメールアドレスを入力し、Send Codeで届くコードを使ってログインすると、トーンを選べます。",
      ),
    ),
    const SizedBox(height: 8),
    Text(tr("ログインはこの端末に保存され、次回からはお気に入りやダウンロード履歴をすぐに表示します。")),
    if (_loadingSettings) const LinearProgressIndicator(),
  ];

  List<Widget> _setup() => [
    const SizedBox(height: 20),
    Text(tr("連携の初期設定"), style: const TextStyle(fontWeight: FontWeight.bold)),
    const SizedBox(height: 8),
    Text(
      tr(
        "TONE3000のSettings → API Keysにある公開キーを設定します。Redirect URIを登録する場合は次の値を指定してください。",
      ),
    ),
    const SizedBox(height: 8),
    const SelectableText(toneCallback),
    const SizedBox(height: 12),
    TextField(
      controller: _key,
      enabled: !_working,
      autocorrect: false,
      enableSuggestions: false,
      textInputAction: TextInputAction.go,
      onSubmitted: _working || _loadingSettings || !_canSignIn
          ? null
          : (_) => _browse(),
      decoration: InputDecoration(
        labelText: 'Publishable Key（client_id）',
        helperText: tr("Secret Keyは入力しないでください。"),
      ),
    ),
    if (_supported || widget.scanKey != null)
      OutlinedButton.icon(
        onPressed: _working ? null : _scanKey,
        icon: const Icon(Icons.qr_code_scanner),
        label: Text(tr("QRコードから入力")),
      ),
    TextButton(
      onPressed: () => launchUrl(
        Uri.https('www.tone3000.com', '/settings'),
        mode: LaunchMode.externalApplication,
      ),
      child: Text(tr("TONE3000の設定を開く")),
    ),
  ];

  String _shelfLabel(ToneShelf shelf) => switch (shelf) {
    ToneShelf.favorited => tr("お気に入り"),
    ToneShelf.downloaded => tr("ダウンロード履歴"),
    ToneShelf.created => tr("自分のトーン"),
    ToneShelf.trending => tr("トレンド"),
    ToneShelf.latest => tr("新着"),
    ToneShelf.search => tr("検索"),
  };

  List<Widget> _browser() => [
    Row(
      children: [
        const Tone3000Logo(),
        const Spacer(),
        TextButton(
          onPressed: _working ? null : _signOut,
          child: Text(tr("ログアウト")),
        ),
      ],
    ),
    const SizedBox(height: 8),
    Row(
      children: [
        CircleAvatar(
          radius: 14,
          backgroundImage: _account!.avatar == null
              ? null
              : NetworkImage(_account!.avatar.toString()),
          child: _account!.avatar == null
              ? const Icon(Icons.person_outline, size: 16)
              : null,
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(tr("@{0} でログイン中", [_account!.username]))),
      ],
    ),
    const SizedBox(height: 16),
    Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final shelf in ToneShelf.values)
          if (shelf != ToneShelf.search || toneSearchEnabled)
            ChoiceChip(
              label: Text(_shelfLabel(shelf)),
              selected: _shelf == shelf,
              onSelected: _working
                  ? null
                  : (_) {
                      setState(() => _shelf = shelf);
                      _refreshList();
                    },
            ),
      ],
    ),
    const SizedBox(height: 8),
    TextField(
      key: const ValueKey('tone-remote-query'),
      controller: _remoteQuery,
      enabled: !_busy,
      textInputAction: TextInputAction.search,
      onSubmitted: (_) => _refreshList(),
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search),
        hintText: _shelf == ToneShelf.search
            ? tr("キーワードで検索")
            : tr("このリストを絞り込み（名前・機材）"),
        isDense: true,
      ),
    ),
    const SizedBox(height: 8),
    Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final gear in [null, ..._gears])
          FilterChip(
            label: Text(gear == null ? tr("すべての機材") : TonePack.gearName(gear)),
            selected: _gear == gear,
            onSelected: _working
                ? null
                : (_) {
                    setState(() => _gear = gear);
                    _refreshList();
                  },
          ),
      ],
    ),
    const SizedBox(height: 12),
    for (final tone in _tones)
      ToneTile(
        tone: tone,
        stored: _library.storedFor(tone.id),
        enabled: !_working,
        onOpen: () => _showTone(tone),
        onDownload: () => _download([ToneDownloadJob(tone)]),
      ),
    if (_listed && _tones.isEmpty)
      Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          _shelf == ToneShelf.favorited
              ? tr(
                  "A2モデルのあるお気に入りがありません。「全カタログから選ぶ」でトーンを探すか、TONE3000でお気に入りに追加してください。",
                )
              : tr("A2モデルのあるトーンが見つかりません。"),
        ),
      ),
    if (_page < _totalPages)
      OutlinedButton(
        onPressed: _working
            ? null
            : () => _run(tr("トーン一覧を読み込み中"), () => _list(more: true)),
        child: Text(tr("さらに読み込む")),
      ),
  ];

  Widget _local() => ToneLibraryView(
    entries: _library.entries,
    query: _localQuery,
    selected: _selected,
    enabled: !_working,
    canTransfer: widget.freeSlots != null,
    onQuery: (value) => setState(() => _localQuery = value),
    onToggle: (id, value) =>
        setState(() => value ? _selected.add(id) : _selected.remove(id)),
  );
}
