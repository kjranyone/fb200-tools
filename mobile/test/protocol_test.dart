import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fb200_nam/protocol.dart';

class MemoryLink implements FrameLink {
  final incoming = StreamController<List<int>>();
  final writes = <Uint8List>[];
  Future<void> Function(Uint8List)? sent;
  @override
  Stream<List<int>> get bytes => incoming.stream;
  @override
  Future<void> write(Uint8List value) async {
    writes.add(value);
    await sent?.call(value);
  }

  void reply(Uint8List request, {int status = 0, List<int> data = const []}) {
    final p = FrameDecoder().add(request).single.payload;
    final answer = frame(0xe1, [...p.take(4), status, ...data]);
    for (var i = 0; i < answer.length; i += 3) {
      incoming.add(
        answer.sublist(i, i + 3 > answer.length ? answer.length : i + 3),
      );
    }
  }

  @override
  Future<void> close() async {
    if (!incoming.isClosed) await incoming.close();
  }
}

void main() {
  for (final probe in ['legacy', 'NAM']) {
    test(
      'waiting for an idle wire completes after a soft $probe timeout',
      () async {
        final link = MemoryLink();
        final wire = WireTransport(
          link,
          timeout: const Duration(milliseconds: 5),
          retries: 0,
        );
        final request = probe == 'legacy'
            ? wire.exchange(
                0,
                [],
                1,
                disconnectOnTimeout: false,
                responseTimeout: const Duration(milliseconds: 5),
              )
            : wire.request(0, []);
        final failed = expectLater(request, throwsA(isA<DeviceError>()));
        await wire.waitIdle().timeout(const Duration(seconds: 1));
        await failed;
        expect(wire.isIdle, isTrue);
        expect(wire.isClosed, isFalse);
        link.sent = (_) async => link.incoming.add(frame(1, [1]));
        await wire.exchange(0, [], 1);
        await wire.close();
      },
    );
  }
  test(
    'a slow large NAM page completes before any duplicate request is sent',
    () async {
      final link = MemoryLink();
      final payload = List.generate(993, (i) => i & 255);
      final timers = <Timer>[];
      link.sent = (request) async {
        timers.add(
          Timer(const Duration(milliseconds: 1200), () {
            link.reply(request, data: payload);
          }),
        );
      };
      final wire = WireTransport(link);
      expect(await wire.request(1, [0]), payload);
      expect(
        link.writes.length,
        1,
        reason: 'a 1 KB BLE page can take over one second',
      );
      for (final timer in timers) {
        timer.cancel();
      }
      await wire.close();
    },
  );
  test('stock framing and CRC agree with Python fixture', () {
    expect(frame(0xe0, [1, 0, 0x34, 0x12]), [
      0xaa,
      0x55,
      5,
      0,
      0xe0,
      1,
      0,
      0x34,
      0x12,
      0x30,
      0xc2,
    ]);
    expect(crc32('123456789'.codeUnits), 0xcbf43926);
    final decoder = FrameDecoder();
    final good = frame(0xe1, [1, 0, 1, 0, 0]);
    final bad = Uint8List.fromList(good)..[good.length - 1] ^= 1;
    final found = <Frame>[];
    for (final b in [0, 0xaa, 0xaa, 0x55, 0xff, 0xff, ...bad, ...good]) {
      found.addAll(decoder.add([b]));
    }
    expect(found.length, 1);
    expect(found.single.payload, [1, 0, 1, 0, 0]);
  });
  test(
    'lost ACK retries identical request, decodes fragmented response',
    () async {
      final link = MemoryLink();
      link.sent = (request) async {
        if (link.writes.length == 2) link.reply(request, data: [42]);
      };
      final wire = WireTransport(
        link,
        timeout: const Duration(milliseconds: 10),
      );
      expect(await wire.request(1, []), [42]);
      expect(link.writes.length, 2);
      expect(link.writes[0], link.writes[1]);
      await wire.close();
    },
  );
  test(
    'ignores unrelated op/id; reports device errors without retries',
    () async {
      final link = MemoryLink();
      link.sent = (request) async {
        link.incoming.add(frame(0xe1, [1, 7, 0, 0, 0]));
        link.reply(request, status: 3);
      };
      final wire = WireTransport(link);
      await expectLater(
        wire.request(2, []),
        throwsA(isA<DeviceError>().having((e) => e.status, 'status', 3)),
      );
      expect(link.writes.length, 1);
      await wire.close();
    },
  );
  test('disconnect during write rejects request and notifies once', () async {
    final link = MemoryLink();
    var disconnected = 0;
    final wire = WireTransport(link)..onDisconnected = () => disconnected++;
    link.sent = (_) async {
      link.incoming.addError(Exception('lost'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    };
    await expectLater(wire.request(0, []), throwsA(isA<DeviceError>()));
    await expectLater(wire.request(0, []), throwsA(isA<DeviceError>()));
    expect(disconnected, 1);
    await wire.close();
  });
  test(
    'timeout retries are bounded and concurrent operations are refused',
    () async {
      final link = MemoryLink();
      final wire = WireTransport(
        link,
        timeout: const Duration(milliseconds: 10),
        retries: 1,
      );
      final result = wire.request(0, []);
      await expectLater(wire.request(1, []), throwsA(isA<DeviceError>()));
      await expectLater(result, throwsA(isA<DeviceError>()));
      expect(link.writes.length, 2);
      await wire.close();
    },
  );
}
