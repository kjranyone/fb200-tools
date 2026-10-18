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
  PedalHarness() {
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
      }
    };
  }
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
}
