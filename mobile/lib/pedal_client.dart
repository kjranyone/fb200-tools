import 'localization.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'ir_wav.dart' show irBytes, irLength;
import 'nam_client.dart' show TransferCancelled;
import 'protocol.dart';

/// One user-IR slot record as listed by the `65` command.
class IrSlotInfo {
  final int slot; // 1..9
  final bool used;
  final String name;
  const IrSlotInfo(this.slot, this.used, this.name);
}

/// The 0xD7 looper status reply.
class LooperStatus {
  final int state; // 0..5, dsp/looper.h LOOPER_*
  final int level; // 0..100
  final int lenS, posS, maxS, prepS; // seconds
  final int undo; // 0 none, 1 undo, 2 redo
  final bool storeBusy, writing;
  const LooperStatus(
    this.state,
    this.level,
    this.lenS,
    this.posS,
    this.maxS,
    this.prepS,
    this.undo,
    this.storeBusy,
    this.writing,
  );
  factory LooperStatus.parse(Uint8List p) {
    if (p.length != 13) throw DeviceError(tr("ルーパーの状態が不正です。"));
    return LooperStatus(
      p[0],
      p[1],
      read16(p, 2),
      read16(p, 4),
      read16(p, 6),
      read16(p, 8),
      p[10],
      p[11] != 0,
      p[12] != 0,
    );
  }

  bool get available => state != 0;
}

class PedalPreset {
  final Uint8List bytes;
  PedalPreset(List<int> bytes) : bytes = Uint8List.fromList(bytes) {
    if (bytes.length != 256) throw DeviceError(tr("プリセットの形式が不正です。"));
  }
  String get name =>
      latin1.decode(bytes.take(20).takeWhile((v) => v != 0).toList());
  int word(int offset) => read16(bytes, offset);
  PedalPreset renamed(String name) {
    if (name.isEmpty ||
        name.length > 20 ||
        name.codeUnits.any((c) => c < 32 || c > 126)) {
      throw DeviceError(tr("プリセット名は半角英数字・記号で1〜20文字にしてください。"));
    }
    final copy = Uint8List.fromList(bytes)..fillRange(0, 20, 0);
    copy.setRange(0, name.length, name.codeUnits);
    return PedalPreset(copy);
  }

  PedalPreset setWord(int offset, int value) {
    final copy = Uint8List.fromList(bytes)
      ..setRange(offset, offset + 2, u16(value));
    return PedalPreset(copy);
  }
}

class PedalClient extends ChangeNotifier {
  final WireTransport transport;
  final bool namAware;
  late final StreamSubscription<Frame> _subscription;
  final presets = <int, PedalPreset>{};
  final irSlots = <int, IrSlotInfo>{};
  PedalPreset? edit;
  int selected = 0, battery = 0;
  int? editIndex;
  bool _disposed = false;
  bool charging = false, refreshRequired = false;
  Uint8List? settings, rhythm;
  String version = '';
  PedalClient(this.transport, {this.namAware = false}) {
    _subscription = transport.frames.listen(_receive);
  }
  static String address(int index) => '${index ~/ 4}${'ABCD'[index % 4]}';

