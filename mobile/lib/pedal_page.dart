import 'localization.dart';

import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import 'ir_wav.dart' show WavError, wavToIr;
import 'nam_client.dart' show DeviceState, NamClient;
import 'nam_tone.dart';
import 'effect_parameters.dart';
import 'connection_recovery.dart';
import 'widgets/recovery_layer.dart';
import 'studio_theme.dart';

import 'pedal_client.dart';
import 'protocol.dart';
import 'pedal/drums_tab.dart';
import 'pedal/effect_dialogs.dart';
import 'pedal/ir_tab.dart';
import 'pedal/looper_tab.dart';
import 'pedal/nam_model_selector.dart';
import 'pedal/pedal_nav_bar.dart';
import 'pedal/presets_tab.dart';
import 'pedal/settings_tab.dart';
import 'pedal/tuner_tab.dart';
import 'widgets/chain_strip.dart';
import 'widgets/dialogs.dart';
import 'widgets/knob.dart';
import 'widgets/nam_model_picker.dart';
import 'widgets/parameter_deck.dart';
import 'widgets/effect_choice.dart';

class PedalPage extends StatefulWidget {
  final WireTransport transport;
  final ConnectionRecovery? recovery;
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
    this.recovery,
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
  PedalTab _tab = PedalTab.effects;
  int _bank = 0;
  bool _working = false, _ready = false;
  bool _blocking = false;
  bool get _busy =>
      _working ||
      _toneDraft != null ||
      (widget.recovery != null && !widget.recovery!.connected);
  String _error = '', _status = '';
  DateTime? _lastTap;
  Future<void>? _poll;
  String _pitch = '—';
  List<IrSlotInfo>? _irs;
  DeviceState? _namState;
  bool _libraryOpen = false;
  RecoveryDraft? _pendingEdit;
  RecoveryDraft? _toneDraft, _toneQueued;
  Future<void>? _tonePreviewWork;
  int? _toneField;

