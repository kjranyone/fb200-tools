import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import 'ir_wav.dart' show WavError, wavToIr;
import 'nam_client.dart' show DeviceState, NamClient;
import 'nam_tone.dart';
import 'studio_theme.dart';

import 'pedal_client.dart';
import 'protocol.dart';
import 'widgets/chain_strip.dart';
import 'widgets/knob.dart';
import 'widgets/nam_model_picker.dart';

class PedalPage extends StatefulWidget {
  final WireTransport transport;
  final bool restrictedNam;
  final bool toolsAvailable;
  final bool effectsAvailable;
  final bool btAudioAvailable;
  final String? namModel;

  /// The NAM client for model selection within the controller; null when the
  /// connected firmware has no NAM RPC (stock vendor firmware).
  final NamClient? namClient;
  final DeviceState? namState;
  final Future<void> Function()? onOpenModels;
  const PedalPage({
    super.key,
    required this.transport,
    required this.restrictedNam,
    required this.toolsAvailable,
    required this.effectsAvailable,
    required this.btAudioAvailable,
    this.namModel,
    this.namClient,
    this.namState,
    this.onOpenModels,
  });
  @override
  State<PedalPage> createState() => _PedalPageState();
}

class _PedalPageState extends State<PedalPage> {
  late final PedalClient _pedal;
  Timer? _timer;
  int _tab = 1, _bank = 0;
  bool _busy = false, _ready = false;
  String _error = '', _status = '';
  DateTime? _lastTap;
  Future<void>? _poll;
  String _pitch = '—';
  List<IrSlotInfo>? _irs;
  DeviceState? _namState;
  bool _libraryOpen = false;

  @override
  void initState() {
    super.initState();
    _pedal = PedalClient(widget.transport, namAware: widget.restrictedNam)
      ..addListener(_changed);
    _namState = widget.namState;
    unawaited(
      _run('本体を読み込み中', () async {
        await _pedal.initialize();
        _bank = _pedal.selected ~/ 4;
        await _pedal.loadBank(_bank);
        await _refreshNam();
        _ready = true;
        await _probeLooper();
      }),
    );
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_ready && !_busy && !_libraryOpen && _pedal.refreshRequired) {
        unawaited(
          _run('本体を同期中', () async {
            await _pedal.refresh();
            _bank = _pedal.selected ~/ 4;
            await _pedal.loadBank(_bank);
            await _refreshNam();
          }),
        );
      } else if (_ready &&
          !_busy &&
          !_libraryOpen &&
          _poll == null &&
          _tab == 3 &&
          widget.toolsAvailable &&
          widget.restrictedNam &&
          _pedal.settings![8] != 0) {
        _poll = _readPitch().whenComplete(() => _poll = null);
      } else if (_ready &&
          !_busy &&
          !_libraryOpen &&
          _poll == null &&
          _tab == 4 &&
          _looperAvailable) {
        _poll = _refreshLoop().whenComplete(() => _poll = null);
      }
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshNam() async {
    final client = widget.namClient;
    if (client == null) return;
    final fresh = await client.readState();
    if (mounted) setState(() => _namState = fresh);
  }

  String? get _activeModel => _namState?.slots
      .where((s) => s.number == _namState!.selected)
      .firstOrNull
      ?.name;

  bool get _dirty =>
      _ready &&
      !listEquals(_pedal.edit?.bytes, _pedal.presets[_pedal.selected]?.bytes);

  Future<void> _selectPreset(int index) async {
    if (index == _pedal.selected || _busy) return;
    if (_dirty &&
        !await _confirm(
          '未保存の編集を破棄してプリセットを切り替えますか？',
          title: 'プリセットを切り替え',
          accept: '切り替える',
        )) {
      return;
    }
    await _run('プリセットを選択中', () async {
      await _pedal.select(index);
      _bank = index ~/ 4;
      await _pedal.loadBank(_bank);
      await _refreshNam();
    });
  }

  Future<void> _openModels() async {
    if (_busy || widget.onOpenModels == null) return;
    setState(() => _libraryOpen = true);
    try {
      await _poll;
      if (!mounted) return;
      await widget.onOpenModels!();
      if (mounted) {
        await _run('モデルを同期中', () async {
          await _pedal.refresh();
          await _pedal.loadBank(_bank);
          await _refreshNam();
        });
      }
    } finally {
      if (mounted) setState(() => _libraryOpen = false);
    }
  }

