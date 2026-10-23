import 'dart:convert';
import 'dart:typed_data';

import 'package:fb200_nam/pedal_client.dart';
import 'package:fb200_nam/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'protocol_test.dart' show MemoryLink;

class PedalHarness {
  final link = MemoryLink();
  late final WireTransport wire = WireTransport(link);
  late final PedalClient pedal = PedalClient(wire);
  int selected = 0, writes = 0;
  final presets = List.generate(40, (i) {
    final p = Uint8List(256);
    p.setRange(0, 6, 'PRESET'.codeUnits);
    p.setRange(0xde, 0xe2, [0x4e, 0x41, i % 4, 0]);
    p[255] = i;
    return p;
  });

  /// IR store state: which slots are used and their 50-byte names.
  final irUsed = List.filled(9, false);
  final irNames = List.generate(9, (i) => Uint8List(50));
  final irUploadFrames = <int>[];
  int irUploadSlot = -1;
  List<int>? irAssembled;
  List<int>? irUploadNameBytes;
  List<int>? btName;
  List<int>? moduleOrder;
  int looperState = 1; // LOOPER_EMPTY
  int looperLevelValue = 100;
  final looperLog = <String>[];
  PedalHarness() {
    irUsed[2] = true; // IR3 in use
    irNames[2].setRange(0, 6, 'Cab IR'.codeUnits);
    link.sent = (bytes) async {
      final f = FrameDecoder().add(bytes).single;
      void reply(int command, List<int> p) =>
          link.incoming.add(frame(command, p));
      switch (f.command) {
        case 0:
          final version = Uint8List(55)..setRange(0, 5, 'FB200'.codeUnits);
          reply(1, version);
        case 0x94:
          reply(0xa1, [selected, ...presets[selected]]);
          reply(0xb0, [selected, 1, 13, 0, 0, 0, 0, 5, 0, 1, 1, 0, 100]);
          reply(0xba, [0, 0, 3, 80, ...u16(110)]);
          reply(0xbb, [75, 1]);
          reply(0xc9, [0]);
        case 0x96:
          // An unrelated preset notification must not satisfy this request.
          final i = f.payload[0];
          reply(0x97, [(i + 1) % 40, ...presets[(i + 1) % 40]]);
          reply(0x97, [i, ...presets[i]]);
        case 0x97:
          writes++;
          selected = f.payload[0];
          presets[selected] = Uint8List.fromList(f.payload.sublist(1));
          reply(0x99, [1]);
          reply(0x98, [selected]);
        case 0x98:
          selected = f.payload[0];
          reply(0x98, [selected]);
        case 0x61: // IR upload frame: assemble like proto.c ir_upload()
          final slot = read16(f.payload, 1);
          final total = f.payload[3], idx = f.payload[4];
          final len = read16(f.payload, 5);
          if (f.payload[0] != 1 || slot < 1 || slot > 9) return;
          if (idx == 0) {
            irUploadSlot = slot;
            irAssembled = [];
            irUploadNameBytes = f.payload.sublist(7, 7 + len);
          } else if (slot == irUploadSlot) {
            irAssembled?.addAll(f.payload.sublist(7, 7 + len));
          }
          irUploadFrames.add(idx);
          if (irUploadFrames.length == total && idx == total - 1) {
            irUsed[slot - 1] = true;
            irNames[slot - 1]
              ..fillRange(0, 50, 0)
              ..setAll(0, irUploadNameBytes ?? const []);
          }
          reply(0x62, [1, slot & 255, 0, idx]);
        case 0x65: // IR slot list
          if (f.payload.length == 5 && f.payload[0] == 1) {
            final out = <int>[];
            for (var s = 1; s <= 9; s++) {
              final name = irNames[s - 1];
              out
                ..add(1)
                ..addAll(u16(s))
                ..add(irUsed[s - 1] ? 1 : 0)
                ..add(irUsed[s - 1] ? 2 : 0)
                ..addAll(name)
                ..add(irUsed[s - 1] ? 50 : 0)
                ..addAll([0, 0, 0]);
            }
            reply(0x66, out);
          }
        case 0x67: // IR delete/rename
          final slot = read16(f.payload, 1), op = f.payload[3];
          var ok = 1;
          if (op == 1) {
            irUsed[slot - 1] = false;
            irNames[slot - 1]
              ..fillRange(0, 50, 0)
              ..setRange(0, 5, 'Empty'.codeUnits);
          } else if (irUsed[slot - 1]) {
            irNames[slot - 1]
              ..fillRange(0, 50, 0)
              ..setAll(0, f.payload.sublist(4));
          } else {
            ok = 0;
          }
          reply(0x68, [1, slot & 255, slot >> 8, ok]);
        case 0xb3:
          btName = f.payload;
        // No reply: the stock protocol has none for B3.
        case 0xa0:
          moduleOrder = f.payload;
        case 0xd7:
          final op = f.payload[0];
          if (op == 0) {
            final out = <int>[
              looperState,
              looperLevelValue,
              1, 0, // len s
              0, 0, // pos s
              133, 0, // max s
              7, 0, // prep s
              0,
              0,
              0,
            ];
            reply(0xd8, out);
          } else {
            looperLog.add('op$op');
            reply(0xd8, [looperState == 0 ? (op == 7 ? 2 : 1) : 0]);
          }
        // No reply: the stock protocol has none for B3/A0.
      }
    };
  }

