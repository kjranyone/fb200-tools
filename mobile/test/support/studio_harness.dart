import 'dart:typed_data';

import 'package:fb200_nam/nam_client.dart';
import 'package:fb200_nam/pedal_client.dart';
import 'package:fb200_nam/protocol.dart';

import '../pedal_client_test.dart' show PedalHarness;

/// A firmware-like edit buffer, stored presets and NAM RPC on one wire.
/// In particular audition must not write flash or lose other preset words.
class StudioHarness {
  final pedal = PedalHarness();

  /// Op 0 flags. A recovery test's second harness only lends its link, so
  /// replies must not touch [client] (it would attach another wire).
  int flags = 7 | 8 | 16 | 128 | 256 | 512;
  late final client = NamClient(pedal.wire)..capabilityFlags = flags;
  late Uint8List edit;
  int selected = 1;
  final selections = <List<int>>[];
  final names = <int, String>{1: 'Studio Clean', 2: 'Bass Crunch'};
  bool failSelection = false;

  /// Op 10 peaks (input, NAM input, output); null answers unsupported.
  List<double>? levels;
  int levelReads = 0;

  /// Op 8 snapshot; null answers unsupported.
  List<int>? tuner;

  /// Header byte 52 per slot (ops 11/12, answered with flags bit 12).
  final kinds = <int, int>{};
  final kindWrites = <List<int>>[];

  /// Op 15 writes [offset, value] (answered with flags bit 14).
  final tailWrites = <List<int>>[];

  /// The 13 global settings bytes, rewritten by 0xB0.
  final settings = [0, 1, 13, 0, 0, 0, 0, 5, 0, 1, 1, 0, 100];

  StudioHarness() {
    for (var i = 0; i < 40; i++) {
      var p = PedalPreset(pedal.presets[i])
          .renamed(i == 0 ? 'Studio Finger' : 'Preset $i');
      for (final m in pedalModules) {
        p = p.setWord(m.offset, 1);
      }
      p = p.setWord(0x74, 0).setWord(0x8c, 0);
      for (var k = 2; k < 8; k++) {
        p = p.setWord(0x2c + k * 2, 50);
      }
      p.bytes.setRange(0xbc, 0xc3, [1, 0, 2, 3, 4, 5, 6]);
      p = p.setWord(0xe0, i == 0 ? 1 : 2);
      pedal.presets[i] = p.bytes;
    }
    edit = Uint8List.fromList(pedal.presets[0]);
    final legacy = pedal.link.sent!;
    pedal.link.sent = (bytes) async {
      final f = FrameDecoder().add(bytes).single;
      void reply(int command, List<int> payload) =>
          pedal.link.incoming.add(frame(command, payload));
      if (f.command == 0xe0) {
        final op = f.payload[1], args = f.payload.sublist(4);
        if (op == 0) {
          pedal.link.reply(
            bytes,
            data: [
              ...u32(48000),
              ...u16(1871),
              3,
              64,
              ...u16(7548),
              ...u16(flags),
              selected,
            ],
          );
        } else if (op == 1) {
          final data = <int>[selected];
          for (var i = 1; i <= 3; i++) {
            final name = names[i]?.codeUnits ?? <int>[];
            data.addAll([
              i,
              names.containsKey(i) ? 1 : 0,
              ...name,
              ...List.filled(24 - name.length, 0),
              ...u32(0),
            ]);
          }
          pedal.link.reply(bytes, data: data);
        } else if (op == 6) {
          selections.add(List.of(args));
          if (failSelection) {
            pedal.link.reply(bytes, status: 4);
            return;
          }
          selected = args[0];
          var p = PedalPreset(edit)
              .setWord(0xde, 0x414e)
              .setWord(0xe0, selected);
          if (selected != 0) p = p.setWord(0x2c, 1);
          edit = p.bytes;
          if (args[1] != 0) {
            pedal.presets[pedal.selected] = Uint8List.fromList(edit);
          }
          pedal.link.reply(bytes);
        } else if (op == 11 && flags & 4096 != 0) {
          pedal.link.reply(
            bytes,
            data: [for (var i = 1; i <= 64; i++) kinds[i] ?? 0],
          );
        } else if (op == 12 && flags & 4096 != 0) {
          kindWrites.add(List.of(args));
          kinds[args[0]] = args[1];
          pedal.link.reply(bytes);
        } else if (op == 14 && flags & 16384 != 0) {
          if (args.length == 1 && args[0] == 1) {
            pedal.link.reply(bytes, data: pitchDescriptor);
          } else {
            pedal.link.reply(bytes, status: 1);
          }
        } else if (op == 15 && flags & 16384 != 0) {
          tailWrites.add([args[0], read16(args, 1)]);
          edit = PedalPreset(edit).setWord(args[0], read16(args, 1)).bytes;
          pedal.link.reply(bytes);
        } else if (op == 10 && levels != null) {
          levelReads++;
          final data = ByteData(12);
          for (var i = 0; i < 3; i++) {
            data.setFloat32(i * 4, levels![i], Endian.little);
          }
          pedal.link.reply(bytes, data: data.buffer.asUint8List());
        } else if (op == 8 && tuner != null) {
          pedal.link.reply(bytes, data: tuner!);
        } else {
          pedal.link.reply(bytes, status: 5);
        }
        return;
      }
      if (f.command == 0x94) {
        reply(0xa1, [pedal.selected, ...edit]);
        reply(0xb0, settings);
        reply(0xba, [0, 0, 3, 80, ...u16(110)]);
        reply(0xbb, [75, 0]);
        reply(0xc9, [0]);
      } else if (f.command == 0x98) {
        selectPreset(f.payload[0]);
      } else if (f.command == 0xb0) {
        settings.setAll(0, f.payload);
      } else if (f.command >= 0x80 && f.command <= 0x86) {
        final m = pedalModules.firstWhere((m) => m.command == f.command);
        edit.setRange(m.offset, m.offset + f.payload.length, f.payload);
      } else if (f.command == 0x97 && f.payload[0] == 255) {
        edit = Uint8List.fromList(f.payload.sublist(1));
      } else {
        if (f.command == 0x97) edit = Uint8List.fromList(f.payload.sublist(1));
        await legacy(bytes);
      }
    };
  }

  /// The firmware's op 14 reply for mode 1 (src/dsp/fx.c).
  static final pitchDescriptor = [
    1,
    0,
    ..._text('PITCH', 16),
    5,
    ..._param('SHIFT', 0, 4800, 3600, 4),
    ..._param('MIX', 0, 100, 50, 1),
    ..._param('LEVEL', 0, 100, 50, 2),
    ..._param('GLIDE', 0, 1000, 0, 3),
    ..._param('RANGE', 0, 1, 1, 5, 'Guitar|Bass'),
  ];

  static List<int> _text(String s, int n) => [
    ...s.codeUnits,
    ...List.filled(n - s.length, 0),
  ];

  static List<int> _param(
    String name,
    int min,
    int max,
    int def,
    int unit, [
    String labels = '',
  ]) => [
    ..._text(name, 12),
    ...u16(min),
    ...u16(max),
    ...u16(def),
    unit,
    ..._text(labels, 24),
  ];

  /// Firmware that advertises more, as already seen by [client].
  void addFlags(int bits) {
    flags |= bits;
    client.capabilityFlags |= bits;
  }

  void selectPreset(int index) {
    pedal.selected = index;
    edit = Uint8List.fromList(pedal.presets[index]);
    selected = read16(edit, 0xe0);
    pedal.link.incoming.add(frame(0x98, [index]));
  }

  Future<void> close() => pedal.close();
}