  void _receive(Frame frame) {
    final p = frame.payload;
    switch (frame.command) {
      case 0x69
          when p.length == 59 &&
              p[0] == 1 &&
              read16(p, 1) >= 1 &&
              read16(p, 1) <= irSlotCount &&
              p[3] <= 1:
        final slot = _irRecord(p, 0);
        irSlots[slot.slot] = slot;
      case 0xa1 when p.length == 257 && p[0] < 40:
        selected = p[0];
        editIndex = p[0];
        edit = PedalPreset(p.sublist(1));
      case 0x97 when p.length == 257 && p[0] < 40:
        presets[p[0]] = PedalPreset(p.sublist(1));
      case 0x98 when p.length == 1 && p[0] < 40:
        selected = p[0];
        refreshRequired = true;
      case 0xb0 when p.length == 13:
        settings = Uint8List.fromList(p);
      case 0xba when p.length == 6:
        rhythm = Uint8List.fromList(p);
      case 0xbb when p.length == 2:
        battery = p[0].clamp(0, 100);
        charging = p[1] != 0;
      default:
        final module = pedalModules
            .where((m) => m.command == frame.command)
            .firstOrNull;
        if (module != null &&
            edit != null &&
            p.length == module.fields.length * 2) {
          final bytes = Uint8List.fromList(edit!.bytes)
            ..setRange(module.offset, module.offset + p.length, p);
          edit = PedalPreset(bytes);
        } else {
          return;
        }
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    final v = await transport.exchange(0, [], 1);
    if (v.payload.length != 55 ||
        latin1.decode(v.payload.take(32).toList()).split('\x00').first !=
            'FB200') {
      throw DeviceError(tr("FB200本体を確認できませんでした。"));
    }
    version = latin1.decode(v.payload.sublist(39, 46)).split('\x00').first;
    await refresh();
  }

  Future<void> refresh() async {
    refreshRequired = false;
    await transport.exchange(
      0x94,
      [],
      0xc9,
      accept: (f) => f.payload.length == 1,
    );
    if (edit == null || settings == null || rhythm == null) {
      throw DeviceError(tr("本体の状態を読み取れませんでした。"));
    }
  }

  Future<PedalPreset> readPreset(int index) async {
    if (index < 0 || index >= 40) throw RangeError.range(index, 0, 39);
    final f = await transport.exchange(
      0x96,
      [index],
      0x97,
      accept: (f) => f.payload.length == 257 && f.payload[0] == index,
    );
    final preset = PedalPreset(f.payload.sublist(1));
    presets[index] = preset;
    return preset;
  }

  Future<void> loadBank(int bank) async {
    if (bank < 0 || bank > 9) throw RangeError.range(bank, 0, 9);
    for (var i = bank * 4; i < bank * 4 + 4; i++) {
      await readPreset(i);
    }
    if (!_disposed) notifyListeners();
  }

  /// Writes edit-buffer words no module command covers (the preset tail) by
  /// sending the whole edit buffer, as the delay block does.
  Future<void> setEditWords(Map<int, int> words) async {
    var changed = edit;
    if (changed == null) throw DeviceError(tr("本体の編集中プリセットを読み取れていません。"));
    for (final MapEntry(:key, :value) in words.entries) {
      changed = changed!.setWord(key, value);
    }
    await transport.sendCommand(0x97, [255, ...changed!.bytes]);
    await refresh();
  }

  Future<void> select(int index) async {
    if (index < 0 || index >= 40) throw RangeError.range(index, 0, 39);
    await transport.exchange(
      0x98,
      [index],
      0x98,
      accept: (f) => f.payload.length == 1 && f.payload[0] == index,
    );
    await refresh();
  }

  Future<void> store(int index, PedalPreset preset) async {
    if (namAware && preset.word(0xde) != 0x414e) {
      // An explicit bypass marker prevents the firmware's legacy-app guard
      // from retaining a NAM binding from the destination of a copy/restore.
      preset = preset.setWord(0xde, 0x414e).setWord(0xe0, 0);
    }
    if (index < 0 || index >= 40) throw RangeError.range(index, 0, 39);
    final f = await transport.exchange(
      0x97,
      [index, ...preset.bytes],
      0x99,
      accept: (f) => f.payload.length == 1,
    );
    if (f.payload[0] != 1) throw DeviceError(tr("プリセットの保存に失敗しました。"));
    final readback = await readPreset(index);
    if (!listEquals(readback.bytes, preset.bytes)) {
      throw DeviceError(tr("保存内容が一致しません。一覧を更新してください。"));
    }
    await refresh();
  }

  Future<void> module(PedalModule module, List<int> values) async {
    if (values.length != module.fields.length) {
      throw ArgumentError('module fields');
    }
    for (var i = 0; i < values.length; i++) {
      if ((values[i] < module.fields[i].min ||
              values[i] > module.fields[i].max) &&
          (edit == null || edit!.word(module.offset + i * 2) != values[i])) {
        throw ArgumentError('module value');
      }
    }
    if (module.command == 0x85 && edit != null) {
      var changed = edit!.setWord(0x96, 0x4c44);
      for (var i = 0; i < values.length; i++) {
        changed = changed.setWord(module.offset + i * 2, values[i]);
      }
      await transport.sendCommand(0x97, [255, ...changed.bytes]);
    } else {
      await transport.sendCommand(module.command, [
        for (final v in values) ...u16(v),
      ]);
    }
    await refresh();
  }

  Future<void> setRhythm({
    required bool on,
    required int pattern,
    required int level,
    required int bpm,
  }) async {
    if (pattern < 0 ||
        pattern > 39 ||
        level < 0 ||
        level > 100 ||
        bpm < 40 ||
        bpm > 260) {
      throw ArgumentError('rhythm');
    }
    await transport.sendCommand(0xba, [
      on ? 1 : 0,
      rhythm?[1] ?? 0,
      pattern,
      level,
      ...u16(bpm),
    ]);
    await refresh();
  }

  Future<void> setTuner({
    required bool on,
    required bool mute,
    required int a4,
  }) async {
    if (a4 < 435 || a4 > 450) throw ArgumentError('A4');
    await transport.sendCommand(0xb8, [a4 - 435, 0, on ? 1 : 0, mute ? 1 : 0]);
    await refresh();
  }

  Future<void> setSettings(Uint8List values) async {
    if (values.length != 13) throw ArgumentError('settings');
    await transport.sendCommand(0xb0, values);
    await refresh();
  }

  // ---- user IR slots (stock protocol 61..68) ----

  static const irSlotCount = 9;
  static const _irNameLen = 50;
  static const _irChunk = 512;

  static String sanitizeIrName(String name) {
    final cleaned = name.split('').map((c) {
      final code = c.codeUnitAt(0);
      return code >= 0x20 && code <= 0x7e ? c : ' ';
    }).join();
    final collapsed = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
    final trimmed = collapsed.isEmpty ? 'untitled' : collapsed;
    return trimmed.length > _irNameLen
        ? trimmed.substring(0, _irNameLen)
        : trimmed;
  }

  void _irSlotCheck(int slot) {
    if (slot < 1 || slot > irSlotCount) {
      throw ArgumentError.value(slot, 'IR slot', 'must be 1..$irSlotCount');
    }
  }

  /// List the nine user-IR slots (`65`). Read-only.
  Future<List<IrSlotInfo>> irList() async {
    final f = await transport.exchange(
      0x65,
      [1, ...u16(1), ...u16(irSlotCount)],
      0x66,
      accept: (f) => f.payload.length == irSlotCount * 59,
    );
    final p = f.payload;
    final result = <IrSlotInfo>[];
    for (var s = 0; s < irSlotCount; s++) {
      final o = s * 59;
      if (p[o] != 1 || read16(p, o + 1) != s + 1) {
        throw DeviceError(tr("IRスロット一覧の形式が不正です。"));
      }
      if (p[o + 3] > 1) throw DeviceError(tr("IRスロットの使用状態が不正です。"));
      result.add(_irRecord(p, o));
    }
    irSlots
      ..clear()
      ..addEntries(result.map((s) => MapEntry(s.slot, s)));
    return result;
  }

  static IrSlotInfo _irRecord(List<int> p, int offset) => IrSlotInfo(
    read16(p, offset + 1),
    p[offset + 3] == 1,
    p[offset + 3] == 1
        ? latin1
              .decode(p.sublist(offset + 5, offset + 5 + _irNameLen))
              .split('\x00')
              .first
        : '',
  );

  /// Rename a used IR slot (`67` op 2).
  Future<void> irRename(int slot, String name) async {
    _irSlotCheck(slot);
    final bytes = latin1.encode(sanitizeIrName(name));
    final f = await transport.exchange(
      0x67,
      [
        1,
        ...u16(slot),
        2,
        ...bytes,
        ...List.filled(_irNameLen - bytes.length, 0),
      ],
      0x68,
      accept: (f) =>
          f.payload.length == 4 &&
          f.payload[0] == 1 &&
          read16(f.payload, 1) == slot,
    );
    if (f.payload[3] == 0) {
      throw DeviceError(tr("このIRスロットは空のため、名前を変更できません。"));
    }
  }

  /// Delete an IR slot (`67` op 1): clears the used flag, name becomes Empty.
  Future<void> irDelete(int slot) async {
    _irSlotCheck(slot);
    final f = await transport.exchange(
      0x67,
      [1, ...u16(slot), 1, ...List.filled(_irNameLen, 0)],
      0x68,
      accept: (f) =>
          f.payload.length == 4 &&
          f.payload[0] == 1 &&
          read16(f.payload, 1) == slot,
    );
    if (f.payload[3] == 0) {
      throw DeviceError(tr("IRスロットを削除できませんでした。"));
    }
  }

  /// Upload one IR (`61`): frame 0 carries the name, frames 1..8 carry the
  /// 4096 bytes of 1024 float32 samples. Nothing is committed unless every
  /// frame is acknowledged in order, so a failed upload is simply retried
  /// from frame 0 by the caller.
  Future<void> irUpload(
    int slot,
    String name,
    List<double> samples, {
    void Function(int sent, int total)? progress,
    bool Function()? cancelled,
  }) async {
    _irSlotCheck(slot);
    if (samples.length != irLength) throw ArgumentError('IR samples');
    for (final v in samples) {
      if (!v.isFinite) {
        throw DeviceError(tr("IRに異常な値が含まれています。変換を確認してください。"));
      }
    }
    final nameBytes = latin1.encode(sanitizeIrName(name));
    final data = irBytes(Float32List.fromList(samples));
    final frames = data.length ~/ _irChunk;
    final total = frames + 1;
    Future<void> sendFrame(int index, List<int> chunk) async {
      await transport.exchange(
        0x61,
        [1, ...u16(slot), total, index, ...u16(chunk.length), ...chunk],
        0x62,
        accept: (f) =>
            f.payload.length == 4 &&
            f.payload[0] == 1 &&
            read16(f.payload, 1) == slot &&
            f.payload[2] == 0 &&
            f.payload[3] == index,
      );
      progress?.call(index + 1, total);
    }

    await sendFrame(0, nameBytes);
    for (var index = 1; index < total; index++) {
      if (cancelled?.call() ?? false) throw TransferCancelled();
      await sendFrame(
        index,
        data.sublist(
          (index - 1) * _irChunk,
          math.min(index * _irChunk, data.length),
        ),
      );
    }
  }

  /// Change the Bluetooth device name (`B3`, 20 bytes, no reply). The module
  /// applies it after the Bluetooth link reconnects.
  Future<void> setBtName(String name) async {
    final codes = name.codeUnits;
    if (name.isEmpty ||
        codes.length > 20 ||
        codes.any((c) => c < 0x20 || c > 0x7e)) {
      throw DeviceError(tr("Bluetooth名は半角英数字・記号で1〜20文字にしてください。"));
    }
    await transport.sendCommand(0xb3, [
      ...codes,
      ...List.filled(20 - codes.length, 0),
    ]);
  }

  /// Reorder the effect chain of the edit buffer (`A0`, 7 bytes, no reply):
  /// a permutation of module indexes 0..6.
  Future<void> setModuleOrder(List<int> order) async {
    if (order.length != 7 ||
        !Set.of(order).containsAll(const [0, 1, 2, 3, 4, 5, 6])) {
      throw DeviceError(tr("モジュール順序が不正です。"));
    }
    await transport.sendCommand(0xa0, order);
  }

  // ---- looper (our 0xD7 extension) ----

  static List<String> get looperStates => [
    tr("利用不可"),
    tr("空"),
    tr("録音"),
    tr("再生"),
    tr("ダビング"),
    tr("停止"),
  ];

  Future<LooperStatus> looperStatus() async {
    final f = await transport.exchange(
      0xd7,
      [0],
      0xd8,
      accept: (f) => f.payload.length == 13,
    );
    return LooperStatus.parse(f.payload);
  }

  /// op 1..7: tap, rec, play, dub, stop, undo, clear. Returns the code
  /// (0 ok, 1 not now, 2 no flash area, 3 not ready).
  Future<int> looperAction(int op) async {
    if (op < 1 || op > 7) throw ArgumentError.value(op, 'looper op');
    final f = await transport.exchange(
      0xd7,
      [op],
      0xd8,
      accept: (f) => f.payload.length == 1,
    );
    return f.payload[0];
  }

  Future<void> looperLevel(int pct) async {
    final f = await transport.exchange(
      0xd7,
      [8, pct.clamp(0, 100)],
      0xd8,
      accept: (f) => f.payload.length == 1,
    );
    if (f.payload[0] != 0) throw DeviceError(tr("ルーパーの音量を変更できませんでした。"));
  }

  Future<void> looperSave(int slot) async {
    final f = await transport.exchange(
      0xd7,
      [9, slot.clamp(1, 2)],
      0xd8,
      accept: (f) => f.payload.length == 1,
    );
    if (f.payload[0] != 0) throw DeviceError(tr("ループを保存できませんでした。"));
  }

  Future<void> looperLoad(int slot) async {
    final f = await transport.exchange(
      0xd7,
      [10, slot.clamp(1, 2)],
      0xd8,
      accept: (f) => f.payload.length == 1,
    );
    if (f.payload[0] != 0) throw DeviceError(tr("ループを読み込めませんでした。"));
  }

  Future<Uint8List> backup() async {
    final records = <Map<String, Object>>[];
    for (var i = 0; i < 40; i++) {
      final p = await readPreset(i);
      records.add({
        'index': i,
        'data': base64Encode(p.bytes),
        'crc32': crc32(p.bytes),
      });
    }
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'fb200-presets',
          'version': 1,
          'presets': records,
        }),
      ),
    );
  }

  static List<PedalPreset> parseBackup(List<int> bytes) {
    if (bytes.length > 65536) throw DeviceError(tr("バックアップが大きすぎます。"));
    try {
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map ||
          json['format'] != 'fb200-presets' ||
          json['version'] != 1 ||
          json['presets'] is! List) {
        throw const FormatException();
      }
      final records = json['presets'] as List;
      if (records.length != 40) throw const FormatException();
      final result = <PedalPreset>[];
      for (var i = 0; i < 40; i++) {
        final r = records[i];
        if (r is! Map || r['index'] != i || r['data'] is! String) {
          throw const FormatException();
        }
        final p = PedalPreset(base64Decode(r['data'] as String));
        if (r['crc32'] != crc32(p.bytes)) throw const FormatException();
        result.add(p);
      }
      return result;
    } catch (_) {
      throw DeviceError(tr("FB200プリセットのバックアップ形式・整合性を確認してください。"));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription.cancel());
    super.dispose();
  }
}

