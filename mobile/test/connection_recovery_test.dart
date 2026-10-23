import 'dart:async';
import 'dart:io';

import 'package:fb200_nam/connection_recovery.dart';
import 'package:fb200_nam/protocol.dart';
import 'package:fb200_nam/nam_client.dart';
import 'package:fb200_nam/nam_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'protocol_test.dart' show MemoryLink;

Future<void> settleRecovery(ConnectionRecovery recovery) async {
  for (
    var i = 0;
    i < 100 && recovery.phase != RecoveryPhase.failed && !recovery.connected;
    i++
  ) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  test('an upload interrupted during GATT write never sends abort or data to a new connection', () async {
    final old = MemoryLink(), next = MemoryLink();
    final wire = WireTransport(old);
    final blocked = Completer<void>(), started = Completer<void>();
    old.sent = (bytes) async {
      final op = FrameDecoder().add(bytes).single.payload[1];
      if (op == 2) old.reply(bytes, data: [...u32(1), ...u16(0)]);
      if (op == 3) {
        started.complete();
        await blocked.future;
      }
    };
    final model = NamModel.parse(
      File('test/fixtures/synthetic.nam').readAsBytesSync(),
      'test.nam',
    );
    final upload = NamClient(wire)
        .upload(1, model, progress: (_) {}, cancelled: () => false);
    final failure = expectLater(upload, throwsA(isA<DeviceError>()));
    await started.future;
    await wire.replaceLink(next);
    blocked.complete();
    await failure;
    expect(next.writes, isEmpty);
    await wire.close();
  });

  test(
    'silent-link heartbeat detects loss and reconnects with no mutation replay',
    () async {
      final old = MemoryLink(), next = MemoryLink();
      final wire = WireTransport(old);
      final recovery = ConnectionRecovery(
        wire,
        () async => next,
        retryDelays: const [Duration.zero],
        heartbeatInterval: Duration.zero,
        probeTimeout: const Duration(milliseconds: 5),
      );
      await recovery.checkConnection();
      expect(
        recovery.connected,
        isTrue,
        reason: 'one missed probe keeps GATT open',
      );
      await recovery.checkConnection();
      await settleRecovery(recovery);
      expect(recovery.connected, isTrue);
      expect(old.writes.length, 2);
      expect(FrameDecoder().add(old.writes.first).single.command, 0);
      expect(next.writes, isEmpty);
      await recovery.close();
      recovery.dispose();
    },
  );

  test(
    'valid traffic resets missed probes and active links skip idle checks',
    () async {
      final link = MemoryLink();
      final wire = WireTransport(link);
      final recovery = ConnectionRecovery(
        wire,
        () async => throw StateError('must not reconnect'),
        heartbeatInterval: Duration.zero,
        probeTimeout: const Duration(milliseconds: 5),
      );
      await recovery.checkConnection();
      link.incoming.add(frame(0xbb, [100, 0]));
      await Future<void>.delayed(Duration.zero);
      await recovery.checkConnection();
      expect(recovery.connected, isTrue);
      link.sent = (_) async => link.incoming.add(frame(0xbb, [99, 0]));
      await recovery.checkConnection();
      await recovery.checkConnection();
      expect(
        recovery.connected,
        isTrue,
        reason: 'live notifications prove GATT is healthy',
      );
      link.sent = (_) async => link.incoming.add(frame(1, [1]));
      await recovery.checkConnection();
      expect(recovery.connected, isTrue);
      await recovery.close();
      recovery.dispose();

      final active = MemoryLink();
      final healthy = ConnectionRecovery(
        WireTransport(active),
        () async => active,
      );
      await healthy.checkConnection();
      expect(
        active.writes,
        isEmpty,
        reason: 'recent link activity suppresses probes',
      );
      await healthy.close();
      healthy.dispose();
    },
  );

  test(
    'optional NAM probing may time out without breaking the stock connection',
    () async {
      final link = MemoryLink();
      final wire = WireTransport(
        link,
        timeout: const Duration(milliseconds: 1),
        retries: 0,
      );
      await expectLater(wire.request(0, []), throwsA(isA<DeviceError>()));
      expect(wire.isClosed, isFalse);
      link.sent = (_) async => link.incoming.add(frame(1, [1]));
      expect((await wire.exchange(0, [], 1)).payload, [1]);
      await wire.close();
    },
  );

  test(
    'a failed resync is retried and is never reported as connected early',
    () async {
      final wire = WireTransport(MemoryLink());
      final first = MemoryLink(), second = MemoryLink();
      var attempts = 0, reads = 0;
      final recovery = ConnectionRecovery(
        wire,
        () async => ++attempts == 1 ? first : second,
        retryDelays: const [Duration.zero, Duration.zero],
        heartbeatInterval: Duration.zero,
      );
      recovery.addResynchronizer(() async {
        expect(recovery.connected, isFalse);
        if (++reads == 1) throw DeviceError('resync failed');
      });
      (wire.link as MemoryLink).incoming.addError(Exception('lost'));
      await Future<void>.delayed(Duration.zero);
      await settleRecovery(recovery);
      expect(recovery.connected, isTrue);
      expect(reads, 2);
      expect(first.incoming.isClosed, isTrue);
      await recovery.close();
      recovery.dispose();
    },
  );

  test('recovery keeps frame subscribers, resets decoder and serializes read-only resync', () async {
    final old = MemoryLink(), next = MemoryLink();
    final wire = WireTransport(old);
    final seen = <int>[];
    final sub = wire.frames.listen((f) => seen.add(f.command));
    final order = <int>[];
    next.sent = (bytes) async {
      final f = FrameDecoder().add(bytes).single;
      next.incoming.add(frame(f.command + 1, [1]));
    };
    final recovery = ConnectionRecovery(
      wire,
      () async => next,
      retryDelays: const [Duration.zero],
      heartbeatInterval: Duration.zero,
    );
    recovery.addResynchronizer(() async {
      order.add(1);
      await wire.exchange(0, [], 1);
    });
    recovery.addResynchronizer(() async {
      order.add(2);
      await wire.exchange(0x96, [0], 0x97);
    });
    old.incoming.add([0xaa, 0x55, 0xff]);
    old.incoming.addError(Exception('radio lost'));
    await Future<void>.delayed(Duration.zero);
    await settleRecovery(recovery);
    expect(recovery.connected, isTrue);
    expect(order, [1, 2]);
    expect(seen, containsAll([1, 0x97]));
    expect(next.writes.map((b) => FrameDecoder().add(b).single.command), [
      0,
      0x96,
    ]);
    await sub.cancel();
    await recovery.close();
    recovery.dispose();
  });

  test(
    'automatic retries stop at the limit and manual retry can recover',
    () async {
      final old = MemoryLink();
      final wire = WireTransport(old);
      var calls = 0, fail = true;
      final recovery = ConnectionRecovery(
        wire,
        () async {
          calls++;
          if (fail) throw DeviceError('off');
          return MemoryLink();
        },
        retryDelays: const [Duration.zero, Duration.zero, Duration.zero],
        heartbeatInterval: Duration.zero,
      );
      old.incoming.addError(Exception('lost'));
      await Future<void>.delayed(Duration.zero);
      await settleRecovery(recovery);
      expect(calls, 3);
      expect(recovery.phase, RecoveryPhase.failed);
      fail = false;
      await recovery.reconnect();
      expect(recovery.connected, isTrue);
      expect(calls, 4);
      await recovery.close();
      recovery.dispose();
    },
  );

  test(
    'cancel closes a late connection and cannot revive the old attempt',
    () async {
      final old = MemoryLink();
      final wire = WireTransport(old);
      final opening = Completer<FrameLink>();
      final recovery = ConnectionRecovery(
        wire,
        () => opening.future,
        retryDelays: const [Duration.zero],
        heartbeatInterval: Duration.zero,
      );
      old.incoming.addError(Exception('lost'));
      await Future<void>.delayed(Duration.zero);
      recovery.cancelRecovery();
      final late = MemoryLink();
      opening.complete(late);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(recovery.phase, RecoveryPhase.failed);
      expect(late.incoming.isClosed, isTrue);
      await recovery.close();
      recovery.dispose();
    },
  );

  test(
    'background loss waits for resume; intentional close never reconnects',
    () async {
      final old = MemoryLink();
      final wire = WireTransport(old);
      var calls = 0;
      final recovery = ConnectionRecovery(
        wire,
        () async {
          calls++;
          return MemoryLink();
        },
        retryDelays: const [Duration.zero],
        heartbeatInterval: Duration.zero,
      );
      recovery.setForeground(false);
      old.incoming.addError(Exception('lost'));
      await Future<void>.delayed(Duration.zero);
      expect(calls, 0);
      expect(recovery.phase, RecoveryPhase.disconnected);
      recovery.setForeground(true);
      await settleRecovery(recovery);
      expect(calls, 1);
      await recovery.close();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      recovery.dispose();
    },
  );

  test('an exhausted RPC times out into recovery without replaying on the new link', () async {
    final old = MemoryLink(), next = MemoryLink();
    final wire = WireTransport(
      old,
      timeout: const Duration(milliseconds: 1),
      retries: 0,
    );
    final recovery = ConnectionRecovery(
      wire,
      () async => next,
      retryDelays: const [Duration.zero],
      heartbeatInterval: Duration.zero,
    );
    await expectLater(wire.request(6, [2, 1]), throwsA(isA<DeviceError>()));
    await settleRecovery(recovery);
    expect(recovery.connected, isTrue);
    expect(old.writes.length, 1);
    expect(next.writes, isEmpty);
    await recovery.close();
    recovery.dispose();
  });

  test(
    'old request completion cannot clear a request on the replacement link',
    () async {
      final old = MemoryLink(), next = MemoryLink();
      final write = Completer<void>();
      old.sent = (_) => write.future;
      final wire = WireTransport(old);
      final previous = wire.exchange(0x97, [0], 0x99);
      final failure = expectLater(previous, throwsA(isA<DeviceError>()));
      await wire.replaceLink(next);
      final fresh = wire.request(8, []);
      write.complete();
      await failure;
      expect(wire.isIdle, isFalse);
      next.reply(next.writes.single, data: [9]);
      expect(await fresh, [9]);
      await wire.close();
    },
  );

  test(
    'draft takes a copy and is not overwritten by later resync callbacks',
    () async {
      final wire = WireTransport(MemoryLink());
      final recovery = ConnectionRecovery(
        wire,
        () async => MemoryLink(),
        heartbeatInterval: Duration.zero,
      );
      final bytes = [1, 2, 3];
      recovery.keepDraft(3, bytes);
      bytes[0] = 99;
      recovery.keepDraft(4, [8]);
      expect(recovery.draft!.preset, 3);
      expect(recovery.draft!.bytes, [1, 2, 3]);
      recovery.clearDraft();
      expect(recovery.draft, isNull);
      await recovery.close();
      recovery.dispose();
    },
  );
}
