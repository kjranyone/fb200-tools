import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'protocol.dart';

class PedalPreset {
  final Uint8List bytes;
  PedalPreset(List<int> bytes) : bytes = Uint8List.fromList(bytes) {
    if (bytes.length != 256) throw DeviceError('プリセットの形式が不正です。');
  }
  String get name =>
      latin1.decode(bytes.take(20).takeWhile((v) => v != 0).toList());
  int word(int offset) => read16(bytes, offset);
  PedalPreset renamed(String name) {
    if (name.isEmpty ||
        name.length > 20 ||
        name.codeUnits.any((c) => c < 32 || c > 126)) {
      throw DeviceError('プリセット名は半角英数字・記号で1〜20文字にしてください。');
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
  PedalPreset? edit;
  int selected = 0, battery = 0;
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
      case 0xa1 when p.length == 257 && p[0] < 40:
        selected = p[0];
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
    notifyListeners();
  }

  Future<void> initialize() async {
    final v = await transport.exchange(0, [], 1);
    if (v.payload.length != 55 ||
        latin1.decode(v.payload.take(32).toList()).split('\x00').first !=
            'FB200') {
      throw DeviceError('FB200本体を確認できませんでした。');
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
      throw DeviceError('本体の状態を読み取れませんでした。');
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
    notifyListeners();
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
    if (f.payload[0] != 1) throw DeviceError('プリセットの保存に失敗しました。');
    final readback = await readPreset(index);
    if (!listEquals(readback.bytes, preset.bytes)) {
      throw DeviceError('保存内容が一致しません。一覧を更新してください。');
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
    if (bytes.length > 65536) throw DeviceError('バックアップが大きすぎます。');
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
      throw DeviceError('FB200プリセットのバックアップ形式・整合性を確認してください。');
    }
  }

  @override
  void dispose() {
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

const pedalModules = [
  PedalModule('コンプレッサー', 0x80, 0x14, [
    PedalField('オン', 1),
    PedalField('タイプ', 0),
    PedalField('アタック'),
    PedalField('スレッショルド'),
    PedalField('レシオ'),
    PedalField('レベル'),
  ]),
  PedalModule('ノイズゲート', 0x81, 0x5c, [
    PedalField('オン', 1),
    PedalField('タイプ', 0),
    PedalField('スレッショルド'),
  ]),
  PedalModule('アンプ', 0x82, 0x2c, [
    PedalField('オン', 1),
    PedalField('モデル（1〜10）', 10),
    PedalField('ゲイン'),
    PedalField('ベース'),
    PedalField('ミドル'),
    PedalField('ミドル周波数'),
    PedalField('トレブル'),
    PedalField('ボリューム'),
  ]),
  PedalModule('キャビネット / IR', 0x83, 0x44, [
    PedalField('オン', 1),
    PedalField('タイプ（11〜19：ユーザーIR）', 19),
    PedalField('パラメーター1', 4),
    PedalField('パラメーター2'),
    PedalField('パラメーター3'),
    PedalField('パラメーター4', 9),
  ]),
  PedalModule('モジュレーション', 0x84, 0x74, [
    PedalField('オン', 1),
    PedalField('タイプ', 11),
    PedalField('レート'),
    PedalField('ミックス'),
    PedalField('パラメーター3'),
    PedalField('パラメーター4'),
    PedalField('パラメーター5', 240),
  ]),
  PedalModule('ディレイ', 0x85, 0x8c, [
    PedalField('オン', 1),
    PedalField('タイプ', 6),
    PedalField('ミックス'),
    PedalField('フィードバック'),
    PedalField('タイム (ms)', 2500, 40),
  ]),
  PedalModule('リバーブ', 0x86, 0xa4, [
    PedalField('オン', 1),
    PedalField('タイプ', 4),
    PedalField('パラメーター1', 200),
    PedalField('レベル'),
    PedalField('ディケイ'),
    PedalField('トーン'),
  ]),
];
