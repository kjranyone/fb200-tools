import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fb200_nam/nam_client.dart';
import 'package:fb200_nam/nam_model.dart';
import 'package:fb200_nam/protocol.dart';

import 'protocol_test.dart' show MemoryLink;

class RecordingTransport implements RpcTransport {
  final demo = DemoTransport();
  final operations = <int>[];
  bool corruptAck = false, incompatible = false;
  @override
  Future<Uint8List> request(int op, List<int> args) async {
    operations.add(op);
    final reply = await demo.request(op, args);
    if (op == 0 && incompatible) reply[0] = 0;
    if (op == 3 && corruptAck) reply[4] ^= 1;
    return reply;
  }

  @override
  Future<void> close() => demo.close();
}

/// A firmware-like paged list over a dynamic slot count (flags bit 5).
class PagedTransport implements RpcTransport {
  final int slots;
  final int pageSize;
  final names = <int, String>{};
  int selected = 0;
  bool breakOrder = false;
  PagedTransport(this.slots, {this.pageSize = 4});
  @override
  Future<Uint8List> request(int op, List<int> a) async {
    switch (op) {
      case 0:
        return Uint8List.fromList([
          ...u32(48000),
          ...u16(1871),
          slots,
          64,
          ...u16(7548),
          ...u16(7 | 16 | 32),
          selected,
        ]);
      case 1:
        if (a.length != 1 || a[0] >= slots) throw DeviceError('bad page');
        final start = a[0];
        final count = pageSize < slots - start ? pageSize : slots - start;
        final out = <int>[selected, start, count];
        for (var i = 0; i < count; i++) {
          final slot = start + i + 1;
          final name = names[slot];
          final used = name != null;
          out
            ..add(breakOrder && i == 0 ? slot + 1 : slot)
            ..add(used ? 1 : 0)
            ..addAll(used ? name.codeUnits : const [])
            ..addAll(List.filled(used ? 24 - name.length : 24, 0))
            ..addAll(u32(used ? 0x12345678 : 0));
        }
        return Uint8List.fromList(out);
      default:
        throw DeviceError('unsupported');
    }
  }

  @override
  Future<void> close() async {}
}

/// The pre-paging firmware: unpaged op 1, three slots, no flags bit 5.
class LegacyTransport implements RpcTransport {
  @override
  Future<Uint8List> request(int op, List<int> a) async {
    if (op == 0) {
      return Uint8List.fromList([
        ...u32(48000),
        ...u16(1871),
        3,
        64,
        ...u16(7548),
        ...u16(7),
        2,
      ]);
    }
    if (op == 1 && a.isEmpty) {
      return Uint8List.fromList([
        2,
        1,
        1,
        ...'Only'.codeUnits,
        ...List.filled(20, 0),
        ...u32(1),
        2,
        0,
        ...List.filled(24, 0),
        ...u32(0),
        3,
        0,
        ...List.filled(24, 0),
        ...u32(0),
      ]);
    }
    throw DeviceError('unsupported');
  }

  @override
  Future<void> close() async {}
}