class PedalField {
  final String label;
  final int min, max;
  const PedalField(this.label, [this.max = 100, this.min = 0]);
}

class PedalModule {
  final String name;
  final int command, offset;
  final List<PedalField> fields;
  const PedalModule(this.name, this.command, this.offset, this.fields);
}

List<PedalModule> get pedalModules => [
  PedalModule(tr("コンプレッサー"), 0x80, 0x14, [
    PedalField(tr("オン"), 1),
    PedalField(tr("タイプ"), 0),
    PedalField(tr("アタック")),
    PedalField(tr("スレッショルド")),
    PedalField(tr("レシオ")),
    PedalField(tr("レベル")),
  ]),
  PedalModule(tr("ノイズゲート"), 0x81, 0x5c, [
    PedalField(tr("オン"), 1),
    PedalField(tr("タイプ"), 0),
    PedalField(tr("スレッショルド")),
  ]),
  PedalModule(tr("アンプ"), 0x82, 0x2c, [
    PedalField(tr("オン"), 1),
    PedalField(tr("モデル（1〜10）"), 10),
    PedalField(tr("ゲイン")),
    PedalField(tr("ベース")),
    PedalField(tr("ミドル")),
    PedalField(tr("ミドル周波数")),
    PedalField(tr("トレブル")),
    PedalField(tr("ボリューム")),
  ]),
  PedalModule(tr("キャビネット / IR"), 0x83, 0x44, [
    PedalField(tr("オン"), 1),
    PedalField(tr("タイプ（11〜19：ユーザーIR）"), 19),
    PedalField(tr("パラメーター1"), 4),
    PedalField(tr("パラメーター2")),
    PedalField(tr("パラメーター3")),
    PedalField(tr("パラメーター4"), 9),
  ]),
  PedalModule(tr("モジュレーション"), 0x84, 0x74, [
    PedalField(tr("オン"), 1),
    PedalField(tr("タイプ"), 11),
    PedalField(tr("レート")),
    PedalField(tr("ミックス")),
    PedalField(tr("パラメーター3")),
    PedalField(tr("パラメーター4")),
    PedalField(tr("パラメーター5"), 240),
  ]),
  PedalModule(tr("ディレイ"), 0x85, 0x8c, [
    PedalField(tr("オン"), 1),
    PedalField(tr("タイプ"), 6),
    PedalField(tr("ミックス")),
    PedalField(tr("フィードバック")),
    PedalField(tr("タイム (ms)"), 2500, 40),
  ]),
  PedalModule(tr("リバーブ"), 0x86, 0xa4, [
    PedalField(tr("オン"), 1),
    PedalField(tr("タイプ"), 4),
    PedalField(tr("パラメーター1"), 200),
    PedalField(tr("レベル")),
    PedalField(tr("ディケイ")),
    PedalField(tr("トーン")),
  ]),
];
