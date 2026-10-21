import 'localization.dart';

import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ble_link.dart';
import 'connection_recovery.dart';
import 'widgets/recovery_layer.dart';
import 'nam_client.dart';
import 'nam_model.dart';
import 'pedal_client.dart';
import 'pedal_page.dart';
import 'protocol.dart';
import 'studio_theme.dart';
import 'tone3000.dart';
import 'tone3000_page.dart';
import 'widgets/nam_model_picker.dart';

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

class ModelPage extends StatefulWidget {
  final Future<ImportedTone?> Function(BuildContext)? pickTone;
  final AppLanguage? language;
  final bool savingLanguage;
  final Future<void> Function(AppLanguage)? onLanguageChanged;

  /// A library route borrows the controller's connection. It must never
  /// disconnect it when the library is closed.
  final NamClient? sharedClient;
  final DeviceState? initialState;
  final ConnectionRecovery? recovery;
  const ModelPage({
    super.key,
    this.pickTone,
    this.language,
    this.savingLanguage = false,
    this.onLanguageChanged,
    this.sharedClient,
    this.initialState,
    this.recovery,
  });
  @override
  State<ModelPage> createState() => _ModelPageState();
}

class _ModelPageState extends State<ModelPage> with WidgetsBindingObserver {
  final _connector = BleConnector();
  NamClient? _client;
  WireTransport? _wire;
  DeviceState? _state;
  NamModel? _model;
  ImportedTone? _toneSource;
  final _slotSources = <int, ImportedTone>{};
  bool _demo = false, _working = false, _cancel = false, _committing = false;
  ConnectionRecovery? _recovery;
  bool get _busy => _working || (_recovery != null && !_recovery!.connected);
  bool _showModels = false;
  String _deviceName = '', _operation = '', _message = '', _error = '';
  double? _progress;
  int? _lastUploaded;
  bool _showEmptySlots = false;

  bool get _libraryOnly => widget.sharedClient != null;

  @override
  void initState() {
    super.initState();
    if (!_libraryOnly) WidgetsBinding.instance.addObserver(this);
    _recovery = widget.recovery;
    _listenRecovery();
    if (_libraryOnly) {
      _client = widget.sharedClient;
      _state = widget.initialState;
      _showModels = true;
    }
  }