  static List<int> irUploadName(Frame f) => const [];
  Future<void> close() async {
    pedal.dispose();
    await wire.close();
  }
}

void main() {
  test(
    'stock connect and bank reads are read-only and correlate preset index',
    () async {
      final h = PedalHarness();
      await h.pedal.initialize();
      await h.pedal.loadBank(9);
      expect(h.pedal.presets[39]!.bytes[255], 39);
      expect(h.pedal.battery, 75);
      expect(h.pedal.charging, isTrue);
      expect(h.writes, 0);
      expect(PedalClient.address(39), '9D');
      await h.close();
    },
  );
  test(
    'copy and rename preserve NAM binding and unknown bytes, verify readback',
    () async {
      final h = PedalHarness();
      await h.pedal.initialize();
      final source = await h.pedal.readPreset(7);
      final renamed = source.renamed('Bass NAM');
      await h.pedal.store(15, renamed);
      expect(h.presets[15].sublist(20), source.bytes.sublist(20));
      expect(h.pedal.edit!.name, 'Bass NAM');
      expect(h.writes, 1);
      await h.close();
    },
  );
  test('backup round-trips all forty records and rejects CRC/order/size corruption before writes', () async {
    final h = PedalHarness();
    final backup = await h.pedal.backup();
    final parsed = PedalClient.parseBackup(backup);
    expect(parsed[39].bytes, h.presets[39]);
    final json = jsonDecode(utf8.decode(backup)) as Map;
    (json['presets'] as List)[0]['crc32'] = 0;
    expect(
      () => PedalClient.parseBackup(utf8.encode(jsonEncode(json))),
      throwsA(isA<DeviceError>()),
    );
    expect(
      () => PedalClient.parseBackup(List.filled(65537, 0)),
      throwsA(isA<DeviceError>()),
    );
    expect(h.writes, 0);
    await h.close();
  });
  test('NAM-aware copy of an unbound preset explicitly bypasses a destination binding', () async {
    final h = PedalHarness();
    final client = PedalClient(h.wire, namAware: true);
    final unbound = PedalPreset(Uint8List(256)).renamed('Stock copy');
    await client.store(6, unbound);
    expect(read16(h.presets[6], 0xde), 0x414e);
    expect(read16(h.presets[6], 0xe0), 0);
    client.dispose();
    await h.close();
  });
  test(
    'legacy exchanges exclude NAM writes and fail immediately on disconnect',
    () async {
      final link = MemoryLink();
      final wire = WireTransport(link);
      final pending = wire.exchange(0x96, [0], 0x97);
      await expectLater(wire.request(0, []), throwsA(isA<DeviceError>()));
      await expectLater(
        wire.sendCommand(0xba, [1]),
        throwsA(isA<DeviceError>()),
      );
      final result = expectLater(pending, throwsA(isA<DeviceError>()));
      link.incoming.addError(Exception('disconnected'));
      await result;
      expect(link.writes.length, 1);
      await wire.close();
    },
  );
  test(
    'malformed preset and invalid control values cause no device mutations',
    () async {
      final h = PedalHarness();
      expect(() => PedalPreset([1]), throwsA(isA<DeviceError>()));
      expect(
        () => PedalPreset(Uint8List(256)).renamed('日本語'),
        throwsA(isA<DeviceError>()),
      );
      await expectLater(
        h.pedal.setRhythm(on: true, pattern: 40, level: 80, bpm: 110),
        throwsArgumentError,
      );
      await expectLater(
        h.pedal.setTuner(on: true, mute: true, a4: 999),
        throwsArgumentError,
      );
      expect(h.link.writes, isEmpty);
      await h.close();
    },
  );
  test('IR names are sanitized like the reference tools', () {
    expect(PedalClient.sanitizeIrName('My  Cab\tIR'), 'My Cab IR');
    expect(PedalClient.sanitizeIrName('日本語 IR'), 'IR');
    expect(PedalClient.sanitizeIrName('   '), 'untitled');
    expect(PedalClient.sanitizeIrName('x' * 60).length, 50);
    expect(PedalClient.sanitizeIrName('x' * 60), 'x' * 50);
  });
  test('IR list parses used and empty slots', () async {
    final h = PedalHarness();
    final slots = await h.pedal.irList();
    expect(slots.length, 9);
    expect(slots[0].used, isFalse);
    expect(slots[2].used, isTrue);
    expect(slots[2].name, 'Cab IR');
    expect(slots[8].slot, 9);
    await h.close();
  });
  test(
    'IR upload sends one name frame then eight 512-byte data frames',
    () async {
      final h = PedalHarness();
      final samples = Float32List(1024);
      for (var i = 0; i < samples.length; i++) {
        samples[i] = i / samples.length;
      }
      final progress = <String>[];
      await h.pedal.irUpload(
        5,
        'Test IR',
        samples,
        progress: (sent, total) => progress.add('$sent/$total'),
      );
      expect(progress.first, '1/9');
      expect(progress.last, '9/9');
      expect(h.irUploadFrames, [for (var i = 0; i < 9; i++) i]);
      expect(h.irUploadNameBytes, 'Test IR'.codeUnits);
      expect(h.irUploadSlot, 5);
      final expected = ByteData(4096);
      for (var i = 0; i < 1024; i++) {
        expected.setFloat32(i * 4, samples[i], Endian.little);
      }
      expect(h.irAssembled, expected.buffer.asUint8List());
      expect(h.irUsed[4], isTrue);
      await h.close();
    },
  );
  test('IR upload rejects non-finite samples before any write', () async {
    final h = PedalHarness();
    final samples = Float32List(1024)..[100] = double.nan;
    await expectLater(
      h.pedal.irUpload(1, 'Bad', samples),
      throwsA(isA<DeviceError>()),
    );
    expect(h.link.writes, isEmpty);
    expect(h.irUploadFrames, isEmpty);
    await h.close();
  });
  test('IR rename and delete verify the acknowledgement', () async {
    final h = PedalHarness();
    await h.pedal.irRename(3, 'New Name');
    final name = latin1.decode(h.irNames[2]).split('\x00').first;
    expect(name, 'New Name');
    await h.pedal.irDelete(3);
    expect(h.irUsed[2], isFalse);
    await h.close();
  });
  test('renaming an empty IR slot fails without mutation', () async {
    final h = PedalHarness();
    // Slot 1 is empty: the fake answers ok=0 like the firmware.
    await expectLater(h.pedal.irRename(1, 'Nope'), throwsA(isA<DeviceError>()));
    expect(latin1.decode(h.irNames[0]).split('\x00').first, isEmpty);
    await h.close();
  });
  test(
    'Bluetooth name writes exactly twenty bytes and validates input',
    () async {
      final h = PedalHarness();
      await h.pedal.setBtName('FB200 KJ');
      expect(h.btName!.length, 20);
      expect(h.btName!.sublist(0, 8), 'FB200 KJ'.codeUnits);
      expect(h.btName!.sublist(8), everyElement(0));
      for (final bad in ['', 'way-too-long-bluetooth-name!', '日本語']) {
        await expectLater(h.pedal.setBtName(bad), throwsA(isA<DeviceError>()));
      }
      expect(h.link.writes.length, 1); // only the valid write
      await h.close();
    },
  );
  test('module order validates a permutation and sends seven bytes', () async {
    final h = PedalHarness();
    await h.pedal.setModuleOrder([6, 5, 4, 3, 2, 1, 0]);
    expect(h.moduleOrder, [6, 5, 4, 3, 2, 1, 0]);
    for (final bad in [
      [0, 1, 2, 3, 4, 5], // too short
      [0, 1, 2, 3, 4, 5, 7], // out of range
      [0, 0, 1, 2, 3, 4, 5], // duplicate
    ]) {
      await expectLater(
        h.pedal.setModuleOrder(bad),
        throwsA(isA<DeviceError>()),
      );
    }
    expect(h.moduleOrder, [6, 5, 4, 3, 2, 1, 0]);
    await h.close();
  });
  test('looper status parses and actions map codes to errors', () async {
    final h = PedalHarness();
    final s = await h.pedal.looperStatus();
    expect(s.state, 1);
    expect(s.level, 100);
    expect(s.lenS, 1);
    expect(s.maxS, 133);
    expect(s.undo, 0);
    expect(s.available, isTrue);
    expect(await h.pedal.looperAction(1), 0);
    expect(await h.pedal.looperAction(7), 0);
    expect(h.looperLog, ['op1', 'op7']);
    await expectLater(h.pedal.looperLevel(37), completes);
    await expectLater(h.pedal.looperSave(1), completes);
    await expectLater(h.pedal.looperLoad(2), completes);
    expect(h.looperLog, ['op1', 'op7', 'op8', 'op9', 'op10']);
    h.looperState = 0; // OFF: codes surface as device errors
    expect(await h.pedal.looperAction(7), 2);
    await expectLater(h.pedal.looperLevel(5), throwsA(isA<DeviceError>()));
    await h.close();
  });
}
