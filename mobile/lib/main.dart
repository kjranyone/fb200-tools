import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import 'ble_link.dart';
import 'nam_client.dart';
import 'nam_model.dart';
import 'pedal_client.dart';
import 'pedal_page.dart';
import 'protocol.dart';
import 'tone3000.dart';
import 'tone3000_page.dart';

void main() => runApp(const MainApp());

class MainApp extends StatelessWidget {
  const MainApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'FB200 NAM',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xff090d10),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff74e5bd),
        brightness: Brightness.dark,
        surface: const Color(0xff10171c),
      ),
      cardTheme: const CardThemeData(
        color: Color(0xff121c21),
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
          side: BorderSide(color: Color(0x1a74e5bd)),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xff0b1114),
        centerTitle: false,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xff0b1114),
        indicatorColor: const Color(0x2674e5bd),
        labelTextStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      listTileTheme: const ListTileThemeData(iconColor: Color(0xff74e5bd)),
    ),
    home: const ModelPage(),
  );
}

class ModelPage extends StatefulWidget {
  final Future<ImportedTone?> Function(BuildContext)? pickTone;
  const ModelPage({super.key, this.pickTone});
  @override
  State<ModelPage> createState() => _ModelPageState();
}

class _ModelPageState extends State<ModelPage> {
  final _connector = BleConnector();
  NamClient? _client;
  WireTransport? _wire;
  DeviceState? _state;
  NamModel? _model;
  ImportedTone? _toneSource;
  final _slotSources = <int, ImportedTone>{};
  bool _demo = false, _busy = false, _cancel = false, _committing = false;
  String _deviceName = '', _operation = '', _message = '', _error = '';
  double? _progress;