  Future<void> _run(String status, Future<void> Function() action) async {
    if (_busy || !mounted) return;
    setState(() {
      _busy = true;
      _error = '';
      _status = status;
    });
    try {
      await _poll;
      await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is DeviceError
              ? e.message
              : '操作を完了できませんでした。接続と本体の状態を確認してください。',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '';
        });
      }
    }
  }

  Future<void> _readPitch() async {
    try {
      final p = await widget.transport.request(8, []);
      if (p.length != 16 || !mounted) return;
      final bytes = ByteData.sublistView(p);
      final frequency = bytes.getFloat32(4, Endian.little);
      final cents = bytes.getFloat32(8, Endian.little);
      const notes = [
        '—',
        'A♯',
        'B',
        'C',
        'C♯',
        'D',
        'D♯',
        'E',
        'F',
        'F♯',
        'G',
        'G♯',
        'A',
      ];
      if (p[0] == 0 ||
          p[1] == 0 ||
          p[2] < 1 ||
          p[2] > 12 ||
          !frequency.isFinite ||
          !cents.isFinite) {
        setState(() => _pitch = '—');
      } else {
        setState(
          () => _pitch =
              '${notes[p[2]]}  ${frequency.toStringAsFixed(1)} Hz  ${cents >= 0 ? '+' : ''}${cents.toStringAsFixed(1)} cent',
        );
      }
    } on DeviceError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<bool> _confirm(
    String text, {
    String title = '本体へ保存',
    String accept = '保存する',
  }) async =>
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
              child: Text(accept),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _save(int destination, PedalPreset preset) async {
    if (!await _confirm(
      '${PedalClient.address(destination)} を「${preset.name}」で上書きします。このプリセットを使っている音色が変わります。',
    )) {
      return;
    }
    await _run('プリセットを保存・照合中', () async {
      await _pedal.store(destination, preset);
      await _pedal.loadBank(_bank);
      await _refreshNam();
    });
  }

  Future<void> _rename(int index) async {
    final preset = await _pedal.readPreset(index);
    if (!mounted) return;
    final controller = TextEditingController(text: preset.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${PedalClient.address(index)} の名前'),
        content: TextField(
          controller: controller,
          maxLength: 20,
          decoration: const InputDecoration(helperText: '半角英数字・記号'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('次へ'),
          ),
        ],
      ),
    );
    // The dialog route is still animating out when its Future completes.
    Future<void>.delayed(const Duration(milliseconds: 500), controller.dispose);
    if (name != null && mounted) await _save(index, preset.renamed(name));
  }

  Future<void> _copy(int index) async {
    final source = await _pedal.readPreset(index);
    if (!mounted) return;
    final destination = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('${PedalClient.address(index)} のコピー先'),
        children: [
          for (var i = 0; i < 40; i++)
            if (i != index)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, i),
                child: Text(PedalClient.address(i)),
              ),
        ],
      ),
    );
    if (destination != null && mounted) await _save(destination, source);
  }

  Future<void> _backup() => _run('40プリセットをバックアップ中', () async {
    final data = await _pedal.backup();
    await FilePicker.saveFile(
      fileName: 'fb200-presets.json',
      bytes: data,
      mimeType: 'application/json',
    );
  });
  Future<void> _restore() async {
    final file = await FilePicker.pickFile(type: FileType.any);
    if (file == null) return;
    final bytes = BytesBuilder();
    await for (final chunk in file.readAsByteStream()) {
      if (bytes.length + chunk.length > 65536) {
        throw DeviceError('64 KB以下のバックアップを選択してください。');
      }
      bytes.add(chunk);
    }
    final presets = PedalClient.parseBackup(bytes.takeBytes());
    if (!mounted ||
        !await _confirm(
          '全40プリセットをバックアップの内容で上書きします。復元中は接続を維持してください。途中で切れた場合、完了したプリセットだけが復元されます。NAMモデル本体やIRデータは含みません。',
        )) {
      return;
    }
    await _run('プリセットを復元中', () async {
      final original = _pedal.selected;
      for (var i = 0; i < 40; i++) {
        if (mounted) setState(() => _status = '${i + 1}/40 を復元・照合中');
        await _pedal.store(i, presets[i]);
      }
      await _pedal.select(original);
      await _pedal.loadBank(_bank);
    });
  }

  // ---- user IR slots ----

  Future<void> _irReload() async {
    final slots = await _pedal.irList();
    if (mounted) setState(() => _irs = slots);
  }

  Future<String?> _askName(String title, String initial, int maxLength) async {
    final controller = TextEditingController(text: initial);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          maxLength: maxLength,
          decoration: const InputDecoration(helperText: '半角英数字・記号'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('次へ'),
          ),
        ],
      ),
    );
    // The dialog route is still animating out when its Future completes.
    Future<void>.delayed(const Duration(milliseconds: 500), controller.dispose);
    return name;
  }

  Future<void> _irImport(IrSlotInfo slot) async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['wav'],
    );
    if (file == null || !mounted) return;
    final bytes = BytesBuilder();
    await for (final chunk in file.readAsByteStream()) {
      if (bytes.length + chunk.length > 8 * 1024 * 1024) {
        throw DeviceError('8MB以下のWAVファイルを選択してください。');
      }
      bytes.add(chunk);
    }
    final samples = _guardWav(bytes.takeBytes());
    if (!mounted) return;
    final stem = file.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
    final name = await _askName('IR${slot.slot} の名前', stem, 50);
    if (name == null || name.trim().isEmpty || !mounted) return;
    if (slot.used &&
        !await _confirm(
          'IR${slot.slot} 「${slot.name}」を「${PedalClient.sanitizeIrName(name)}」で上書きします。',
          title: 'IRを上書き',
          accept: '上書きする',
        )) {
      return;
    }
    await _run('IRを転送中', () async {
      await _pedal.irUpload(
        slot.slot,
        name,
        samples,
        progress: (sent, total) {
          if (mounted) setState(() => _status = 'IRを転送中 ($sent/$total)');
        },
      );
      await _irReload();
    });
  }

  Float32List _guardWav(List<int> raw) {
    try {
      return wavToIr(Uint8List.fromList(raw));
    } on WavError catch (e) {
      throw DeviceError(e.message);
    }
  }

  Future<void> _irRename(IrSlotInfo slot) async {
    final name = await _askName('IR${slot.slot} の名前', slot.name, 50);
    if (name == null || name.trim().isEmpty || !mounted) return;
    await _run('IR名を変更中', () async {
      await _pedal.irRename(slot.slot, name);
      await _irReload();
    });
  }

  Future<void> _irDelete(IrSlotInfo slot) async {
    if (!await _confirm(
      'IR${slot.slot} 「${slot.name}」を削除します。このIRを使うプリセットの音が変わります。',
      title: 'IRを削除',
      accept: '削除する',
    )) {
      return;
    }
    await _run('IRを削除中', () async {
      await _pedal.irDelete(slot.slot);
      await _irReload();
    });
  }

  Future<void> _btName() async {
    final name = await _askName('Bluetooth名', '', 20);
    if (name == null || name.isEmpty || !mounted) return;
    await _run('Bluetooth名を送信中', () async {
      await _pedal.setBtName(name);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Bluetooth名を送信しました。反映を確認するには再接続してください。'),
          ),
        );
      }
    });
  }

  Future<void> _rhythm({bool? on, int? pattern, int? level, int? bpm}) =>
      _run('ドラムを設定中', () async {
        final r = _pedal.rhythm!;
        await _pedal.setRhythm(
          on: on ?? r[0] != 0,
          pattern: pattern ?? r[2],
          level: level ?? r[3],
          bpm: bpm ?? read16(r, 4),
        );
      });
  Future<void> _tuner({bool? on, bool? mute, int? a4}) =>
      _run('チューナーを設定中', () async {
        final s = _pedal.settings!;
        await _pedal.setTuner(
          on: on ?? s[8] != 0,
          mute: mute ?? s[9] != 0,
          a4: a4 ?? 435 + s[7],
        );
      });
  Future<void> _setting(int index, int value) => _run('本体設定を更新中', () async {
    final s = Uint8List.fromList(_pedal.settings!)..[index] = value;
    await _pedal.setSettings(s);
  });

  // ---- looper ----

  bool _looperAvailable = false;
  LooperStatus? _loop;

  Future<void> _editModuleOrder() async {
    // Real presets can carry a stale/unknown sequence; repair it into a full
    // permutation (keep the valid prefix, append missing modules in default
    // order) instead of refusing to edit.
    final bytes = _pedal.edit!.bytes.sublist(0xbc, 0xc3);
    final order = <int>[];
    final used = <int>{};
    for (final v in bytes) {
      if (v < 0 || v > 6 || used.contains(v)) break;
      order.add(v);
      used.add(v);
    }
    for (var m = 0; m <= 6; m++) {
      if (!used.contains(m)) order.add(m);
    }
    var matches = order.length == bytes.length;
    for (var i = 0; matches && i < order.length; i++) {
      matches = order[i] == bytes[i];
    }
    final repaired = !matches;
    final changed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('モジュールの接続順'),
          content: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (repaired)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text(
                        'プリセットの順序データが壊れていたため、標準順で補いました。',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  for (var i = 0; i < order.length; i++)
                    Row(
                      children: [
                        Expanded(child: Text(moduleName(order[i]))),
                        IconButton(
                          icon: const Icon(Icons.arrow_upward),
                          onPressed: i == 0
                              ? null
                              : () => setDialog(() {
                                  final t = order[i - 1];
                                  order[i - 1] = order[i];
                                  order[i] = t;
                                }),
                        ),
                        IconButton(
                          icon: const Icon(Icons.arrow_downward),
                          onPressed: i == order.length - 1
                              ? null
                              : () => setDialog(() {
                                  final t = order[i + 1];
                                  order[i + 1] = order[i];
                                  order[i] = t;
                                }),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('変更'),
            ),
          ],
        ),
      ),
    );
    if (changed != true || !mounted) return;
    await _run('モジュール順序を変更中', () async {
      await _pedal.setModuleOrder(order);
      await _pedal.refresh();
    });
  }

  static String moduleName(int index) {
    const names = [
      'コンプレッサー',
      'ノイズゲート',
      'アンプ',
      'キャビネット / IR',
      'モジュレーション',
      'ディレイ',
      'リバーブ',
    ];
    return names[index.clamp(0, 6)];
  }

  Future<void> _probeLooper() async {
    try {
      final s = await _pedal.looperStatus();
      if (mounted) setState(() => _looperAvailable = s.available);
      if (s.available) setState(() => _loop = s);
    } catch (_) {
      if (mounted) setState(() => _looperAvailable = false);
    }
  }

  Future<void> _refreshLoop() async {
    try {
      final s = await _pedal.looperStatus();
      if (mounted && s.available) setState(() => _loop = s);
    } catch (_) {
      /* polling */
    }
  }

  Future<void> _looperAct(int op, String label) => _run(label, () async {
    final code = await _pedal.looperAction(op);
    if (code == 1) throw DeviceError('今は実行できません（録音中の確定待ちなど）。');
    if (code == 2) throw DeviceError('ルーパー用のフラッシュ領域がありません。');
    if (code == 3) throw DeviceError('フラッシュの準備中です。少し待って再試行してください。');
    await _refreshLoop();
  });

  Future<void> _looperClear() async {
    if (!await _confirm(
      'ループを消去します。取り消せません。',
      title: 'ループを消去',
      accept: '消去する',
    )) {
      return;
    }
    await _looperAct(7, 'ループを消去中');
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pedal.removeListener(_changed);
    _pedal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('FB200 STUDIO'),
      actions: [
        if (_ready)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: Text(
                '${_pedal.battery}%',
                style: const TextStyle(fontSize: 12, color: Color(0xff9daaba)),
              ),
            ),
          ),
        IconButton(
          tooltip: '本体と同期',
          onPressed: _busy
              ? null
              : () => _run('同期中', () async {
                  await _pedal.refresh();
                  _bank = _pedal.selected ~/ 4;
                  await _pedal.loadBank(_bank);
                  await _refreshNam();
                  if (_irs != null) await _irReload();
                }),
          icon: const Icon(Icons.sync, size: 21),
        ),
      ],
    ),
    bottomNavigationBar: SafeArea(
      top: false,
      child: Material(
        color: StudioTheme.background,
        child: SizedBox(
          height: 68,
          child: LayoutBuilder(
            builder: (context, box) {
              const labels = [
                'プリセット',
                'エフェクト',
                'ドラム',
                'チューナー',
                'ルーパー',
                'IR',
                '設定',
              ];
              const icons = [
                Icons.grid_view_outlined,
                Icons.route_outlined,
                Icons.music_note_outlined,
                Icons.straighten,
                Icons.loop,
                Icons.speaker_outlined,
                Icons.settings_outlined,
              ];
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < labels.length; i++)
                      Semantics(
                        selected: _tab == i,
                        child: SizedBox(
                          width: (box.maxWidth / 7).clamp(48.0, 180.0),
                          child: InkWell(
                            onTap: () {
                              setState(() => _tab = i);
                              if (i == 5 && _irs == null && !_busy) {
                                _run('IR一覧を読み込み中', _irReload);
                              }
                            },
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  icons[i],
                                  size: 21,
                                  color: _tab == i
                                      ? StudioTheme.blue
                                      : const Color(0xff8390a1),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  labels[i],
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: _tab == i
                                        ? StudioTheme.blue
                                        : const Color(0xff9daaba),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    ),
    body: SafeArea(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_ready)
            LayoutBuilder(
              builder: (context, box) {
                final wide = box.maxWidth >= 1000;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (wide)
                      Container(
                        width: 242,
                        padding: const EdgeInsets.all(16),
                        decoration: const BoxDecoration(
                          border: Border(
                            right: BorderSide(color: StudioTheme.line),
                          ),
                        ),
                        child: SingleChildScrollView(child: _presetSidebar()),
                      ),
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: wide ? 24 : 16,
                          vertical: 8,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _presetHeader(),
                            if (_error.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 6,
                                ),
                                child: Text(
                                  _error,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                              ),
                            const SizedBox(height: 12),
                            Expanded(
                              child: _fillOrScroll(switch (_tab) {
                                0 => _banks(),
                                1 => _effects(),
                                2 => _drums(),
                                3 => _tunerTab(),
                                4 => _looper(),
                                5 => _ir(),
                                _ => _settings(),
                              }),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          if (_busy && _status != 'エフェクトを更新中') ...[
            const ModalBarrier(color: Color(0x99090d12), dismissible: false),
            Center(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(height: 16),
                      Text(_status, textAlign: TextAlign.center),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _presetHeader() => Row(
    children: [
      Text(
        PedalClient.address(_pedal.selected),
        style: const TextStyle(
          fontSize: 36,
          fontWeight: FontWeight.w800,
          color: StudioTheme.blue,
          height: 1.1,
        ),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _pedal.edit!.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 3),
            Text(
              _dirty ? '●  EDITED · 未保存' : 'PRESET · 本体と同期済み',
              style: TextStyle(
                fontSize: 10,
                letterSpacing: .8,
                color: _dirty ? StudioTheme.nam : const Color(0xff8390a1),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(width: 6),
      FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: StudioTheme.nam,
          foregroundColor: StudioTheme.background,
        ),
        onPressed: _busy ? null : () => _save(_pedal.selected, _pedal.edit!),
        icon: const Icon(Icons.save_outlined, size: 17),
        label: const Text('保存'),
      ),
    ],
  );

  Widget _presetSidebar() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'PRESETS',
        style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 1.8),
      ),
      const SizedBox(height: 16),
      DropdownButtonFormField<int>(
        key: ValueKey(_bank),
        initialValue: _bank,
        decoration: const InputDecoration(labelText: 'バンク'),
        items: [
          for (var i = 0; i < 10; i++)
            DropdownMenuItem(value: i, child: Text('BANK $i')),
        ],
        onChanged: _busy
            ? null
            : (v) => _run('バンクを読み込み中', () async {
                _bank = v!;
                await _pedal.loadBank(_bank);
              }),
      ),
      const SizedBox(height: 14),
      for (var i = _bank * 4; i < _bank * 4 + 4; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Material(
            color: i == _pedal.selected
                ? StudioTheme.blue.withValues(alpha: .12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              leading: Text(
                PedalClient.address(i),
                style: TextStyle(
                  color: i == _pedal.selected
                      ? StudioTheme.blue
                      : const Color(0xff8390a1),
                ),
              ),
              title: Text(
                _pedal.presets[i]?.name ?? '読み込み前',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
              onTap: _busy ? null : () => _selectPreset(i),
            ),
          ),
        ),
      const Divider(height: 32),
      TextButton(
        onPressed: () => setState(() => _tab = 0),
        child: const Text('プリセットを管理'),
      ),
      if (widget.onOpenModels != null)
        OutlinedButton.icon(
          onPressed: _busy ? null : _openModels,
          icon: const Icon(Icons.library_music_outlined, size: 18),
          label: const Text('NAMライブラリ'),
        ),
      const SizedBox(height: 20),
      Text(
        '40 PRESETS  /  ${_pedal.version}',
        style: const TextStyle(fontSize: 10, color: Color(0xff8390a1)),
      ),
    ],
  );

  /// Fixed-layout tab body: fills the screen when the content fits (the
  /// normal case on portrait tablets), and only scrolls when the screen is
  /// too short (landscape phones). Knobs still win the gesture arena over
  /// this scroll view, so drag control keeps working either way.
  Widget _fillOrScroll(Widget child) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: child,
      ),
    ),
  );

  Widget _banks() {
    final selected = _pedal.selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<int>(
                key: ValueKey(_bank),
                initialValue: _bank,
                decoration: const InputDecoration(labelText: 'バンク'),
                isExpanded: true,
                items: [
                  for (var i = 0; i < 10; i++)
                    DropdownMenuItem(value: i, child: Text('BANK $i')),
                ],
                onChanged: _busy
                    ? null
                    : (v) => _run('バンクを読み込み中', () async {
                        _bank = v!;
                        await _pedal.loadBank(_bank);
                      }),
              ),
            ),
            const SizedBox(width: 8),
            PopupMenuButton<String>(
              enabled: !_busy,
              onSelected: (v) =>
                  v == 'backup' ? _run('バックアップ中', _backup) : _guard(_restore),
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'backup', child: Text('全プリセットをファイルへ保存')),
                PopupMenuItem(value: 'restore', child: Text('バックアップから復元')),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: 2,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 2.6,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            for (var i = _bank * 4; i < _bank * 4 + 4; i++)
              Card(
                margin: EdgeInsets.zero,
                color: i == selected
                    ? Theme.of(context).colorScheme.primaryContainer
                    : null,
                child: InkWell(
                  onTap: _busy ? null : () => _selectPreset(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            Text(
                              PedalClient.address(i),
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                            const Spacer(),
                            if (i == selected)
                              Icon(
                                Icons.check_circle,
                                size: 16,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                          ],
                        ),
                        Text(
                          _pedal.presets[i]?.name ?? '読み込み前',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _save(_pedal.selected, _pedal.edit!),
              child: const Text('編集内容を保存'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _guard(() => _rename(_presetMenuTarget())),
              child: const Text('名前の変更'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _guard(() => _copy(_presetMenuTarget())),
              child: const Text('コピー'),
            ),
          ],
        ),
      ],
    );
  }

  int _presetMenuTarget() => _pedal.selected;

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is DeviceError ? e.message : '操作を完了できませんでした。',
        );
      }
    }
  }

  int _selectedModule = 2;

  // engine_task processes this fixed serial path. Preset order bytes are
  // metadata in current firmware, so do not draw them as audible routing.
  List<int> get _chainOrder => const [1, 0, 2, 3, 4, 5, 6];

  Set<int> get _chainEnabled => {
    for (var i = 0; i < pedalModules.length; i++)
      if (_pedal.edit!.word(pedalModules[i].offset) != 0) i,
  };

  Widget _effects() {
    final visible = [
      for (final m in _chainOrder)
        if (pedalModules[m].command != 0x85 || widget.restrictedNam) m,
    ];
    final selected = visible.contains(_selectedModule)
        ? _selectedModule
        : visible.first;
    final module = pedalModules[selected];
    final isNam = widget.restrictedNam && selected == 2;
    final unsupported =
        widget.restrictedNam &&
        !widget.effectsAvailable &&
        [3, 4, 6].contains(selected);
    final accent = StudioTheme.moduleColors[selected];
    final enabled = _chainEnabled
      ..removeWhere(
        (m) =>
            (widget.restrictedNam &&
                !widget.effectsAvailable &&
                [3, 4, 6].contains(m)) ||
            (widget.restrictedNam && m == 2 && _namState?.selected == 0),
      );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                const Row(
                  children: [
                    Text(
                      'SIGNAL CHAIN',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.4,
                      ),
                    ),
                    Spacer(),
                    Text(
                      'FIXED',
                      style: TextStyle(fontSize: 10, color: Color(0xff8390a1)),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                ChainStrip(
                  order: visible,
                  enabled: enabled,
                  unavailable: widget.restrictedNam && !widget.effectsAvailable
                      ? const {3, 4, 6}
                      : const {},
                  selected: visible.indexOf(selected),
                  restrictedNam: widget.restrictedNam,
                  namModel: _namState == null ? widget.namModel : _activeModel,
                  onTap: (i) => setState(() => _selectedModule = visible[i]),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: .12),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Icon(
                        ChainStrip.icons[selected],
                        size: 23,
                        color: accent,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isNam ? 'NAM A2 LITE' : module.name,
                            style: const TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            isNam
                                ? 'NEURAL AMP MODELER · 48 kHz'
                                : ChainStrip.names[selected],
                            style: TextStyle(
                              fontSize: 9,
                              letterSpacing: 1,
                              color: accent,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: enabled.contains(selected),
                      activeTrackColor: accent,
                      onChanged:
                          _busy ||
                              unsupported ||
                              (isNam && _namState?.selected == 0)
                          ? null
                          : (v) => _run(
                              'エフェクトを更新中',
                              () => _pedal.module(module, [
                                for (var k = 0; k < module.fields.length; k++)
                                  k == 0
                                      ? (v ? 1 : 0)
                                      : _pedal.edit!.word(
                                          module.offset + k * 2,
                                        ),
                              ]),
                            ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (isNam) ...[
                  _namModelSelector(),
                  const SizedBox(height: 16),
                  Text(
                    widget.namClient?.canToneEq == true
                        ? 'PRE · DRIVE  →  A2 LITE  →  POST · EQ / LEVEL'
                        : 'このファームウェアではGAIN / VOLUMEのみ対応',
                    style: TextStyle(
                      fontSize: 9,
                      letterSpacing: .5,
                      color: Color(0xff9daaba),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (unsupported)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text('このファームウェアでは、このエフェクトの音声処理は利用できません。'),
                  ),
                LayoutBuilder(
                  builder: (context, box) {
                    final columns = box.maxWidth >= 650
                        ? 6
                        : box.maxWidth >= 280
                        ? 3
                        : 2;
                    final width = (box.maxWidth - (columns - 1) * 12) / columns;
                    final fields = isNam
                        ? const [2, 3, 4, 6, 5, 7]
                        : [
                            for (var i = 1; i < module.fields.length; i++)
                              if (module.fields[i].max > 0) i,
                          ];
                    return Wrap(
                      spacing: 12,
                      runSpacing: 16,
                      children: [
                        for (final i in fields)
                          SizedBox(
                            width: width,
                            child: Knob(
                              key: ValueKey('module-$selected-field-$i'),
                              defaultValue: isNam ? 50 : null,
                              label: isNam
                                  ? NamTone.labels[i]!
                                  : module.fields[i].label,
                              value: _pedal.edit!
                                  .word(module.offset + i * 2)
                                  .clamp(
                                    module.fields[i].min,
                                    module.fields[i].max,
                                  ),
                              min: module.fields[i].min,
                              max: module.fields[i].max,
                              size: width.clamp(56.0, 86.0),
                              accent: accent,
                              format: isNam
                                  ? (v) => NamTone.format(i, v)
                                  : null,
                              enabled: !_busy && !_moduleDisabled(module, i),
                              onChanged: (value) => _run(
                                'エフェクトを更新中',
                                () => _pedal.module(module, [
                                  for (var k = 0; k < module.fields.length; k++)
                                    k == i
                                        ? value
                                        : _pedal.edit!.word(
                                            module.offset + k * 2,
                                          ),
                                ]),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
                const Divider(height: 20),
                Text(
                  isNam
                      ? '上下で調整・横に離すと微調整 · 数値タップで入力 · 保存で確定'
                      : '上下ドラッグで調整 · 数値タップで直接入力',
                  style: TextStyle(fontSize: 10, color: Color(0xff8390a1)),
                ),
              ],
            ),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('モジュールの接続順'),
          subtitle: const Text('プリセットの順序データを編集（音声経路は固定）。'),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: _busy ? null : () => _guard(_editModuleOrder),
        ),
      ],
    );
  }

  Future<void> _chooseNamModel() async {
    final state = _namState, client = widget.namClient;
    if (_busy || state == null || client == null) return;
    final preset = _pedal.selected;
    setState(() => _libraryOpen = true);
    int? choice;
    try {
      await _poll;
      if (!mounted) return;
      choice = await pickNamModel(
        context,
        state,
        canAdd: widget.onOpenModels != null,
      );
    } finally {
      if (mounted) setState(() => _libraryOpen = false);
    }
    if (!mounted || choice == null) return;
    if (choice == -1) {
      await _guard(_openModels);
      return;
    }
    if (preset != _pedal.selected) {
      setState(() => _error = '本体のプリセットが切り替わりました。モデルを選び直してください。');
      return;
    }
    if (choice == state.selected) return;
    await _run('NAMモデルをロード中', () async {
      await client.select(choice!);
      await _pedal.refresh();
      await _refreshNam();
    });
  }

  Widget _namModelSelector() {
    final state = _namState;
    final selected = state?.selected ?? 0;
    final name = _activeModel;
    final status = state == null
        ? 'モデルの状態を取得できません'
        : selected == 0
        ? 'NAMをバイパス中'
        : name == null
        ? '選択したスロットは空です。モデルを選び直してください'
        : _pedal.edit!.word(0x2c) == 0
        ? 'ロード済み · NAMはOFF'
        : '本体にロード済み';
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          state == null
              ? widget.namModel ?? 'NAM MODEL'
              : selected == 0
              ? '00  BYPASS'
              : '${selected.toString().padLeft(2, '0')}  ${name ?? 'モデルなし'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Icon(
              selected != 0 && name != null
                  ? Icons.check_circle
                  : Icons.info_outline,
              size: 14,
              color: StudioTheme.ready,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                status,
                style: const TextStyle(fontSize: 12, color: StudioTheme.ready),
              ),
            ),
          ],
        ),
      ],
    );
    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          key: const ValueKey('choose-nam-model'),
          style: FilledButton.styleFrom(
            backgroundColor: StudioTheme.nam,
            foregroundColor: StudioTheme.background,
          ),
          onPressed: _busy || state == null || widget.namClient == null
              ? null
              : _chooseNamModel,
          icon: const Icon(Icons.swap_horiz),
          label: const Text('モデルを選ぶ'),
        ),
        if (widget.onOpenModels != null)
          TextButton.icon(
            key: const ValueKey('open-nam-library'),
            onPressed: _busy ? null : () => _guard(_openModels),
            icon: const Icon(Icons.add),
            label: const Text('追加・転送'),
          ),
      ],
    );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: StudioTheme.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: StudioTheme.nam.withValues(alpha: .45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, box) => box.maxWidth >= 650
                ? Row(
                    children: [
                      Expanded(child: info),
                      const SizedBox(width: 16),
                      actions,
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [info, const SizedBox(height: 12), actions],
                  ),
          ),
          if (state != null && !state.slots.any((s) => s.name != null)) ...[
            const SizedBox(height: 8),
            const Text(
              '保存済みモデルなし · ライブラリから本体へ転送してください',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  bool _moduleDisabled(PedalModule module, int field) {
    if ((widget.restrictedNam &&
        !widget.effectsAvailable &&
        [0x83, 0x84, 0x86].contains(module.command))) {
      return true;
    }
    // Under NAM the amp block's fields drive the NAM tone controls; only
    // the model field (index 1) has no NAM meaning.
    return widget.restrictedNam &&
        module.command == 0x82 &&
        (field == 1 ||
            (field >= 3 && field <= 6 && widget.namClient?.canToneEq != true));
  }

  Widget _value(
    String label,
    int value,
    int min,
    int max,
    void Function(int) change, {
    bool disabled = false,
  }) {
    return Knob(
      label: label,
      value: value.clamp(min, max),
      min: min,
      max: max,
      enabled: !_busy && !disabled,
      onChanged: change,
    );
  }

  Widget _drums() {
    final r = _pedal.rhythm!;
    if (!widget.toolsAvailable) {
      return Center(child: const Text('ドラムは本体の更新後に利用できます。'));
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _value('パターン', r[2] + 1, 1, 40, (v) => _rhythm(pattern: v - 1)),
            _value('テンポ', read16(r, 4), 40, 260, (v) => _rhythm(bpm: v)),
            _value('音量', r[3], 0, 100, (v) => _rhythm(level: v)),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            FilledButton.tonal(
              onPressed: _busy ? null : () => _rhythm(on: r[0] == 0),
              child: Text(r[0] != 0 ? '停止' : '再生'),
            ),
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () {
                      final now = DateTime.now(), previous = _lastTap;
                      _lastTap = now;
                      if (previous != null) {
                        final dt = now.difference(previous).inMilliseconds;
                        if (dt > 0 && dt <= 3000) {
                          _rhythm(bpm: (60000 / dt).round().clamp(40, 260));
                        }
                      }
                    },
              child: const Text('タップテンポ'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _tunerTab() {
    final s = _pedal.settings!;
    if (!widget.toolsAvailable) {
      return Center(child: const Text('チューナーは本体の更新後に利用できます。'));
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.restrictedNam)
          Text(
            _pitch,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.displayMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary,
            ),
          )
        else
          Text(
            '音程は本体のディスプレイで確認できます。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: s[8] != 0,
                  onChanged: _busy ? null : (v) => _tuner(on: v),
                ),
                const Text('チューナー'),
              ],
            ),
            _value('基準 A4', 435 + s[7], 435, 450, (v) => _tuner(a4: v)),
          ],
        ),
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 48),
          title: const Text('チューニング中はミュート'),
          value: s[9] != 0,
          onChanged: _busy ? null : (v) => _tuner(mute: v),
        ),
      ],
    );
  }

  Widget _looper() {
    if (!_looperAvailable) {
      return const Center(child: Text('ルーパーはこのファームウェアでは利用できません。'));
    }
    final s = _loop;
    final status = () {
      if (s == null) return '状態を確認中…';
      final undo = s.undo == 0
          ? ''
          : s.undo == 1
          ? '・元に戻す可'
          : '・やり直し可';
      return '${PedalClient.looperStates[s.state.clamp(0, 5)]}'
          '  長さ ${s.lenS}秒 / 最大 ${s.maxS}秒$undo'
          '${s.storeBusy ? '・保存中' : ''}${s.writing ? '・書込中' : ''}';
    }();
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          status,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonal(
              onPressed: _busy ? null : () => _looperAct(1, 'ルーパーを操作中'),
              child: const Text('タップ'),
            ),
            FilledButton.tonal(
              onPressed: _busy ? null : () => _looperAct(2, 'ルーパーを操作中'),
              child: const Text('録音'),
            ),
            FilledButton.tonal(
              onPressed: _busy ? null : () => _looperAct(3, 'ルーパーを操作中'),
              child: const Text('再生'),
            ),
            FilledButton.tonal(
              onPressed: _busy ? null : () => _looperAct(4, 'ルーパーを操作中'),
              child: const Text('ダビング'),
            ),
            TextButton(
              onPressed: _busy ? null : () => _looperAct(5, 'ルーパーを操作中'),
              child: const Text('停止'),
            ),
            TextButton(
              onPressed: _busy ? null : () => _looperAct(6, 'ルーパーを操作中'),
              child: const Text('元に戻す'),
            ),
            TextButton(
              onPressed: _busy ? null : _looperClear,
              child: const Text('消去'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Center(
          child: _value(
            'ループの音量',
            s?.level ?? 100,
            0,
            100,
            (v) => _run('ループ音量を変更中', () async {
              await _pedal.looperLevel(v);
              await _refreshLoop();
            }),
          ),
        ),
        const SizedBox(height: 4),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          children: [
            for (var slot = 1; slot <= 2; slot++) ...[
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _run('ループ$slotを保存中', () => _pedal.looperSave(slot)),
                child: Text('$slotへ保存'),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _run('ループ$slotを読込中', () async {
                        await _pedal.looperLoad(slot);
                        await _refreshLoop();
                      }),
                child: Text('$slotから読込'),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _ir() {
    final slots = _irs;
    if (slots == null) {
      return Center(
        child: OutlinedButton.icon(
          onPressed: _busy ? null : () => _run('IR一覧を読み込み中', _irReload),
          icon: const Icon(Icons.refresh),
          label: const Text('IR一覧を読み込む'),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.restrictedNam && !widget.effectsAvailable)
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text(
              '現在のNAMファームウェアではキャビネットIRは音声処理に使われません。保存したIRはストックファームウェアで利用できます。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12),
            ),
          ),
        GridView.count(
          crossAxisCount: 3,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 1.9,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            for (final s in slots)
              Card(
                margin: EdgeInsets.zero,
                child: InkWell(
                  onTap: _busy ? null : () => _guard(() => _irSlotMenu(s)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'IR${s.slot}',
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                        Text(
                          s.used ? s.name : '空き',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                color: s.used
                                    ? null
                                    : Theme.of(context).colorScheme.outline,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        const Text(
          'スロットをタップしてWAV取り込み・名前変更・削除。変換は公式エディタと同じ44.1 kHz・チャンネル0・1024サンプルです。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12),
        ),
      ],
    );
  }

  Future<void> _irSlotMenu(IrSlotInfo s) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                'IR${s.slot}  ${s.used ? s.name : '空き'}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('WAVから取り込み'),
              onTap: () => Navigator.pop(context, 'import'),
            ),
            if (s.used) ...[
              ListTile(
                leading: const Icon(Icons.text_fields),
                title: const Text('名前の変更'),
                onTap: () => Navigator.pop(context, 'rename'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('削除'),
                onTap: () => Navigator.pop(context, 'delete'),
              ),
            ],
          ],
        ),
      ),
    );
    switch (action) {
      case 'import':
        await _irImport(s);
      case 'rename':
        await _irRename(s);
      case 'delete':
        await _irDelete(s);
    }
  }

  Widget _settings() {
    final s = _pedal.settings!;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _value('入力ゲイン', s[2], 0, 25, (v) => _setting(2, v)),
            _value('LED色', s[11], 0, 9, (v) => _setting(11, v)),
            _value('LED明るさ', s[12], 0, 100, (v) => _setting(12, v)),
          ],
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          dense: true,
          title: const Text('グローバル・キャビネット'),
          value: s[1] != 0,
          onChanged: _busy || (widget.restrictedNam && !widget.effectsAvailable)
              ? null
              : (v) => _setting(1, v ? 1 : 0),
        ),
        SwitchListTile(
          dense: true,
          title: const Text('Bluetoothオーディオ'),
          value: s[10] != 0,
          onChanged: _busy || (widget.restrictedNam && !widget.btAudioAvailable)
              ? null
              : (v) => _setting(10, v ? 1 : 0),
        ),
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Bluetooth名の変更'),
          subtitle: const Text('半角英数字・記号で1〜20文字。変更は再接続後に本体側で確認してください。'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _busy ? null : () => _guard(_btName),
        ),
      ],
    );
  }
}
