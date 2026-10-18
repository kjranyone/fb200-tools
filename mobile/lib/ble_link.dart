import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

import 'ble_profile.dart';
import 'protocol.dart';

class _ChannelPair {
  final Characteristic writer, reader;
  _ChannelPair(this.writer, this.reader);
}

class BleConnector {
  FlutterReactiveBle? _instance;
  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  FlutterReactiveBle get ble => _instance ??= FlutterReactiveBle();

  Future<void> prepare() async {
    if (!supported) throw DeviceError('実機へのBluetooth接続はAndroid / iOSで利用できます。');
    List<Permission> permissions;
    if (defaultTargetPlatform == TargetPlatform.android) {
      final sdk = await const MethodChannel('dev.fb200/platform')
          .invokeMethod<int>('androidSdkInt');
      permissions = (sdk ?? 0) >= 31
          ? [Permission.bluetoothScan, Permission.bluetoothConnect]
          : [Permission.locationWhenInUse];
    } else {
      permissions = [Permission.bluetooth];
    }
    final result = await permissions.request();
    if (result.values.any((v) => !v.isGranted && !v.isLimited)) {
      throw DeviceError('Bluetoothの利用を許可してください。拒否済みの場合は端末の設定から変更できます。');
    }
    await ble.initialize();
    if (ble.status != BleStatus.ready) {
      try {
        await ble.statusStream
            .firstWhere((s) => s == BleStatus.ready)
            .timeout(const Duration(seconds: 10));
      } on TimeoutException {
        throw DeviceError('Bluetoothをオンにしてください。');
      }
    }
  }

  Stream<DiscoveredDevice> scan() async* {
    await prepare();
    yield* ble.scanForDevices(withServices: [], scanMode: ScanMode.lowLatency);
  }

  Future<WireTransport> connect(String id) async {
    await prepare();
    final connected = Completer<void>();
    _BleFrameLink? link;
    late final StreamSubscription<ConnectionStateUpdate> subscription;
    subscription = ble
        .connectToDevice(id: id, connectionTimeout: const Duration(seconds: 12))
        .listen(
          (s) {
            if (s.connectionState == DeviceConnectionState.connected &&
                !connected.isCompleted) {
              connected.complete();
            }
            if (s.connectionState == DeviceConnectionState.disconnected) {
              if (!connected.isCompleted) {
                connected.completeError(DeviceError('本体に接続できませんでした。'));
              }
              link?.lost();
            }
          },
          onError: (Object error) {
            if (!connected.isCompleted) {
              connected.completeError(DeviceError('本体への接続に失敗しました。'));
            }
            link?.lost();
          },
        );
    try {
      await connected.future.timeout(const Duration(seconds: 15));
      await ble.discoverAllServices(id);
      final services = await ble.getDiscoveredServices(id);
      final route = selectFb200Uart([
        for (final service in services)
          for (final c in service.characteristics)
            BleEndpoint(
              handle: c,
              service: service.id.toString(),
              characteristic: c.id.toString(),
              writable: c.isWritableWithResponse || c.isWritableWithoutResponse,
              notifiable: c.isNotifiable || c.isIndicatable,
            ),
      ]);
      if (route == null) {
        throw DeviceError('FB200のモデル転送用Bluetooth通信が見つかりませんでした。FB200を選んでください。');
      }
      link = _BleFrameLink(
        _ChannelPair(route.writer, route.reader),
        subscription,
      );
      final transport = WireTransport(link);
      link.start();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return transport;
    } catch (_) {
      await link?.close();
      await subscription.cancel();
      rethrow;
    }
  }
}

class _BleFrameLink implements FrameLink {
  final _ChannelPair channel;
  final StreamSubscription<ConnectionStateUpdate> connection;
  final _bytes = StreamController<List<int>>();
  StreamSubscription<List<int>>? _notifications;
  bool _closed = false;
  _BleFrameLink(this.channel, this.connection);
  void start() {
    _notifications = channel.reader.subscribe().listen(
      (value) {
        if (!_closed) _bytes.add(value);
      },
      onError: (Object error) {
        lost();
      },
      onDone: lost,
    );
  }

  void lost() {
    if (_closed) return;
    _closed = true;
    _bytes.addError(DeviceError('Bluetooth接続が切れました。'));
    unawaited(_bytes.close());
  }

  @override
  Stream<List<int>> get bytes => _bytes.stream;
  @override
  Future<void> write(Uint8List value) async {
    if (_closed) throw DeviceError('Bluetooth接続が切れています。');
    for (var offset = 0; offset < value.length; offset += 20) {
      if (_closed) throw DeviceError('Bluetooth接続が切れています。');
      await channel.writer.write(
        value.sublist(offset, min(offset + 20, value.length)),
        withResponse: channel.writer.isWritableWithResponse,
      );
      if (!channel.writer.isWritableWithResponse) {
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _notifications?.cancel();
    await connection.cancel();
    if (!_bytes.isClosed) await _bytes.close();
  }
}