  Future<void> _run(String label, Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _working = true;
      _operation = label;
      _error = '';
      _message = '';
    });
    try {
      final transport = _wire ?? _client?.transport;
      if (transport is WireTransport) {
        final binding = transport.connectionGeneration;
        await transport.waitIdle();
        if (transport.isClosed || binding != transport.connectionGeneration) {
          throw DeviceError(tr("接続が切り替わりました。復旧後に操作をやり直してください。"));
        }
      }
      await action();
    } on TransferCancelled {
      if (mounted) setState(() => _message = tr("転送を中止しました。"));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _working = false;
          _progress = null;
          _committing = false;
        });
      }
    }
  }

  Future<void> _refresh({bool reuseSlots = false}) async {
    final client = _client;
    if (client == null) return;
    final value = await client.readState(reuse: reuseSlots);
    if (mounted && _client == client) setState(() => _state = value);
  }

  Future<void> _attach(
    RpcTransport transport,
    String name,
    bool demo, {
    Future<FrameLink> Function()? reopen,
  }) async {
    final client = NamClient(transport);
    try {
      if (transport is WireTransport) {
        final pedal = PedalClient(transport);
        try {
          await pedal.initialize();
        } finally {
          pedal.dispose();
        }
      }
      DeviceState? state;
      try {
        await client.handshake();
        state = await client.readState();
      } on DeviceError {
        if (transport is! WireTransport || transport.isClosed) rethrow;
        // Stock firmware supports the legacy editor but not NAM RPC.
      }
      if (transport is WireTransport && transport.isClosed) {
        throw DeviceError(tr("接続の確認中に通信が切れました。再接続してください。"));
      }
      if (!mounted) {
        await client.close();
        return;
      }
      setState(() {
        _client = state == null ? null : client;
        _wire = transport is WireTransport ? transport : null;
        _state = state;
        _demo = demo;
        _deviceName = name;
        if (transport is WireTransport && reopen != null) {
          _recovery = ConnectionRecovery(
            transport,
            reopen,
            cancelOpening: _connector.cancelPendingConnection,
          );
          _listenRecovery();
        }
        if (state == null) {
          _message = tr("本体コントロールを利用できます。NAMモデル管理には対応ファームウェアが必要です。");
        }
      });
    } catch (_) {
      await client.close();
      rethrow;
    }
  }

  Future<void> _connect() async {
    final device = await showModalBottomSheet<DiscoveredDevice>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DevicePicker(connector: _connector),
    );
    if (device == null || !mounted) return;
    await _run(tr("本体の対応状況を確認中"), () async {
      final transport = await _connector.connect(device.id);
      await _attach(
        transport,
        device.name.isEmpty ? 'FB200' : device.name,
        false,
        reopen: () => _connector.openLink(device.id),
      );
    });
  }

  Future<void> _disconnect() async {
    final client = _client;
    final wire = _wire;
    setState(() {
      _client = null;
      _wire = null;
      _state = null;
      _message = '';
      _error = '';
    });
    final recovery = _recovery;
    _unlistenRecovery();
    setState(() => _recovery = null);
    if (recovery != null) {
      await recovery.close();
      recovery.dispose();
    } else {
      await client?.close();
      if (client == null) await wire?.close();
    }
    _slotSources.clear();
  }

  Future<void> _import() => _run(tr("モデルを確認中"), () async {
    final file = await FilePicker.pickFile(type: FileType.any);
    if (file == null) return;
    const limit = 8 * 1024 * 1024;
    if ((await file.length() ?? 0) > limit) {
      throw FormatException(tr("8 MB以下の.namファイルを選択してください。"));
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream()) {
      if (bytes.length + chunk.length > limit) {
        throw FormatException(tr("8 MB以下の.namファイルを選択してください。"));
      }
      bytes.add(chunk);
    }
    final model = NamModel.parse(bytes.takeBytes(), file.name);
    if (mounted) {
      setState(() {
        _model = model;
        _toneSource = null;
        _message = tr("モデルを確認しました。転送先を選んでください。");
      });
    }
  });
  Future<void> _importTone() => _run(tr("TONE3000からモデルを取り込み中"), () async {
    final imported =
        await (widget.pickTone?.call(context) ??
            Navigator.push<ImportedTone>(
              context,
              MaterialPageRoute(builder: (_) => const Tone3000Page()),
            ));
    if (imported == null || !mounted) return;
    setState(() {
      _model = imported.model;
      _toneSource = imported;
      _message = tr("A2-Lite対応を確認しました。転送先を選んでください。");
    });
  });
  Future<bool> _confirm(String title, String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr("キャンセル")),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr("実行")),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> _upload(ModelSlot slot) async {
    final model = _model, client = _client;
    if (model == null || client == null || _busy) return;
    if (slot.name != null &&
        !await _confirm(
          tr("スロット {0} を上書き", [slot.number]),
          tr("「{0}」を「{1}」に置き換えます。このスロットを使う他のプリセットも、次回の読み込みから新しいモデルを使用します。", [
            slot.name,
            model.name,
          ]),
        )) {
      return;
    }
    if (!mounted || _client != client) return;
    await _run(tr("スロット {0} へ転送中", [slot.number]), () async {
      _cancel = false;
      _lastUploaded = null;
      setState(() => _progress = 0);
      await client.upload(
        slot.number,
        model,
        progress: (value) {
          if (mounted) setState(() => _progress = value);
        },
        cancelled: () => _cancel,
        committing: () {
          if (mounted) {
            setState(() {
              _committing = true;
              _operation = tr("本体への保存を確認中");
            });
          }
        },
      );
      final source = _toneSource;
      if (source == null) {
        _slotSources.remove(slot.number);
      } else {
        _slotSources[slot.number] = source;
      }
      await _refresh();
      if (mounted) {
        setState(() {
          _lastUploaded = slot.number;
          _message = tr("スロット {0} への転送が完了しました。", [slot.number]);
        });
      }
    });
  }

  Future<void> _chooseTransferSlot() async {
    final state = _state;
    if (_busy || _model == null || state == null) return;
    final slot = await pickNamModel(context, state, transfer: true);
    if (!mounted || slot == null) return;
    await _upload(state.slots.firstWhere((s) => s.number == slot));
  }

  Future<void> _select(int slot, {bool save = false}) => _run(
    save ? tr("プリセットへ保存中") : tr("モデルを切り替え中"),
    () async {
      await _client!.select(slot, save: save);
      await _refresh();
      _lastUploaded = null;
      if (mounted) {
        setState(
          () =>
              _message = save ? tr("現在のプリセットに選択を保存しました。") : tr("モデルを切り替えました。"),
        );
      }
    },
  );
  Future<void> _delete(ModelSlot slot) async {
    final client = _client;
    if (!await _confirm(
      tr("モデルを削除"),
      tr("スロット {0} の「{1}」を削除します。このモデルを使うプリセットは再設定が必要です。", [
        slot.number,
        slot.name,
      ]),
    )) {
      return;
    }
    if (!mounted || client == null || _client != client) return;
    await _run(tr("削除中"), () async {
      await client.delete(slot.number);
      _slotSources.remove(slot.number);
      await _refresh();
    });
  }

  Future<void> _renameSlot(ModelSlot slot) async {
    final client = _client;
    if (client == null || !mounted) return;
    final controller = TextEditingController(text: slot.name ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr("スロット {0} の名前", [slot.number])),
        content: TextField(
          controller: controller,
          maxLength: 23,
          decoration: InputDecoration(helperText: tr("半角英数字・記号（空白なし）で1〜23文字")),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr("キャンセル")),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(tr("変更")),
          ),
        ],
      ),
    );
    // The dialog route is still animating out when its Future completes.
    Future<void>.delayed(const Duration(milliseconds: 500), controller.dispose);
    if (name == null || name.isEmpty || !mounted || _client != client) return;
    await _run(tr("名前を変更中"), () async {
      await client.rename(slot.number, name);
      await _refresh();
      if (mounted) {
        setState(() => _message = tr("スロット {0} の名前を変更しました。", [slot.number]));
      }
    });
  }

  void _listenRecovery() {
    _recovery?.addListener(_connectionChanged);
    _recovery?.addResynchronizer(_resynchronize);
  }

  void _unlistenRecovery() {
    _recovery?.removeListener(_connectionChanged);
    _recovery?.removeResynchronizer(_resynchronize);
  }

  void _connectionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _resynchronize() async {
    if (!mounted) return;
    if (_wire case final wire?) {
      final pedal = PedalClient(wire);
      try {
        await pedal.initialize();
      } finally {
        pedal.dispose();
      }
    }
    if (_client case final client?) {
      await client.handshake();
      await _refresh(reuseSlots: true);
    }
    if (mounted) {
      setState(() {
        _error = '';
        _lastUploaded = null;
        _message = tr("再接続しました。本体の状態を読み直しました。中断した転送・保存は再実行していません。");
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_libraryOnly) {
      _recovery?.setForeground(state == AppLifecycleState.resumed);
    }
  }

  @override
  void dispose() {
    _unlistenRecovery();
    if (!_libraryOnly) {
      WidgetsBinding.instance.removeObserver(this);
      if (_recovery != null) {
        _recovery!.dispose();
      } else {
        unawaited(_client?.close() ?? _wire?.close());
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_working,
    child: Scaffold(
      appBar: AppBar(
        title: Text(_showModels ? 'NAM LIBRARY' : 'FB200 STUDIO'),
        leading: _showModels
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _working
                    ? null
                    : () {
                        if (_libraryOnly) {
                          Navigator.pop(context);
                        } else {
                          setState(() => _showModels = false);
                        }
                      },
              )
            : null,
        actions: [
          if (!_showModels && (_client != null || _wire != null)) ...[
            IconButton(
              tooltip: tr("一覧を更新"),
              onPressed: _busy ? null : () => _run(tr("一覧を更新中"), _refresh),
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: tr("接続を終了"),
              onPressed: _working ? null : _disconnect,
              icon: const Icon(Icons.link_off),
            ),
          ],
          if (_showModels)
            IconButton(
              tooltip: tr("一覧を更新"),
              onPressed: _busy ? null : () => _run(tr("一覧を更新中"), _refresh),
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      bottomNavigationBar:
          _showModels && (_busy || _message.isNotEmpty || _error.isNotEmpty)
          ? SafeArea(
              top: false,
              child: Center(
                heightFactor: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 680,
                    maxHeight: 210,
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ..._statusArea(),
                        if (_lastUploaded != null && !_busy) ...[
                          const SizedBox(height: 8),
                          FilledButton.icon(
                            onPressed: () => _select(_lastUploaded!),
                            icon: const Icon(Icons.play_arrow),
                            label: Text(tr("ロードして試聴")),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            )
          : null,
      body: RecoveryLayer(
        recovery: _recovery,
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: _showModels ? _modelsView() : _hubView(),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  // ---- hub (main page): connection + entry points ----

  List<Widget> _hubView() => [
    const SizedBox(height: 8),
    if (_client == null &&
        _wire == null &&
        widget.onLanguageChanged != null) ...[
      Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: DropdownButtonFormField<AppLanguage>(
            key: ValueKey((widget.language, widget.savingLanguage)),
            initialValue: widget.language,
            decoration: InputDecoration(
              labelText: tr('言語'),
              prefixIcon: const Icon(Icons.language),
            ),
            isExpanded: true,
            items: [
              for (final language in AppLanguage.values)
                DropdownMenuItem(
                  value: language,
                  child: Text(language.nativeName),
                ),
            ],
            onChanged: _busy || widget.savingLanguage
                ? null
                : (language) {
                    if (language != null) widget.onLanguageChanged!(language);
                  },
          ),
        ),
      ),
      const SizedBox(height: 20),
    ],
    if (_client == null && _wire == null) ...[
      _card([
        const Text(
          'YOUR TONE.\nUNDER CONTROL.',
          style: TextStyle(
            fontSize: 30,
            height: 1.2,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'NAM A2 LITE  /  MULTI EFFECTS',
          style: TextStyle(
            color: StudioTheme.nam,
            letterSpacing: 1.4,
            fontSize: 11,
          ),
        ),
        const SizedBox(height: 24),
        const SizedBox(height: 12),
        Text(
          tr("FB200を接続"),
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(tr("本体の操作とモデル管理を利用できます。接続中は公式アプリを閉じてください。")),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: !_busy && _connector.supported ? _connect : null,
          icon: const Icon(Icons.bluetooth_searching),
          label: Text(tr("Bluetoothで接続")),
        ),
        if (!_connector.supported)
          Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(tr("Bluetooth接続はAndroid / iOSアプリで利用できます。")),
          ),
        TextButton(
          onPressed: _busy
              ? null
              : () => _run(
                  tr("デモを準備中"),
                  () => _attach(DemoTransport(), 'Demo FB200', true),
                ),
          child: Text(tr("接続せず試す")),
        ),
      ]),
    ] else ...[
      _card([
        Row(
          children: [
            Icon(_demo ? Icons.science_outlined : Icons.bluetooth_connected),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _deviceName,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            Chip(label: Text(_demo ? 'DEMO' : tr("接続中"))),
          ],
        ),
        if (_demo) Text(tr("画面の体験用です。本体への転送・音声処理は行いません。")),
        const SizedBox(height: 12),
        if (_wire != null)
          FilledButton.icon(
            onPressed: _busy
                ? null
                : () => _run(tr("コントローラーを開いています"), () async {
                    await Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PedalPage(
                          transport: _wire!,
                          recovery: _recovery,
                          restrictedNam: _client != null,
                          toolsAvailable:
                              _client == null ||
                              (_client!.capabilityFlags & 8) != 0,
                          effectsAvailable:
                              _client == null ||
                              (_client!.capabilityFlags & 128) != 0,
                          btAudioAvailable:
                              _client == null ||
                              (_client!.capabilityFlags & 256) != 0,
                          onOpenModels: _client == null
                              ? null
                              : () async {
                                  await _refresh();
                                  if (!mounted) return;
                                  await Navigator.push<void>(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => ModelPage(
                                        sharedClient: _client,
                                        recovery: _recovery,
                                        initialState: _state,
                                        pickTone: widget.pickTone,
                                      ),
                                    ),
                                  );
                                },
                          namClient: _client,
                          namState: _state,
                          namModel: _state?.slots
                              .where((s) => s.number == _state!.selected)
                              .map((s) => s.name)
                              .firstOrNull,
                        ),
                      ),
                    );
                    await _wire?.waitIdle();
                    if (_client != null && mounted) await _refresh();
                  }),
            icon: const Icon(Icons.tune),
            label: Text(tr("コントローラー")),
          ),
        if (_client != null)
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () => _run(tr("モデル一覧を読み込み中"), () async {
                    await _refresh();
                    if (mounted) setState(() => _showModels = true);
                  }),
            icon: const Icon(Icons.library_music),
            label: Text(
              tr("モデル管理（{0}/{1}）", [
                _state?.slots.where((s) => s.name != null).length ?? 0,
                _client!.slotCount,
              ]),
            ),
          ),
      ]),
    ],
    if (_recovery?.draft != null)
      Padding(
        padding: EdgeInsets.only(top: 12),
        child: Text(tr("未保存の下書きを保持しています。コントローラーで確認できます。")),
      ),
    ..._statusArea(),
  ];

  // ---- model management view: import + slots ----

  List<Widget> _modelsView() => [
    _modelCard(),
    const SizedBox(height: 20),
    if (_state != null) ...[
      Text(
        tr("本体のモデル（{0}/{1} 使用中）", [
          _state!.slots.where((s) => s.name != null).length,
          _client!.slotCount,
        ]),
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 12),
      FilterChip(
        label: Text(tr("空きスロットも表示")),
        selected: _showEmptySlots,
        onSelected: _busy
            ? null
            : (value) => setState(() => _showEmptySlots = value),
      ),
      const SizedBox(height: 12),
      for (final slot in _state!.slots.where(
        (s) => _showEmptySlots || s.name != null,
      )) ...[_slotCard(slot), const SizedBox(height: 10)],
      TextButton(
        onPressed: _busy || _state!.selected == 0 ? null : () => _select(0),
        child: Text(tr("NAMをバイパス")),
      ),
      FilledButton.tonal(
        onPressed: _busy ? null : () => _select(_state!.selected, save: true),
        child: Text(tr("現在の選択をプリセットに保存")),
      ),
    ],
  ];

  // ---- shared status / progress / messages ----

  List<Widget> _statusArea() => [
    if (_busy) ...[
      const SizedBox(height: 20),
      LinearProgressIndicator(value: _progress),
      const SizedBox(height: 8),
      Text(_operation),
      if (_progress != null)
        Row(
          children: [
            Text('${(_progress! * 100).round()}%'),
            const Spacer(),
            TextButton(
              onPressed: _committing || _cancel
                  ? null
                  : () => setState(() => _cancel = true),
              child: Text(tr("転送を中止")),
            ),
          ],
        ),
    ],
    if (_message.isNotEmpty)
      Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Text(_message, style: const TextStyle(color: Color(0xff74e5bd))),
      ),
    if (_error.isNotEmpty)
      Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Text(
          _error,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
  ];

  Widget _modelCard() => _card([
    Text(
      tr("モデルを読み込む"),
      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
    ),
    const SizedBox(height: 8),
    Text(tr("対応形式：48 kHz・3チャンネルのA2-Lite .nam")),
    const SizedBox(height: 16),
    const Text(
      'NAM A2 LITE',
      style: TextStyle(
        color: StudioTheme.nam,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.5,
      ),
    ),
    const SizedBox(height: 8),
    Text(
      tr("モデルライブラリ"),
      style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
    ),
    const SizedBox(height: 8),
    Text(tr("48 kHzの対応モデルを取り込み、本体のスロットへ転送します。")),
    const SizedBox(height: 16),
    const Tone3000Logo(),
    const SizedBox(height: 12),
    FilledButton.tonalIcon(
      onPressed: _busy ? null : _importTone,
      icon: const Icon(Icons.travel_explore),
      label: Text(tr("TONE3000から探す")),
    ),
    OutlinedButton.icon(
      onPressed: _busy ? null : _import,
      icon: const Icon(Icons.file_open_outlined),
      label: Text(tr(".namファイルを選択")),
    ),
    if (_toneSource != null) ...[
      const SizedBox(height: 12),
      ToneAttribution(_toneSource!.tone),
    ],
    if (_model != null)
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(tr("{0}\nA2-Lite · 48 kHz · 本体への転送待ち", [_model!.name])),
      ),
    if (_model != null) ...[
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: _busy || _state == null ? null : _chooseTransferSlot,
        icon: const Icon(Icons.upload_outlined),
        label: Text(tr("転送先を選ぶ")),
      ),
    ],
  ]);

  Widget _card(List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
  Widget _slotCard(ModelSlot slot) => _card([
    Row(
      children: [
        Text(
          '${slot.number}'.padLeft(2, '0'),
          style: const TextStyle(color: Color(0xff74e5bd), fontSize: 24),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Text(
            slot.name ?? tr("空きスロット"),
            style: const TextStyle(fontSize: 18),
          ),
        ),
        if (_state!.selected == slot.number) Chip(label: Text(tr("選択中"))),
        if (slot.name != null)
          PopupMenuButton<String>(
            enabled: !_busy,
            tooltip: tr("スロット {0} の操作", [slot.number]),
            onSelected: (v) {
              switch (v) {
                case 'rename':
                  _renameSlot(slot);
                case 'delete':
                  _delete(slot);
              }
            },
            itemBuilder: (_) => [
              if (_client!.canRename)
                PopupMenuItem(value: 'rename', child: Text(tr("名前の変更"))),
              PopupMenuItem(value: 'delete', child: Text(tr("削除"))),
            ],
          ),
      ],
    ),
    if (_slotSources[slot.number] case final source?
        when source.model.name == slot.name) ...[
      const SizedBox(height: 12),
      const Text('TONE3000', style: TextStyle(fontWeight: FontWeight.bold)),
      ToneAttribution(source.tone),
    ],
    const SizedBox(height: 10),
    Wrap(
      spacing: 10,
      runSpacing: 8,
      children: [
        OutlinedButton(
          onPressed: _busy || slot.name == null
              ? null
              : () => _select(slot.number),
          child: Text(_state!.selected == slot.number ? tr("再読み込み") : tr("選択")),
        ),
        TextButton.icon(
          onPressed: _busy || _model == null ? null : () => _upload(slot),
          icon: const Icon(Icons.upload_outlined),
          label: Text(tr("ここへ転送")),
        ),
      ],
    ),
  ]);
}

class DevicePicker extends StatefulWidget {
  final BleConnector connector;
  const DevicePicker({super.key, required this.connector});
  @override
  State<DevicePicker> createState() => _DevicePickerState();
}

class _DevicePickerState extends State<DevicePicker> {
  final _devices = <String, DiscoveredDevice>{};
  StreamSubscription<DiscoveredDevice>? _scan;
  Timer? _timer;
  String _error = '';
  bool _scanning = true;
  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    _scan = widget.connector.scan().listen(
      (device) {
        if (mounted) setState(() => _devices[device.id] = device);
      },
      onError: (Object error) {
        if (mounted) {
          setState(() {
            _error = error.toString();
            _scanning = false;
          });
        }
      },
    );
    _timer = Timer(const Duration(seconds: 15), () {
      unawaited(_scan?.cancel());
      if (mounted) setState(() => _scanning = false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_scan?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .7,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr("近くのBluetooth機器"),
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(tr("FB200を選んでください。名前は本体のBluetooth設定により異なります。")),
            const SizedBox(height: 16),
            if (_scanning) const LinearProgressIndicator(),
            if (_error.isNotEmpty) Text(_error),
            if (!_scanning && _devices.isEmpty)
              Text(tr("機器が見つかりません。Bluetoothと本体の電源を確認してください。")),
            Expanded(
              child: ListView(
                children: [
                  for (final device in _devices.values)
                    ListTile(
                      leading: const Icon(Icons.bluetooth),
                      title: Text(
                        device.name.isEmpty ? tr("名前のない機器") : device.name,
                      ),
                      subtitle: Text('${device.id}  ·  ${device.rssi} dBm'),
                      onTap: () async {
                        await _scan?.cancel();
                        if (context.mounted) Navigator.pop(context, device);
                      },
                    ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr("閉じる")),
            ),
          ],
        ),
      ),
    ),
  );
}