void main() {
  test('routes reuse one slot list per recovered wire generation', () async {
    final first = MemoryLink(), next = MemoryLink();
    final fixture = PagedTransport(64, pageSize: 33)..names[1] = 'Before';
    var pages = 0;
    void serve(MemoryLink link) {
      link.sent = (bytes) async {
        final p = FrameDecoder().add(bytes).single.payload;
        if (p[1] == 1) pages++;
        link.reply(bytes, data: await fixture.request(p[1], p.sublist(4)));
      };
    }

    serve(first);
    serve(next);
    final wire = WireTransport(first);
    final shared = NamClient(wire);
    await shared.handshake();
    expect((await shared.readState()).slots.first.name, 'Before');
    expect(pages, 2);
    await shared.readState(reuse: true);
    expect(pages, 2);
    fixture.names[1] = 'After';
    await wire.replaceLink(next);
    expect((await shared.readState(reuse: true)).slots.first.name, 'After');
    expect(pages, 4);
    await shared.readState(reuse: true);
    expect(pages, 4);
    await shared.close();
  });
  late NamModel model;
  setUp(() {
    model = NamModel.parse(
      File('test/fixtures/synthetic.nam').readAsBytesSync(),
      'synthetic.nam',
    );
  });
  test(
    'demo lists 3 slots, upload then explicitly select and save, delete active',
    () async {
      final transport = RecordingTransport();
      final client = NamClient(transport);
      await client.handshake();
      expect(client.canRename, isTrue);
      expect((await client.readState()).slots.length, 3);
      final progress = <double>[];
      var committing = false;
      await client.upload(
        3,
        model,
        progress: progress.add,
        cancelled: () => false,
        committing: () => committing = true,
      );
      expect(progress.last, 1);
      expect(committing, isTrue);
      var state = await client.readState();
      expect(state.selected, 1);
      expect(state.slots[2].name, 'synthetic');
      await client.select(3, save: true);
      expect((await client.readState()).selected, 3);
      await client.rename(3, 'renamed');
      state = await client.readState();
      expect(state.slots[2].name, 'renamed');
      expect(transport.operations.where((op) => op == 9).single, 9);
      await client.delete(3);
      state = await client.readState();
      expect(state.selected, 0);
      expect(state.slots[2].name, isNull);
      expect(transport.operations.where((op) => op == 3).length, 118);
      await client.close();
    },
  );
  test('rename validates names, empty slots and firmware capability', () async {
    final t = RecordingTransport();
    final client = NamClient(t);
    await client.handshake();
    for (final bad in ['', 'has space', '日本語', 'x' * 24]) {
      await expectLater(client.rename(1, bad), throwsA(isA<DeviceError>()));
    }
    await expectLater(client.rename(4, 'ok'), throwsA(isA<DeviceError>()));
    await expectLater(
      client.rename(3, 'ok'),
      throwsA(isA<DeviceError>()),
    ); // empty
    // Invalid names/range never reach the wire; the empty-slot check is the
    // device's, so exactly one op 9 went out and failed there.
    expect(t.operations.where((op) => op == 9).length, 1);
    client.capabilityFlags = 7; // older firmware without op 9
    expect(client.canRename, isFalse);
    await expectLater(client.rename(1, 'nope'), throwsA(isA<DeviceError>()));
    await client.close();
  });
  test(
    'cancelled transfer aborts and never commits or replaces existing slot',
    () async {
      final t = RecordingTransport();
      final client = NamClient(t);
      await client.handshake();
      var cancel = false;
      await expectLater(
        client.upload(
          1,
          model,
          progress: (_) => cancel = true,
          cancelled: () => cancel,
        ),
        throwsA(isA<TransferCancelled>()),
      );
      expect(t.operations, contains(5));
      expect(t.operations, isNot(contains(4)));
      expect((await client.readState()).slots.first.name, 'Demo Clean');
      await client.close();
    },
  );
  test('wrong ACK offset aborts without commit', () async {
    final t = RecordingTransport()..corruptAck = true;
    final client = NamClient(t);
    await client.handshake();
    await expectLater(
      client.upload(1, model, progress: (_) {}, cancelled: () => false),
      throwsA(isA<DeviceError>()),
    );
    expect(t.operations, isNot(contains(4)));
    expect(t.operations, contains(5));
    await client.close();
  });
  test('capability mismatch refuses model management', () async {
    final t = RecordingTransport()..incompatible = true;
    final client = NamClient(t);
    await expectLater(client.handshake(), throwsA(isA<DeviceError>()));
    expect(t.operations, [0]);
    await client.close();
  });
  test('paged list assembles any slot count across pages', () async {
    final t = PagedTransport(7)
      ..names[1] = 'One'
      ..names[5] = 'Five'
      ..names[7] = 'Seven'
      ..selected = 5;
    final client = NamClient(t);
    await client.handshake();
    expect(client.slotCount, 7);
    final state = await client.readState();
    expect(state.selected, 5);
    expect(state.slots.length, 7);
    expect(state.slots[0].name, 'One');
    expect(state.slots[4].name, 'Five');
    expect(state.slots[6].name, 'Seven');
    expect(state.slots[1].name, isNull);
    await client.close();
  });
  test('paged list rejects a slot-order corruption', () async {
    final t = PagedTransport(7)..names[2] = 'Two';
    final client = NamClient(t);
    await client.handshake();
    t.breakOrder = true;
    await expectLater(client.readState(), throwsA(isA<DeviceError>()));
    await client.close();
  });
  test('legacy unpaged firmware still lists its three slots', () async {
    final client = NamClient(LegacyTransport());
    await client.handshake();
    expect(client.slotCount, 3);
    final state = await client.readState();
    expect(state.selected, 2);
    expect(state.slots[0].name, 'Only');
    expect(state.slots[1].name, isNull);
    expect(state.slots[2].name, isNull);
    await client.close();
  });
}
