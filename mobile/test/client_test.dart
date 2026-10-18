import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fb200_nam/nam_client.dart';
import 'package:fb200_nam/nam_model.dart';
import 'package:fb200_nam/protocol.dart';

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

void main() {
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
}
