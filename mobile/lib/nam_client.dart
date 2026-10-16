import 'dart:math';
import 'dart:typed_data';

import 'nam_model.dart';
import 'protocol.dart';

class ModelSlot {
  final int number;
  final String? name;
  final int crc;
  const ModelSlot(this.number, this.name, [this.crc = 0]);
}

class DeviceState {
  final int selected;
  final List<ModelSlot> slots;
  DeviceState(this.selected, this.slots);
}

class TransferCancelled implements Exception {}

class NamClient {
  final RpcTransport transport;
  int _chunkSize = 64;
  NamClient(this.transport);
  Future<void> handshake() async {
    final p = await transport.request(0, []);
    if (p.length != 13 ||
        read32(p, 0) != 48000 ||
        read16(p, 4) != weightCount ||
        p[6] != 3 ||
        p[7] < 1 ||
        p[7] > 64 ||
        read16(p, 8) != packetBytes ||
        (read16(p, 10) & 7) != 7) {
      throw DeviceError('本体のモデル管理形式に対応していません。対応ファームウェアを確認してください。');
    }
    _chunkSize = p[7];
  }

  Future<DeviceState> readState() async {
    final p = await transport.request(1, []);
    if (p.length != 91 || p[0] > 3) throw DeviceError('本体の一覧を読み取れませんでした。');
    final slots = <ModelSlot>[];
    for (var i = 0; i < 3; i++) {
      final off = 1 + i * 30;
      if (p[off] != i + 1 || p[off + 1] > 1) throw DeviceError('不正なスロット一覧です。');
      final name = String.fromCharCodes(
        p.sublist(off + 2, off + 26).takeWhile((v) => v != 0),
      );
      slots.add(
        ModelSlot(i + 1, p[off + 1] == 1 ? name : null, read32(p, off + 26)),
      );
    }
    return DeviceState(p[0], slots);
  }

  Future<void> select(int slot, {bool save = false}) async {
    await transport.request(6, [slot, save ? 1 : 0]);
  }

  Future<void> delete(int slot) async {
    await transport.request(7, [slot]);
  }

  Future<void> upload(
    int slot,
    NamModel model, {
    required void Function(double) progress,
    required bool Function() cancelled,
    void Function()? committing,
  }) async {
    var token = 0;
    try {
      final begin = await transport.request(2, [
        slot,
        ...u16(model.packet.length),
        ...u32(crc32(model.packet)),
      ]);
      if (begin.length != 6 || read16(begin, 4) != 0) {
        throw DeviceError('転送を開始できませんでした。');
      }
      token = read32(begin, 0);
      if (token == 0) throw DeviceError('転送番号を確認できませんでした。');
      var offset = 0;
      while (offset < model.packet.length) {
        if (cancelled()) throw TransferCancelled();
        final end = min(offset + _chunkSize, model.packet.length);
        final ack = await transport.request(3, [
          ...u32(token),
          ...u16(offset),
          ...model.packet.sublist(offset, end),
        ]);
        if (ack.length != 6 ||
            read32(ack, 0) != token ||
            read16(ack, 4) != end) {
          throw DeviceError('転送位置が一致しません。再転送してください。');
        }
        offset = end;
        progress(offset / model.packet.length);
      }
      if (cancelled()) throw TransferCancelled();
      committing?.call();
      await transport.request(4, u32(token));
      token = 0;
    } catch (_) {
      if (token != 0) {
        try {
          await transport.request(5, u32(token));
        } catch (_) {
          /* expiry/disconnect */
        }
      }
      rethrow;
    }
  }

  Future<void> close() => transport.close();
}

/// Explicit demo mode. No BLE instance or audio processing is created.
class DemoTransport implements RpcTransport {
  final _models = <int, NamModel>{};
  final _names = <int, String>{1: 'Demo Clean', 2: 'Demo Crunch'};
  int _selected = 1, _slot = 0, _crc = 0, _token = 0;
  List<int> _pending = [];
  bool closed = false;
  @override
  Future<Uint8List> request(int op, List<int> a) async {
    if (closed) throw DeviceError('デモを終了しました。');
    await Future<void>.delayed(Duration(milliseconds: op == 3 ? 8 : 80));
    switch (op) {
      case 0:
        return Uint8List.fromList([
          ...u32(48000),
          ...u16(weightCount),
          3,
          64,
          ...u16(packetBytes),
          7,
          0,
          _selected,
        ]);
      case 1:
        final out = <int>[_selected];
        for (var slot = 1; slot <= 3; slot++) {
          final name = _names[slot]?.codeUnits ?? [];
          out.addAll([
            slot,
            _names.containsKey(slot) ? 1 : 0,
            ...name,
            ...List.filled(24 - name.length, 0),
            ...u32(
              _models[slot] == null ? 0 : read32(_models[slot]!.packet, 16),
            ),
          ]);
        }
        return Uint8List.fromList(out);
      case 2:
        _slot = a[0];
        _crc = read32(a, 3);
        _pending = [];
        _token++;
        return Uint8List.fromList([...u32(_token), 0, 0]);
      case 3:
        if (read32(a, 0) != _token || read16(a, 4) != _pending.length) {
          throw DeviceError('転送位置が不正です。');
        }
        _pending.addAll(a.sublist(6));
        return Uint8List.fromList([...u32(_token), ...u16(_pending.length)]);
      case 4:
        if (_pending.length != packetBytes || crc32(_pending) != _crc) {
          throw DeviceError('転送データが不正です。');
        }
        final name = String.fromCharCodes(
          _pending.sublist(24, 48).takeWhile((v) => v != 0),
        );
        _models[_slot] = NamModel(name, Uint8List.fromList(_pending));
        _names[_slot] = name;
        _pending = [];
        return Uint8List(0);
      case 5:
        _pending = [];
        return Uint8List(0);
      case 6:
        if (a[0] != 0 && !_names.containsKey(a[0])) {
          throw DeviceError('空のスロットです。');
        }
        _selected = a[0];
        return Uint8List(0);
      case 7:
        _models.remove(a[0]);
        _names.remove(a[0]);
        if (_selected == a[0]) _selected = 0;
        return Uint8List(0);
      default:
        throw DeviceError('未対応の操作です。');
    }
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
