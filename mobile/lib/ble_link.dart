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
  int _openingGeneration = 0;
  Future<void> Function()? _cancelOpening;

  Future<void> cancelPendingConnection() async {
    _openingGeneration++;
    final cancel = _cancelOpening;
    _cancelOpening = null;
    await cancel?.call();
  }

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

  Future<WireTransport> connect(String id) async =>
      WireTransport(await openLink(id));

  Future<FrameLink> openLink(String id) async {
    final generation = ++_openingGeneration;
    await prepare();
    if (generation != _openingGeneration) throw DeviceError('再接続を中止しました。');
    final connected = Completer<void>();
    _BleFrameLink? link;
    var disconnected = false;
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
              disconnected = true;
              if (!connected.isCompleted) {
                connected.completeError(DeviceError('本体に接続できませんでした。'));
              }
              link?.lost();
            }
          },
          onError: (Object error) {
            disconnected = true;
            if (!connected.isCompleted) {
              connected.completeError(DeviceError('本体への接続に失敗しました。'));
            }
            link?.lost();
          },
          onDone: () {
            disconnected = true;
            if (!connected.isCompleted) {
              connected.completeError(DeviceError('本体への接続が終了しました。'));
            }
            link?.lost();
          },
        );
    Future<void> cancel() async {
      disconnected = true;
      if (!connected.isCompleted) {
        connected.completeError(DeviceError('再接続を中止しました。'));
      }
      await subscription.cancel();
    }

    _cancelOpening = cancel;
    try {
      await connected.future.timeout(const Duration(seconds: 15));
      await ble.discoverAllServices(id).timeout(const Duration(seconds: 10));
      final services = await ble
          .getDiscoveredServices(id)
          .timeout(const Duration(seconds: 10));
      if (disconnected || generation != _openingGeneration) {
        throw DeviceError('通信の準備中に接続が切れました。');
      }
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
      link.start();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (disconnected || link._closed || generation != _openingGeneration) {
        throw DeviceError('通信の準備中に接続が切れました。');
      }
      return link;
    } catch (_) {
      await link?.close();
      await subscription.cancel();
      rethrow;
    } finally {
      if (identical(_cancelOpening, cancel)) _cancelOpening = null;
    }
  }
}

class _BleFrameLink implements FrameLink {
  final _ChannelPair channel;
  final StreamSubscription<ConnectionStateUpdate> connection;
  // No request is sent until WireTransport subscribes. A broadcast stream
  // also lets cleanup finish if GATT fails before the link is returned.
  final _bytes = StreamController<List<int>>.broadcast();
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
      try {
        await channel.writer
            .write(
              value.sublist(offset, min(offset + 20, value.length)),
              withResponse: channel.writer.isWritableWithResponse,
            )
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        lost();
        throw DeviceError('Bluetooth通信が中断されました。再接続後に操作結果を確認してください。');
      }
      if (!channel.writer.isWritableWithResponse) {
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    // Android may already have torn GATT down (e.g. Bluetooth switched off).
    try {
      await _notifications?.cancel();
    } catch (_) {}
    try {
      await connection.cancel();
    } catch (_) {}
    if (!_bytes.isClosed) await _bytes.close();
  }
}