  @override
  void initState() {
    super.initState();
    _pedal = PedalClient(widget.transport, namAware: widget.restrictedNam)
      ..addListener(_changed);
    _namState = widget.namState;
    widget.recovery?.addListener(_connectionChanged);
    widget.recovery?.addResynchronizer(_resynchronize);
    unawaited(
      _run(tr("本体を読み込み中"), () async {
        await _pedal.initialize();
        _bank = _pedal.selected ~/ 4;
        await _pedal.loadBank(_bank);
        await _refreshNam();
        await _irReload();
        _ready = true;
        await _probeLooper();
      }),
    );
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_ready && !_busy && !_libraryOpen && _pedal.refreshRequired) {
        unawaited(
          _run(tr("本体を同期中"), () async {
            await _pedal.refresh();
            _bank = _pedal.selected ~/ 4;
            await _pedal.loadBank(_bank);
            await _refreshNam();
          }, blocking: false),
        );
      } else if (_ready &&
          !_busy &&
          !_libraryOpen &&
          _poll == null &&
          _tab == PedalTab.tuner &&
          widget.toolsAvailable &&
          widget.restrictedNam &&
          _pedal.settings![8] != 0) {
        _poll = _readPitch().whenComplete(() => _poll = null);
      } else if (_ready &&
          !_busy &&
          !_libraryOpen &&
          _poll == null &&
          _tab == PedalTab.looper &&
          _looperAvailable) {
        _poll = _refreshLoop().whenComplete(() => _poll = null);
      }
    });
  }

  void _connectionChanged() {
    final recovery = widget.recovery;
    if (recovery == null || !mounted) return;
    if (recovery.phase == RecoveryPhase.disconnected) {
      if (_pendingEdit case final pending?) {
        recovery.keepDraft(pending.preset, pending.bytes);
      } else if (_dirty) {
        recovery.keepDraft(
          _pedal.editIndex ?? _pedal.selected,
          _pedal.edit!.bytes,
        );
      }
      _toneQueued = null;
      _toneDraft = null;
    }
    setState(() {});
  }

  Future<void> _resynchronize() async {
    if (!mounted) return;
    _toneQueued = null;
    _toneDraft = null;
    _pendingEdit = null;
    await _pedal.initialize();
    if (!mounted) return;
    _bank = _pedal.selected ~/ 4;
    await _pedal.loadBank(_bank);
    if (!mounted) return;
    await _refreshNam(reuseSlots: true);
    await _irReload();
    final recovery = widget.recovery;
    final draft = recovery?.draft;
    if (draft != null &&
        draft.preset == _pedal.selected &&
        listEquals(draft.bytes, _pedal.edit!.bytes)) {
      recovery!.clearDraft();
    }
    if (mounted) {
      setState(() {
        _ready = true;
        _error = '';
      });
    }
  }

  Future<void> _restoreDraft() async {
    final recovery = widget.recovery;
    final draft = recovery?.draft;
    if (_busy || recovery == null || draft == null) return;
    if (!await _confirm(
      tr("{0}へ下書きの編集を戻します。音色が切り替わります。プリセットへの記録は、その後「保存」で行ってください。", [
        PedalClient.address(draft.preset),
      ]),
      title: tr("下書きを本体へ戻す"),
      accept: tr("編集を戻す"),
    )) {
      return;
    }
    await _run(tr("下書きを復元中"), () async {
      await _pedal.select(draft.preset);
      var restored = PedalPreset(draft.bytes);
      if (widget.restrictedNam && restored.word(0xde) != 0x414e) {
        restored = restored.setWord(0xde, 0x414e).setWord(0xe0, 0);
      }
      await widget.transport.sendCommand(0x97, [255, ...restored.bytes]);
      await _pedal.refresh();
      if (_pedal.selected != draft.preset ||
          !listEquals(restored.bytes, _pedal.edit!.bytes)) {
        throw DeviceError(tr("下書きの復元結果を確認できませんでした。下書きは保持しています。"));
      }
      _bank = _pedal.selected ~/ 4;
      await _pedal.loadBank(_bank);
      await _refreshNam();
      recovery.clearDraft();
    });
  }

  void _changed() {
    if (mounted) {
      setState(() {
        if (_toneDraft != null &&
            (_toneDraft!.preset != _pedal.selected || _pedal.refreshRequired)) {
          _toneQueued = null;
          _toneDraft = null;
          _toneField = null;
          _pendingEdit = null;
        }
        if (_pedal.irSlots.length == PedalClient.irSlotCount) {
          _irs = _pedal.irSlots.values.toList()
            ..sort((a, b) => a.slot.compareTo(b.slot));
        }
      });
    }
  }

  Future<void> _refreshNam({
    bool reloadSlots = false,
    bool reuseSlots = false,
  }) async {
    final client = widget.namClient;
    if (client == null) return;
    final fresh = reloadSlots || reuseSlots || _namState == null
        ? await client.readState(reuse: reuseSlots)
        : DeviceState(await client.readSelection(), _namState!.slots);
    if (mounted) setState(() => _namState = fresh);
  }

  String? get _activeModel => _namState?.slots
      .where((s) => s.number == _namState!.selected)
      .firstOrNull
      ?.name;

  bool get _dirty =>
      _toneDraft != null ||
      (_ready &&
          !listEquals(
            _pedal.edit?.bytes,
            _pedal.presets[_pedal.editIndex ?? _pedal.selected]?.bytes,
          ));

  Future<void> _selectPreset(int index) async {
    if (index == _pedal.selected || _busy) return;
    if (_dirty &&
        !await _confirm(
          tr("未保存の編集を破棄してプリセットを切り替えますか？"),
          title: tr("プリセットを切り替え"),
          accept: tr("切り替える"),
        )) {
      return;
    }
    await _run(tr("プリセットを選択中"), () async {
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
        await _run(tr("モデルを同期中"), () async {
          await _pedal.refresh();
          await _pedal.loadBank(_bank);
          await _refreshNam(reloadSlots: true);
        });
      }
    } finally {
      if (mounted) setState(() => _libraryOpen = false);
    }
  }

  Future<void> _run(
    String status,
    Future<void> Function() action, {
    bool blocking = true,
  }) async {
    if (_busy || !mounted) return;
    setState(() {
      _working = true;
      _blocking = blocking;
      _error = '';
      _status = status;
    });
    try {
      final binding = widget.transport.connectionGeneration;
      await _poll;
      await _tonePreviewWork;
      await widget.transport.waitIdle();
      if (widget.transport.isClosed ||
          binding != widget.transport.connectionGeneration) {
        throw DeviceError(tr("接続が切り替わりました。復旧後に操作をやり直してください。"));
      }
      await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is DeviceError
              ? e.message
              : tr("操作を完了できませんでした。接続と本体の状態を確認してください。"),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _working = false;
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

  Future<bool> _confirm(String text, {String? title, String? accept}) =>
      confirmDialog(
        context,
        title: title ?? tr("本体へ保存"),
        content: Text(text),
        accept: accept ?? tr("保存する"),
      );

  Future<void> _save(int destination, PedalPreset preset) async {
    if (!await _confirm(
      tr("{0} を「{1}」で上書きします。このプリセットを使っている音色が変わります。", [
        PedalClient.address(destination),
        preset.name,
      ]),
    )) {
      return;
    }
    await _run(tr("プリセットを保存・照合中"), () async {
      await _pedal.store(destination, preset);
      await _pedal.loadBank(_bank);
      await _refreshNam();
    });
  }

  Future<void> _rename(int index) async {
    final preset = await _pedal.readPreset(index);
    if (!mounted) return;
    final name = await _askName(
      tr("{0} の名前", [PedalClient.address(index)]),
      preset.name,
      20,
    );
    if (name != null && mounted) await _save(index, preset.renamed(name));
  }

  Future<void> _copy(int index) async {
    final source = await _pedal.readPreset(index);
    if (!mounted) return;
    final destination = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(tr("{0} のコピー先", [PedalClient.address(index)])),
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

  Future<void> _backup() => _run(tr("40プリセットをバックアップ中"), () async {
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
        throw DeviceError(tr("64 KB以下のバックアップを選択してください。"));
      }
      bytes.add(chunk);
    }
    final presets = PedalClient.parseBackup(bytes.takeBytes());
    if (!mounted ||
        !await _confirm(
          tr(
            "全40プリセットをバックアップの内容で上書きします。復元中は接続を維持してください。途中で切れた場合、完了したプリセットだけが復元されます。NAMモデル本体やIRデータは含みません。",
          ),
        )) {
      return;
    }
    await _run(tr("プリセットを復元中"), () async {
      final original = _pedal.selected;
      for (var i = 0; i < 40; i++) {
        if (mounted) setState(() => _status = tr("{0}/40 を復元・照合中", [i + 1]));
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

  Future<String?> _askName(String title, String initial, int maxLength) =>
      askText(
        context,
        title: title,
        initial: initial,
        maxLength: maxLength,
        helper: tr("半角英数字・記号"),
        accept: tr("次へ"),
      );

  Future<void> _irImport(IrSlotInfo slot) async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['wav'],
    );
    if (file == null || !mounted) return;
    final bytes = BytesBuilder();
    await for (final chunk in file.readAsByteStream()) {
      if (bytes.length + chunk.length > 8 * 1024 * 1024) {
        throw DeviceError(tr("8MB以下のWAVファイルを選択してください。"));
      }
      bytes.add(chunk);
    }
    final samples = _guardWav(bytes.takeBytes());
    if (!mounted) return;
    final stem = file.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
    final name = await _askName(tr("IR{0} の名前", [slot.slot]), stem, 50);
    if (name == null || name.trim().isEmpty || !mounted) return;
    if (slot.used &&
        !await _confirm(
          tr("IR{0} 「{1}」を「{2}」で上書きします。", [
            slot.slot,
            slot.name,
            PedalClient.sanitizeIrName(name),
          ]),
          title: tr("IRを上書き"),
          accept: tr("上書きする"),
        )) {
      return;
    }
    await _run(tr("IRを転送中"), () async {
      await _pedal.irUpload(
        slot.slot,
        name,
        samples,
        progress: (sent, total) {
          if (mounted) {
            setState(() => _status = tr("IRを転送中 ({0}/{1})", [sent, total]));
          }
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
    final name = await _askName(tr("IR{0} の名前", [slot.slot]), slot.name, 50);
    if (name == null || name.trim().isEmpty || !mounted) return;
    await _run(tr("IR名を変更中"), () async {
      await _pedal.irRename(slot.slot, name);
      await _irReload();
    });
  }

  Future<void> _irDelete(IrSlotInfo slot) async {
    if (!await _confirm(
      tr("IR{0} 「{1}」を削除します。このIRを使うプリセットの音が変わります。", [slot.slot, slot.name]),
      title: tr("IRを削除"),
      accept: tr("削除する"),
    )) {
      return;
    }
    await _run(tr("IRを削除中"), () async {
      await _pedal.irDelete(slot.slot);
      await _irReload();
    });
  }

  Future<void> _btName() async {
    final name = await _askName(tr("Bluetooth名"), '', 20);
    if (name == null || name.isEmpty || !mounted) return;
    await _run(tr("Bluetooth名を送信中"), () async {
      await _pedal.setBtName(name);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr("Bluetooth名を送信しました。反映を確認するには再接続してください。"))),
        );
      }
    });
  }

  Future<void> _rhythm({bool? on, int? pattern, int? level, int? bpm}) =>
      _run(tr("ドラムを設定中"), () async {
        final r = _pedal.rhythm!;
        await _pedal.setRhythm(
          on: on ?? r[0] != 0,
          pattern: pattern ?? r[2],
          level: level ?? r[3],
          bpm: bpm ?? read16(r, 4),
        );
      });
  Future<void> _tuner({bool? on, bool? mute, int? a4}) =>
      _run(tr("チューナーを設定中"), () async {
        final s = _pedal.settings!;
        await _pedal.setTuner(
          on: on ?? s[8] != 0,
          mute: mute ?? s[9] != 0,
          a4: a4 ?? 435 + s[7],
        );
      });
  Future<void> _setting(int index, int value) => _run(tr("本体設定を更新中"), () async {
    final s = Uint8List.fromList(_pedal.settings!)..[index] = value;
    await _pedal.setSettings(s);
  });

  // ---- looper ----

  bool _looperAvailable = false;
  LooperStatus? _loop;

  Future<void> _editModuleOrder() async {
    final order = await editModuleOrder(
      context,
      _pedal.edit!.bytes.sublist(0xbc, 0xc3),
    );
    if (order == null || !mounted) return;
    await _run(tr("モジュール順序を変更中"), () async {
      await _pedal.setModuleOrder(order);
      await _pedal.refresh();
    });
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
    if (code == 1) throw DeviceError(tr("今は実行できません（録音中の確定待ちなど）。"));
    if (code == 2) throw DeviceError(tr("ルーパー用のフラッシュ領域がありません。"));
    if (code == 3) throw DeviceError(tr("フラッシュの準備中です。少し待って再試行してください。"));
    await _refreshLoop();
  });

  Future<void> _looperClear() async {
    if (!await _confirm(
      tr("ループを消去します。取り消せません。"),
      title: tr("ループを消去"),
      accept: tr("消去する"),
    )) {
      return;
    }
    await _looperAct(7, tr("ループを消去中"));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _toneQueued = null;
    widget.recovery?.removeListener(_connectionChanged);
    widget.recovery?.removeResynchronizer(_resynchronize);
    _pedal.removeListener(_changed);
    _pedal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: _ready && MediaQuery.sizeOf(context).height < 480
          ? Text(
              '${PedalClient.address(_pedal.selected)}  ${_pedal.edit!.name}',
              overflow: TextOverflow.ellipsis,
            )
          : const Text('FB200 STUDIO'),
      actions: [
        if (_ready && MediaQuery.sizeOf(context).height < 480)
          IconButton(
            tooltip: tr("保存"),
            onPressed: _busy
                ? null
                : () => _save(_pedal.selected, _pedal.edit!),
            icon: const Icon(Icons.save_outlined, color: StudioTheme.nam),
          ),
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
          tooltip: tr("本体と同期"),
          onPressed: _busy
              ? null
              : () => _run(tr("同期中"), () async {
                  await _pedal.refresh();
                  _bank = _pedal.selected ~/ 4;
                  await _pedal.loadBank(_bank);
                  await _refreshNam(reloadSlots: true);
                  if (_irs != null) await _irReload();
                }),
          icon: const Icon(Icons.sync, size: 21),
        ),
      ],
    ),
    bottomNavigationBar: PedalNavBar(
      tab: _tab,
      onSelect: _toneDraft != null ? null : _selectTab,
    ),
    body: RecoveryLayer(
      recovery: widget.recovery,
      child: SafeArea(
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
                            vertical: MediaQuery.sizeOf(context).height < 480
                                ? 4
                                : 8,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (MediaQuery.sizeOf(context).height >= 480)
                                _presetHeader(),
                              if (_error.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 6,
                                  ),
                                  child: Text(
                                    _error,
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error,
                                    ),
                                  ),
                                ),
                              if (MediaQuery.sizeOf(context).height >= 480)
                                const SizedBox(height: 12),
                              Expanded(child: _tabBody()),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            if (_working && _blocking && _status != tr("エフェクトを更新中")) ...[
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
    ),
    bottomSheet:
        widget.recovery?.connected == true && widget.recovery?.draft != null
        ? Material(
            color: StudioTheme.panel,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Wrap(
                  spacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(tr("切断前の未保存の下書きがあります")),
                    TextButton(
                      onPressed: _busy ? null : _restoreDraft,
                      child: Text(tr("下書きを本体へ戻す")),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => widget.recovery!.clearDraft(),
                      child: Text(tr("本体の状態を使う")),
                    ),
                  ],
                ),
              ),
            ),
          )
        : null,
  );

  Widget _presetHeader() => PresetHeader(
    selected: _pedal.selected,
    name: _pedal.edit!.name,
    dirty: _dirty,
    busy: _busy,
    onSave: () => _save(_pedal.selected, _pedal.edit!),
  );

  Widget _presetSidebar() => PresetSidebar(
    bank: _bank,
    selected: _pedal.selected,
    presets: _pedal.presets,
    version: _pedal.version,
    busy: _busy,
    onBank: _loadBank,
    onSelect: _selectPreset,
    onManage: () => setState(() => _tab = PedalTab.presets),
    onOpenModels: widget.onOpenModels == null ? null : _openModels,
  );

  /// Management and tool pages may scroll. The performance editor uses a
  /// separately bounded layout and never passes through this wrapper.
  Widget _fillOrScroll(Widget child) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: child,
      ),
    ),
  );

  Widget _tabBody() => switch (_tab) {
    PedalTab.effects => _effects(),
    PedalTab.presets => _fillOrScroll(
      PresetsTab(
        bank: _bank,
        selected: _pedal.selected,
        presets: _pedal.presets,
        busy: _busy,
        onBank: _loadBank,
        onSelect: _selectPreset,
        onBackup: () => _run(tr("バックアップ中"), _backup),
        onRestore: () => _guard(_restore),
        onSave: () => _save(_pedal.selected, _pedal.edit!),
        onRename: () => _guard(() => _rename(_presetMenuTarget())),
        onCopy: () => _guard(() => _copy(_presetMenuTarget())),
      ),
    ),
    PedalTab.drums => _fillOrScroll(
      DrumsTab(
        rhythm: _pedal.rhythm!,
        available: widget.toolsAvailable,
        busy: _busy,
        onRhythm: _rhythm,
        onTapTempo: _tapTempo,
      ),
    ),
    PedalTab.tuner => _fillOrScroll(
      TunerTab(
        settings: _pedal.settings!,
        available: widget.toolsAvailable,
        busy: _busy,
        showsPitch: widget.restrictedNam,
        pitch: _pitch,
        onTuner: _tuner,
      ),
    ),
    PedalTab.looper => _fillOrScroll(
      LooperTab(
        available: _looperAvailable,
        busy: _busy,
        status: _loop,
        onAction: (op) => _looperAct(op, tr("ルーパーを操作中")),
        onClear: _looperClear,
        onLevel: (v) => _run(tr("ループ音量を変更中"), () async {
          await _pedal.looperLevel(v);
          await _refreshLoop();
        }),
        onSave: (slot) =>
            _run(tr("ループ{0}を保存中", [slot]), () => _pedal.looperSave(slot)),
        onLoad: (slot) => _run(tr("ループ{0}を読込中", [slot]), () async {
          await _pedal.looperLoad(slot);
          await _refreshLoop();
        }),
      ),
    ),
    PedalTab.ir => _fillOrScroll(
      IrTab(
        slots: _irs,
        edit: _pedal.edit!,
        busy: _busy,
        cabinetProcessed: !(widget.restrictedNam && !widget.effectsAvailable),
        onLoad: () => _run(tr("IR一覧を読み込み中"), _irReload),
        onSlot: (s) => _guard(() => _irSlotMenu(s)),
      ),
    ),
    PedalTab.settings => _fillOrScroll(
      SettingsTab(
        settings: _pedal.settings!,
        busy: _busy,
        cabinetAvailable: !(widget.restrictedNam && !widget.effectsAvailable),
        btAudioAvailable: !(widget.restrictedNam && !widget.btAudioAvailable),
        onSetting: _setting,
        onBtName: () => _guard(_btName),
      ),
    ),
  };

  void _selectTab(PedalTab tab) {
    setState(() => _tab = tab);
    if (tab == PedalTab.ir && _irs == null && !_busy) {
      _run(tr("IR一覧を読み込み中"), _irReload);
    }
  }

  Future<void> _loadBank(int bank) => _run(tr("バンクを読み込み中"), () async {
    _bank = bank;
    await _pedal.loadBank(_bank);
  });

  void _tapTempo() {
    final now = DateTime.now(), previous = _lastTap;
    _lastTap = now;
    if (previous != null) {
      final dt = now.difference(previous).inMilliseconds;
      if (dt > 0 && dt <= 3000) {
        _rhythm(bpm: (60000 / dt).round().clamp(40, 260));
      }
    }
  }

  int _presetMenuTarget() => _pedal.selected;

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is DeviceError ? e.message : tr("操作を完了できませんでした。"),
        );
      }
    }
  }

  Future<void> _changeModule(PedalModule module, List<int> values) async {
    if (_busy) return;
    var wanted = _pedal.edit!;
    for (var i = 0; i < values.length; i++) {
      wanted = wanted.setWord(module.offset + i * 2, values[i]);
    }
    if (module.command == 0x85) wanted = wanted.setWord(0x96, 0x4c44);
    _pendingEdit = RecoveryDraft(_pedal.selected, wanted.bytes);
    try {
      await _run(tr("エフェクトを更新中"), () => _pedal.module(module, values));
    } finally {
      _pendingEdit = null;
    }
  }

  void _previewNamTone(int field, int value) {
    if (_working ||
        !mounted ||
        _pedal.refreshRequired ||
        _pedal.editIndex != _pedal.selected ||
        (widget.recovery != null && !widget.recovery!.connected)) {
      return;
    }
    final base = _pedal.edit!.bytes;
    final wanted = PedalPreset(base).setWord(0x2c + field * 2, value);
    setState(() {
      _toneField = field;
      _toneDraft = RecoveryDraft(_pedal.selected, wanted.bytes);
      _toneQueued = _toneDraft;
      _pendingEdit = _toneDraft;
    });
    if (_tonePreviewWork != null) return;
    final work = _sendTonePreviews(widget.transport.connectionGeneration);
    _tonePreviewWork = work;
    unawaited(
      work.whenComplete(() {
        if (identical(_tonePreviewWork, work)) _tonePreviewWork = null;
      }),
    );
  }

  Future<void> _sendTonePreviews(int binding) async {
    try {
      while (_toneQueued != null) {
        var wanted = _toneQueued!;
        _toneQueued = null;
        await widget.transport.waitIdle();
        if (_toneQueued != null) {
          wanted = _toneQueued!;
          _toneQueued = null;
        }
        if (!mounted ||
            widget.transport.isClosed ||
            widget.transport.connectionGeneration != binding ||
            _pedal.selected != wanted.preset ||
            _pedal.editIndex != wanted.preset ||
            _pedal.refreshRequired) {
          return;
        }
        final field = _toneField;
        if (field == null) return;
        final live = _pedal.edit!.setWord(
          0x2c + field * 2,
          PedalPreset(wanted.bytes).word(0x2c + field * 2),
        );
        await widget.transport.sendCommand(
          0x82,
          live.bytes.sublist(0x2c, 0x3c),
        );
      }
    } catch (e) {
      _toneQueued = null;
      if (mounted) {
        setState(
          () => _error = e is DeviceError ? e.message : tr("音色の反映を確認できませんでした。"),
        );
      }
    }
  }

  Future<void> _finishNamTone(int field, int value) async {
    if (_working ||
        !mounted ||
        _pedal.refreshRequired ||
        _pedal.editIndex != _pedal.selected ||
        (widget.recovery != null && !widget.recovery!.connected)) {
      return;
    }
    _previewNamTone(
      field,
      value,
    ); // flush the final value even below the 80 ms interval
    setState(() => _toneDraft = null);
    try {
      await _run(tr("NAM音色を確認中"), () async {
        await _pedal.refresh();
        if (_pedal.edit!.word(0x2c + field * 2) != value) {
          throw DeviceError(tr("本体への反映を確認できませんでした。表示値を確認して再操作してください。"));
        }
        await _refreshNam();
      }, blocking: false);
    } finally {
      _pendingEdit = null;
      _toneField = null;
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

  void _editorAction(int action) {
    if (action >= 0) {
      setState(() => _selectedModule = action);
    } else if (action == -1) {
      _guard(_editModuleOrder);
    } else {
      showEditorHelp(context);
    }
  }

  Widget _editorMenu(List<int> modules, {bool includeModules = false}) =>
      PopupMenuButton<int>(
        enabled: !_busy,
        tooltip: includeModules ? tr("エフェクトを選ぶ") : tr("エディターの詳細"),
        icon: Icon(
          includeModules ? Icons.account_tree_outlined : Icons.more_horiz,
        ),
        onSelected: _editorAction,
        itemBuilder: (_) => [
          if (includeModules) ...[
            for (final m in modules)
              PopupMenuItem(
                value: m,
                child: Text(
                  widget.restrictedNam && m == 2
                      ? 'NAM A2 LITE'
                      : pedalModules[m].name,
                ),
              ),
            const PopupMenuDivider(),
          ],
          PopupMenuItem(value: -2, child: Text(tr("操作方法"))),
          PopupMenuItem(value: -1, child: Text(tr("モジュールの接続順"))),
        ],
      );

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
    final parameters = EffectParameters.forModule(
      module,
      _pedal.edit!,
      irSlots: _irs,
    );
    final fields = isNam
        ? const [2, 3, 4, 6, 5, 7]
        : parameters.map((p) => p.field).toList();
    final toggle = Switch(
      value: enabled.contains(selected),
      activeTrackColor: accent,
      onChanged: _busy || unsupported || (isNam && _namState?.selected == 0)
          ? null
          : (v) => _changeModule(module, [
              for (var k = 0; k < module.fields.length; k++)
                k == 0 ? (v ? 1 : 0) : _pedal.edit!.word(module.offset + k * 2),
            ]),
    );
    return LayoutBuilder(
      builder: (context, box) {
        // A short translated header can make the chain just fit its old
        // height threshold while its wrapped rows crowd out the controls.
        // Account for the actual chain width before choosing that layout.
        final chainMinimum =
            40 + MediaQuery.textScalerOf(context).scale(11) * 4;
        final chainColumns = (box.maxWidth / chainMinimum).floor().clamp(
          1,
          visible.length,
        );
        final chainRows = (visible.length / chainColumns).ceil();
        final tight = box.maxHeight < 440 + (chainRows - 1) * 80;
        final veryShort = box.maxHeight < 270;
        return Column(
          key: const ValueKey('fixed-editor'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!tight) ...[
              ChainStrip(
                order: visible,
                enabled: enabled,
                compact: true,
                unavailable: widget.restrictedNam && !widget.effectsAvailable
                    ? const {3, 4, 6}
                    : const {},
                selected: visible.indexOf(selected),
                restrictedNam: widget.restrictedNam,
                namModel: _namState == null ? widget.namModel : _activeModel,
                onTap: (i) {
                  if (!_busy) setState(() => _selectedModule = visible[i]);
                },
              ),
              const SizedBox(height: 10),
            ],
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (veryShort && isNam)
                        Row(
                          children: [
                            _editorMenu(visible, includeModules: true),
                            Expanded(child: _namModelSelector()),
                            toggle,
                          ],
                        )
                      else ...[
                        Row(
                          children: [
                            if (tight)
                              _editorMenu(visible, includeModules: true)
                            else
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                child: Icon(
                                  ChainStrip.icons[selected],
                                  color: accent,
                                  size: 23,
                                ),
                              ),
                            Expanded(
                              child: Text(
                                isNam ? 'NAM A2 LITE' : module.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  color: accent,
                                ),
                              ),
                            ),
                            if (!tight) _editorMenu(visible),
                            toggle,
                          ],
                        ),
                        if (isNam) ...[
                          const SizedBox(height: 6),
                          _namModelSelector(),
                        ],
                      ],
                      if (isNam &&
                          widget.namClient?.canToneEq != true &&
                          !veryShort)
                        Text(
                          tr("このファームウェアではGAIN / VOLUMEのみ対応"),
                          style: TextStyle(fontSize: 11),
                        ),
                      if (unsupported)
                        Text(
                          tr("このファームウェアでは、このエフェクトの音声処理は利用できません。"),
                          style: TextStyle(fontSize: 11),
                        ),
                      const SizedBox(height: 6),
                      Expanded(
                        child: ParameterDeck(
                          key: ValueKey('parameters-$selected'),
                          count: fields.length,
                          itemBuilder: (index, size) {
                            final i = fields[index];
                            final parameter = isNam ? null : parameters[index];
                            final choices = parameter?.choices;
                            if (choices != null) {
                              final value = _pedal.edit!.word(
                                module.offset + i * 2,
                              );
                              return EffectChoice(
                                label: parameter!.label,
                                value:
                                    choices[value] ?? tr("未選択 ({0})", [value]),
                                enabled: !_busy && !unsupported,
                                onPressed: () =>
                                    _pickEffectParameter(module, parameter),
                              );
                            }
                            return Knob(
                              key: ValueKey(
                                'preset-${_pedal.editIndex}-nam-${_namState?.selected}-module-$selected-field-$i',
                              ),
                              defaultValue: isNam ? 50 : null,
                              label: isNam
                                  ? NamTone.labels[i]!
                                  : parameter!.label,
                              value: _pedal.edit!
                                  .word(module.offset + i * 2)
                                  .clamp(
                                    parameter?.min ?? module.fields[i].min,
                                    parameter?.max ?? module.fields[i].max,
                                  ),
                              min: parameter?.min ?? module.fields[i].min,
                              max: parameter?.max ?? module.fields[i].max,
                              size: size,
                              accent: accent,
                              format: isNam
                                  ? (v) => NamTone.format(i, v)
                                  : parameter?.format,
                              enabled:
                                  (isNam && _toneDraft != null
                                      ? !_working &&
                                            _toneField == i &&
                                            (widget.recovery == null ||
                                                widget.recovery!.connected)
                                      : !_busy) &&
                                  !_moduleDisabled(module, i),
                              onPreview: isNam
                                  ? (value) => _previewNamTone(i, value)
                                  : null,
                              onChanged: isNam
                                  ? (value) => _finishNamTone(i, value)
                                  : (value) => _changeModule(module, [
                                      for (
                                        var k = 0;
                                        k < module.fields.length;
                                        k++
                                      )
                                        k == i
                                            ? value
                                            : _pedal.edit!.word(
                                                module.offset + k * 2,
                                              ),
                                    ]),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _chooseNamModel() async {
    final state = _namState, client = widget.namClient;
    if (_busy || state == null || client == null) return;
    final preset = _pedal.selected;
    final generation = widget.recovery?.generation;
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
    if (generation != widget.recovery?.generation ||
        preset != _pedal.selected) {
      setState(() => _error = tr("本体のプリセットが切り替わりました。モデルを選び直してください。"));
      return;
    }
    if (choice == state.selected) return;
    var wanted = _pedal.edit!.setWord(0xde, 0x414e).setWord(0xe0, choice);
    if (choice != 0) wanted = wanted.setWord(0x2c, 1);
    _pendingEdit = RecoveryDraft(_pedal.selected, wanted.bytes);
    await _run(tr("NAMモデルをロード中"), () async {
      await client.select(choice!);
      await _pedal.refresh();
      await _refreshNam();
    });
    _pendingEdit = null;
  }

  Widget _namModelSelector() => NamModelSelector(
    state: _namState,
    activeModel: _activeModel,
    fallbackModel: widget.namModel,
    namOn: _pedal.edit!.word(0x2c) != 0,
    busy: _busy,
    canChoose: widget.namClient != null,
    onChoose: _chooseNamModel,
    onOpenLibrary: widget.onOpenModels == null
        ? null
        : () => _guard(_openModels),
  );

  Future<void> _pickEffectParameter(
    PedalModule module,
    EffectParameter parameter,
  ) async {
    if (_busy) return;
    final preset = _pedal.selected;
    final generation = widget.transport.connectionGeneration;
    final value = _pedal.edit!.word(module.offset + parameter.field * 2);
    final choice = await pickEffectChoice(
      context,
      module: module,
      parameter: parameter,
      value: value,
      irSlots: _irs,
    );
    if (!mounted || choice == null || _busy) return;
    if (generation != widget.transport.connectionGeneration ||
        preset != _pedal.selected) {
      setState(() => _error = tr("本体の状態が変わりました。もう一度選択してください。"));
      return;
    }
    await _changeModule(module, [
      for (var i = 0; i < module.fields.length; i++)
        i == parameter.field
            ? choice
            : _pedal.edit!.word(module.offset + i * 2),
    ]);
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
            _namState?.selected == 0 ||
            _pedal.edit!.word(0x2c) == 0 ||
            (field >= 3 && field <= 6 && widget.namClient?.canToneEq != true));
  }

  Future<void> _irSlotMenu(IrSlotInfo s) async {
    final action = await pickIrSlotAction(context, s);
    switch (action) {
      case IrSlotAction.import:
        await _irImport(s);
      case IrSlotAction.rename:
        await _irRename(s);
      case IrSlotAction.delete:
        await _irDelete(s);
      case null:
        break;
    }
  }
}