  Future<void> _run(String label, Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _operation = label;
      _error = '';
      _message = '';
    });
    try {
      await action();
    } on TransferCancelled {
      if (mounted) setState(() => _message = '転送を中止しました。');
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
          _committing = false;
        });
      }
    }
  }

  Future<void> _refresh() async {
    final client = _client;
    if (client == null) return;
    final value = await client.readState();
    if (mounted && _client == client) setState(() => _state = value);
  }

  Future<void> _attach(RpcTransport transport, String name, bool demo) async {
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
      if (!mounted) {
        await client.close();
        return;
      }
      if (transport is WireTransport) {
        transport.onDisconnected = () {
          if (mounted && _wire == transport) {
            setState(() {
              _client = null;
              _wire = null;
              _state = null;
              _error = '接続が切れました。再接続して本体の一覧を確認してください。';
            });
            unawaited(client.close());
          }
        };
      }
      setState(() {
        _client = state == null ? null : client;
        _wire = transport is WireTransport ? transport : null;
        _state = state;
        _demo = demo;
        _deviceName = name;
        if (state == null) {
          _message = '本体コントロールを利用できます。NAMモデル管理には対応ファームウェアが必要です。';
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
    await _run('本体の対応状況を確認中', () async {
      final transport = await _connector.connect(device.id);
      await _attach(
        transport,
        device.name.isEmpty ? 'FB200' : device.name,
        false,
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
    await client?.close();
    if (client == null) await wire?.close();
    _slotSources.clear();
  }

  Future<void> _import() => _run('モデルを確認中', () async {
    final file = await FilePicker.pickFile(type: FileType.any);
    if (file == null) return;
    const limit = 8 * 1024 * 1024;
    if ((await file.length() ?? 0) > limit) {
      throw const FormatException('8 MB以下の.namファイルを選択してください。');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream()) {
      if (bytes.length + chunk.length > limit) {
        throw const FormatException('8 MB以下の.namファイルを選択してください。');
      }
      bytes.add(chunk);
    }
    final model = NamModel.parse(bytes.takeBytes(), file.name);
    if (mounted) {
      setState(() {
        _model = model;
        _toneSource = null;
        _message = 'モデルを確認しました。転送先を選んでください。';
      });
    }
  });
  Future<void> _importTone() => _run('TONE3000からモデルを取り込み中', () async {
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
      _message = 'A2-Lite対応を確認しました。転送先を選んでください。';
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
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('実行'),
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
          'スロット ${slot.number} を上書き',
          '「${slot.name}」を「${model.name}」に置き換えます。このスロットを使う他のプリセットも、次回の読み込みから新しいモデルを使用します。',
        )) {
      return;
    }
    if (!mounted || _client != client) return;
    await _run('スロット ${slot.number} へ転送中', () async {
      _cancel = false;
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
              _operation = '本体への保存を確認中';
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
        setState(() => _message = '転送が完了しました。「選択」または「再読み込み」で使用できます。');
      }
    });
  }

  Future<void> _select(int slot, {bool save = false}) =>
      _run(save ? 'プリセットへ保存中' : 'モデルを切り替え中', () async {
        await _client!.select(slot, save: save);
        await _refresh();
        if (mounted) {
          setState(
            () => _message = save ? '現在のプリセットに選択を保存しました。' : 'モデルを切り替えました。',
          );
        }
      });
  Future<void> _delete(ModelSlot slot) async {
    final client = _client;
    if (!await _confirm(
      'モデルを削除',
      'スロット ${slot.number} の「${slot.name}」を削除します。このモデルを使うプリセットは再設定が必要です。',
    )) {
      return;
    }
    if (!mounted || client == null || _client != client) return;
    await _run('削除中', () async {
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
        title: Text('スロット ${slot.number} の名前'),
        content: TextField(
          controller: controller,
          maxLength: 23,
          decoration: const InputDecoration(
            helperText: '半角英数字・記号（空白なし）で1〜23文字',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('変更'),
          ),
        ],
      ),
    );
    // The dialog route is still animating out when its Future completes.
    Future<void>.delayed(const Duration(milliseconds: 500), controller.dispose);
    if (name == null || name.isEmpty || !mounted || _client != client) return;
    await _run('名前を変更中', () async {
      await client.rename(slot.number, name);
      await _refresh();
      if (mounted) {
        setState(() => _message = 'スロット ${slot.number} の名前を変更しました。');
      }
    });
  }

  @override
  void dispose() {
    unawaited(_client?.close() ?? _wire?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('FB200 NAM'),
      actions: [
        if (_client != null || _wire != null) ...[
          IconButton(
            tooltip: '一覧を更新',
            onPressed: _busy ? null : () => _run('一覧を更新中', _refresh),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '接続を終了',
            onPressed: _busy ? null : _disconnect,
            icon: const Icon(Icons.link_off),
          ),
        ],
      ],
    ),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                'いつもの音を、\nペダルへ。',
                style: Theme.of(context).textTheme.headlineLarge
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              const Text('A2-Lite モデルマネージャー  /  48 kHz'),
              const SizedBox(height: 24),
              _modelCard(),
              const SizedBox(height: 20),
              if (_client == null && _wire == null)
                _card([
                  const Icon(Icons.bluetooth, size: 36),
                  const SizedBox(height: 12),
                  const Text(
                    'FB200を接続',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '本体の操作とモデル管理を利用できます。接続中は公式アプリを閉じてください。NAM転送には対応ファームウェアが必要です。',
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: !_busy && _connector.supported ? _connect : null,
                    icon: const Icon(Icons.bluetooth_searching),
                    label: const Text('Bluetoothで接続'),
                  ),
                  if (!_connector.supported)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('Bluetooth接続はAndroid / iOSアプリで利用できます。'),
                    ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(
                            'デモを準備中',
                            () => _attach(DemoTransport(), 'Demo FB200', true),
                          ),
                    child: const Text('接続せず試す'),
                  ),
                ])
              else ...[
                _card([
                  Row(
                    children: [
                      Icon(
                        _demo
                            ? Icons.science_outlined
                            : Icons.bluetooth_connected,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _deviceName,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      Chip(label: Text(_demo ? 'DEMO' : '接続中')),
                    ],
                  ),
                  if (_demo) const Text('画面の体験用です。本体への転送・音声処理は行いません。'),
                  if (_wire != null)
                    FilledButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _run('本体を操作中', () async {
                              await Navigator.push<void>(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => PedalPage(
                                    transport: _wire!,
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
                                    namModel: _state?.slots
                                        .where(
                                          (s) => s.number == _state!.selected,
                                        )
                                        .map((s) => s.name)
                                        .firstOrNull,
                                  ),
                                ),
                              );
                              await _wire?.waitIdle();
                              if (_client != null && mounted) await _refresh();
                            }),
                      icon: const Icon(Icons.dashboard_customize_outlined),
                      label: const Text('プリセット・エフェクト・ツール'),
                    ),
                ]),
                if (_state != null) ...[
                  const SizedBox(height: 24),
                  Text(
                    '本体のモデル（${_state!.slots.where((s) => s.name != null).length}/${_client!.slotCount} 使用中）',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  for (final slot in _state!.slots) ...[
                    _slotCard(slot),
                    const SizedBox(height: 10),
                  ],
                  TextButton(
                    onPressed: _busy || _state!.selected == 0
                        ? null
                        : () => _select(0),
                    child: const Text('NAMをバイパス'),
                  ),
                  FilledButton.tonal(
                    onPressed: _busy
                        ? null
                        : () => _select(_state!.selected, save: true),
                    child: const Text('現在の選択をプリセットに保存'),
                  ),
                ],
              ],
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
                        child: const Text('転送を中止'),
                      ),
                    ],
                  ),
              ],
              if (_message.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    _message,
                    style: const TextStyle(color: Color(0xff74e5bd)),
                  ),
                ),
              if (_error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    _error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 28),
              Text(
                '試作版・Bluetooth転送は実機検証中\nNAM内部のGAINやトーンは変更できません。音色の異なるキャプチャを切り替えて使用します。',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Colors.white54),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _modelCard() => _card([
    const Text(
      'モデルを読み込む',
      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
    ),
    const SizedBox(height: 8),
    const Text('対応形式：48 kHz・3チャンネルのA2-Lite .nam'),
    const SizedBox(height: 16),
    const Tone3000Logo(),
    const SizedBox(height: 12),
    FilledButton.tonalIcon(
      onPressed: _busy ? null : _importTone,
      icon: const Icon(Icons.travel_explore),
      label: const Text('TONE3000から探す'),
    ),
    OutlinedButton.icon(
      onPressed: _busy ? null : _import,
      icon: const Icon(Icons.file_open_outlined),
      label: const Text('.namファイルを選択'),
    ),
    if (_toneSource != null) ...[
      const SizedBox(height: 12),
      ToneAttribution(_toneSource!.tone),
    ],
    if (_model != null)
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text('${_model!.name}\nA2-Lite · 48 kHz · 本体への転送待ち'),
      ),
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
            slot.name ?? '空きスロット',
            style: const TextStyle(fontSize: 18),
          ),
        ),
        if (_state!.selected == slot.number) const Chip(label: Text('選択中')),
        if (slot.name != null)
          PopupMenuButton<String>(
            enabled: !_busy,
            tooltip: 'スロット ${slot.number} の操作',
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
                const PopupMenuItem(value: 'rename', child: Text('名前の変更')),
              const PopupMenuItem(value: 'delete', child: Text('削除')),
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
          child: Text(_state!.selected == slot.number ? '再読み込み' : '選択'),
        ),
        TextButton.icon(
          onPressed: _busy || _model == null ? null : () => _upload(slot),
          icon: const Icon(Icons.upload_outlined),
          label: const Text('ここへ転送'),
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
            const Text(
              '近くのBluetooth機器',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text('FB200を選んでください。名前は本体のBluetooth設定により異なります。'),
            const SizedBox(height: 16),
            if (_scanning) const LinearProgressIndicator(),
            if (_error.isNotEmpty) Text(_error),
            if (!_scanning && _devices.isEmpty)
              const Text('機器が見つかりません。Bluetoothと本体の電源を確認してください。'),
            Expanded(
              child: ListView(
                children: [
                  for (final device in _devices.values)
                    ListTile(
                      leading: const Icon(Icons.bluetooth),
                      title: Text(
                        device.name.isEmpty ? '名前のない機器' : device.name,
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
              child: const Text('閉じる'),
            ),
          ],
        ),
      ),
    ),
  );
}
