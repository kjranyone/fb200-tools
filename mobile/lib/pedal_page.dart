import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'ir_wav.dart' show WavError, wavToIr;
import 'pedal_client.dart';
import 'protocol.dart';

class PedalPage extends StatefulWidget {
  final WireTransport transport;
  final bool restrictedNam;
  final bool toolsAvailable;
  final bool effectsAvailable;
  final bool btAudioAvailable;
  const PedalPage({
    super.key,
    required this.transport,
    required this.restrictedNam,
    required this.toolsAvailable,
    required this.effectsAvailable,
    required this.btAudioAvailable,
  });
  @override
  State<PedalPage> createState() => _PedalPageState();
}

class _PedalPageState extends State<PedalPage> {
  late final PedalClient _pedal;
  Timer? _timer;
  int _tab = 0, _bank = 0;
  bool _busy = false, _ready = false;
  String _error = '', _status = '';
  DateTime? _lastTap;
  Future<void>? _poll;
  String _pitch = '—';
  List<IrSlotInfo>? _irs;

  @override
  void initState() {
    super.initState();
    _pedal = PedalClient(widget.transport, namAware: widget.restrictedNam)
      ..addListener(_changed);
    unawaited(
      _run('本体を読み込み中', () async {
        await _pedal.initialize();
        _bank = _pedal.selected ~/ 4;
        await _pedal.loadBank(_bank);
        _ready = true;
        await _probeLooper();
      }),
    );
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_ready && !_busy && _pedal.refreshRequired) {
        unawaited(_run('本体を同期中', _pedal.refresh));
      } else if (_ready &&
          !_busy &&
          _poll == null &&
          _tab == 2 &&
          widget.toolsAvailable &&
          widget.restrictedNam &&
          _pedal.settings![8] != 0) {
        _poll = _readPitch().whenComplete(() => _poll = null);
      } else if (_ready &&
          !_busy &&
          _poll == null &&
          _tab == 2 &&
          _looperAvailable) {
        _poll = _refreshLoop().whenComplete(() => _poll = null);
      }
    });
  }

  void _changed() {
    if (mounted) setState(() {});
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
    final bytes = _pedal.edit!.bytes.sublist(0xbc, 0xc3);
    var order = List<int>.of(bytes);
    var valid =
        order.length == 7 &&
        Set.of(order).containsAll(const [0, 1, 2, 3, 4, 5, 6]);
    final changed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('モジュールの接続順'),
          content: valid
              ? SizedBox(
                  width: 320,
                  child: ListBody(
                    children: [
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
                )
              : const Text('このプリセットのモジュール順序が未知の値です。変更できません。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル'),
            ),
            if (valid)
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
      title: const Text('FB200 コントロール'),
      actions: [
        IconButton(
          tooltip: '本体と同期',
          onPressed: _busy
              ? null
              : () => _run('同期中', () async {
                  await _pedal.refresh();
                  await _pedal.loadBank(_bank);
                  if (_irs != null) await _irReload();
                }),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _tab,
      onDestinationSelected: (v) {
        setState(() => _tab = v);
        if (v == 3 && _irs == null && !_busy) {
          _run('IR一覧を読み込み中', _irReload);
        }
      },
      destinations: const [
        NavigationDestination(icon: Icon(Icons.grid_view), label: 'プリセット'),
        NavigationDestination(icon: Icon(Icons.tune), label: 'エフェクト'),
        NavigationDestination(icon: Icon(Icons.music_note), label: 'ツール'),
        NavigationDestination(icon: Icon(Icons.graphic_eq), label: 'IR'),
        NavigationDestination(icon: Icon(Icons.settings), label: '設定'),
      ],
    ),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (_busy) ...[const LinearProgressIndicator(), Text(_status)],
              if (_error.isNotEmpty)
                Text(
                  _error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (_ready) ...[
                Text(
                  '${PedalClient.address(_pedal.selected)}  ${_pedal.edit!.name}',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                Text(
                  '${_pedal.version}  ·  電池 ${_pedal.battery}%${_pedal.charging ? '（充電中）' : ''}',
                ),
                const SizedBox(height: 20),
                ...switch (_tab) {
                  0 => _banks(),
                  1 => _effects(),
                  2 => _tools(),
                  3 => _ir(),
                  _ => _settings(),
                },
              ],
            ],
          ),
        ),
      ),
    ),
  );

  List<Widget> _banks() => [
    DropdownButtonFormField<int>(
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
    const SizedBox(height: 12),
    for (var i = _bank * 4; i < _bank * 4 + 4; i++)
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${PedalClient.address(i)}  ${_pedal.presets[i]?.name ?? '読み込み前'}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.tonal(
                    onPressed: _busy
                        ? null
                        : () => _run('プリセットを選択中', () => _pedal.select(i)),
                    child: Text(i == _pedal.selected ? '再読み込み' : '選択'),
                  ),
                  TextButton(
                    onPressed: _busy ? null : () => _save(i, _pedal.edit!),
                    child: const Text('編集内容を保存'),
                  ),
                  TextButton(
                    onPressed: _busy ? null : () => _guard(() => _rename(i)),
                    child: const Text('名前'),
                  ),
                  TextButton(
                    onPressed: _busy ? null : () => _guard(() => _copy(i)),
                    child: const Text('コピー'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    const SizedBox(height: 12),
    OutlinedButton.icon(
      onPressed: _busy ? null : _backup,
      icon: const Icon(Icons.download),
      label: const Text('全プリセットをファイルへ保存'),
    ),
    TextButton(
      onPressed: _busy ? null : () => _guard(_restore),
      child: const Text('バックアップから復元'),
    ),
  ];

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

  List<Widget> _effects() => [
    if (widget.restrictedNam && !widget.effectsAvailable)
      const Text('現在のNAM版ではアンプをNAMに置き換えています。キャビネット・MOD・リバーブは本体の更新後に利用できます。'),
    if (widget.restrictedNam && widget.effectsAvailable)
      const Text('現在のNAM版ではアンプをNAMに置き換えています。キャビネット・MOD・リバーブはNAMの後段で動作します。'),
    ListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('モジュールの接続順'),
      subtitle: const Text('エフェクトチェーンの並び順を変更します（保存で プリセットに反映）。'),
      trailing: const Icon(Icons.chevron_right),
      onTap: _busy ? null : () => _guard(_editModuleOrder),
    ),
    for (final module in pedalModules.where(
      (m) => m.command != 0x85 || widget.restrictedNam,
    ))
      ExpansionTile(
        title: Text(module.name),
        children: [
          for (var i = 0; i < module.fields.length; i++)
            if (module.fields[i].max > 0)
              _value(
                module.fields[i].label,
                _pedal.edit!.word(module.offset + i * 2),
                module.fields[i].min,
                module.fields[i].max,
                (value) => _run(
                  'エフェクトを更新中',
                  () => _pedal.module(module, [
                    for (var k = 0; k < module.fields.length; k++)
                      k == i ? value : _pedal.edit!.word(module.offset + k * 2),
                  ]),
                ),
                disabled:
                    (widget.restrictedNam &&
                        !widget.effectsAvailable &&
                        [0x83, 0x84, 0x86].contains(module.command)) ||
                    (widget.restrictedNam && module.command == 0x82 && i != 0),
              ),
        ],
      ),
  ];
  Widget _value(
    String label,
    int value,
    int min,
    int max,
    void Function(int) change, {
    bool disabled = false,
  }) {
    var draft = value.clamp(min, max);
    return StatefulBuilder(
      builder: (context, setLocal) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            Text('$label  $draft'),
            Slider(
              value: draft.toDouble(),
              min: min.toDouble(),
              max: max.toDouble(),
              divisions: max - min <= 100 ? max - min : null,
              label: '$draft',
              onChanged: _busy || disabled
                  ? null
                  : (v) => setLocal(() => draft = v.round()),
              onChangeEnd: _busy || disabled ? null : (v) => change(v.round()),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _tools() {
    final r = _pedal.rhythm!, s = _pedal.settings!;
    return [
      if (!widget.toolsAvailable) const Text('ドラムとチューナーは本体の更新後に利用できます。'),
      Text('ドラムマシン', style: Theme.of(context).textTheme.titleLarge),
      SwitchListTile(
        title: const Text('再生'),
        value: r[0] != 0,
        onChanged: _busy || !widget.toolsAvailable
            ? null
            : (v) => _rhythm(on: v),
      ),
      _value(
        'パターン',
        r[2] + 1,
        1,
        40,
        (v) => _rhythm(pattern: v - 1),
        disabled: !widget.toolsAvailable,
      ),
      _value(
        'テンポ (BPM)',
        read16(r, 4),
        40,
        260,
        (v) => _rhythm(bpm: v),
        disabled: !widget.toolsAvailable,
      ),
      _value(
        '音量',
        r[3],
        0,
        100,
        (v) => _rhythm(level: v),
        disabled: !widget.toolsAvailable,
      ),
      OutlinedButton(
        onPressed: _busy || !widget.toolsAvailable
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
      const SizedBox(height: 28),
      Text('チューナー', style: Theme.of(context).textTheme.titleLarge),
      SwitchListTile(
        title: const Text('チューナーを起動'),
        value: s[8] != 0,
        onChanged: _busy || !widget.toolsAvailable
            ? null
            : (v) => _tuner(on: v),
      ),
      SwitchListTile(
        title: const Text('チューニング中はミュート'),
        value: s[9] != 0,
        onChanged: _busy || !widget.toolsAvailable
            ? null
            : (v) => _tuner(mute: v),
      ),
      _value(
        '基準 A4 (Hz)',
        435 + s[7],
        435,
        450,
        (v) => _tuner(a4: v),
        disabled: !widget.toolsAvailable,
      ),
      if (widget.toolsAvailable && widget.restrictedNam)
        Text(_pitch, style: Theme.of(context).textTheme.headlineMedium)
      else
        const Text('音程は本体のディスプレイで確認できます。'),
      const SizedBox(height: 28),
      Text('ルーパー', style: Theme.of(context).textTheme.titleLarge),
      if (!_looperAvailable)
        const Text('ルーパーはこのファームウェアでは利用できません。')
      else ...[
        Text(() {
          final s = _loop;
          if (s == null) return '状態を確認中…';
          final undo = s.undo == 0
              ? ''
              : s.undo == 1
              ? '・元に戻す可'
              : '・やり直し可';
          return '${PedalClient.looperStates[s.state.clamp(0, 5)]}'
              '  長さ ${s.lenS}秒 / 最大 ${s.maxS}秒$undo'
              '${s.storeBusy ? '・保存中' : ''}${s.writing ? '・書込中' : ''}';
        }()),
        const SizedBox(height: 8),
        Wrap(
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
        _value(
          'ループの音量',
          _loop?.level ?? 100,
          0,
          100,
          (v) => _run('ループ音量を変更中', () async {
            await _pedal.looperLevel(v);
            await _refreshLoop();
          }),
        ),
        Wrap(
          spacing: 8,
          children: [
            for (var slot = 1; slot <= 2; slot++) ...[
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _run('ループ$slotを保存中', () => _pedal.looperSave(slot)),
                child: Text('スロット$slotへ保存'),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _run('ループ$slotを読込中', () async {
                        await _pedal.looperLoad(slot);
                        await _refreshLoop();
                      }),
                child: Text('スロット$slotから読込'),
              ),
            ],
          ],
        ),
        const Text(
          '保存は2スロット。電源を切ってもループが残ります。本体のフットスイッチ（D+C長押しでルーパーモード）でも操作できます。',
        ),
      ],
    ];
  }

  List<Widget> _ir() {
    final slots = _irs;
    return [
      if (widget.restrictedNam && !widget.effectsAvailable)
        const Text(
          '現在のNAMファームウェアではキャビネットIRは音声処理に使われません。保存したIRはストックファームウェアで利用できます。',
        ),
      Text('ユーザーIR', style: Theme.of(context).textTheme.titleLarge),
      const Text('WAVを読み込んでスロットへ転送します。変換は公式エディタと同じ44.1 kHz・チャンネル0・1024サンプルです。'),
      const SizedBox(height: 8),
      if (slots == null)
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _run('IR一覧を読み込み中', _irReload),
          icon: const Icon(Icons.refresh),
          label: const Text('IR一覧を読み込む'),
        )
      else
        for (final s in slots)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'IR${s.slot}  ${s.used ? s.name : '空き'}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.tonal(
                        onPressed: _busy
                            ? null
                            : () => _guard(() => _irImport(s)),
                        child: const Text('WAVから取り込み'),
                      ),
                      if (s.used) ...[
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _guard(() => _irRename(s)),
                          child: const Text('名前'),
                        ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _guard(() => _irDelete(s)),
                          child: const Text('削除'),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
    ];
  }

  List<Widget> _settings() {
    final s = _pedal.settings!;
    return [
      _value('入力ゲイン', s[2], 0, 25, (v) => _setting(2, v)),
      SwitchListTile(
        title: const Text('グローバル・キャビネット'),
        value: s[1] != 0,
        onChanged: _busy || (widget.restrictedNam && !widget.effectsAvailable)
            ? null
            : (v) => _setting(1, v ? 1 : 0),
      ),
      SwitchListTile(
        title: const Text('Bluetoothオーディオ'),
        value: s[10] != 0,
        onChanged: _busy || (widget.restrictedNam && !widget.btAudioAvailable)
            ? null
            : (v) => _setting(10, v ? 1 : 0),
      ),
      _value('現在のスロットのLED色', s[11], 0, 9, (v) => _setting(11, v)),
      _value('現在のスロットのLED明るさ', s[12], 0, 100, (v) => _setting(12, v)),
      const SizedBox(height: 20),
      Text('Bluetooth', style: Theme.of(context).textTheme.titleLarge),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Bluetooth名の変更'),
        subtitle: const Text(
          '半角英数字・記号で1〜20文字。現在の名前は本体から読み取れないため、変更は再接続後に本体側で確認してください。',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: _busy ? null : () => _guard(_btName),
      ),
    ];
  }
}
