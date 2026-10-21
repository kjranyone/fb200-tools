import 'localization.dart';

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
  int capabilityFlags = 0;
  int slotCount = 3;
  DeviceState? _cachedState;
  int? _cachedGeneration;

  NamClient(this.transport);
  Future<void> handshake() async => readSelection();

  /// A tiny capabilities reply includes the current selection. Knob/preset
  /// updates need this, not another 64-slot catalogue download.
  Future<int> readSelection() async {
    final p = await transport.request(0, []);
    if (p.length != 13 ||
        read32(p, 0) != 48000 ||
        read16(p, 4) != weightCount ||
        p[6] < 1 ||
        p[6] > 64 ||
        p[7] < 1 ||
        p[7] > 64 ||
        read16(p, 8) != packetBytes ||
        (read16(p, 10) & 7) != 7) {
      throw DeviceError(tr("本体のモデル管理形式に対応していません。対応ファームウェアを確認してください。"));
    }
    _chunkSize = p[7];
    slotCount = p[6];
    capabilityFlags = read16(p, 10);
    if (p[12] > slotCount) throw DeviceError(tr("不正なモデル選択です。"));
    return p[12];
  }

  /// Firmware advertises the paged list (op 1 takes a start index) as bit 5.
  bool get _pagedList => (capabilityFlags & 32) != 0;

  ModelSlot _slotRecord(Uint8List p, int off) {
    if (p[off + 1] > 1) throw DeviceError(tr("不正なスロット一覧です。"));
    final name = String.fromCharCodes(
      p.sublist(off + 2, off + 26).takeWhile((v) => v != 0),
    );
    return ModelSlot(
      p[off],
      p[off + 1] == 1 ? name : null,
      read32(p, off + 26),
    );
  }

  Future<DeviceState> readState({bool reuse = false}) async {
    final wire = transport is WireTransport ? transport as WireTransport : null;
    final generation = wire?.connectionGeneration;
    if (reuse &&
        wire != null &&
        !wire.isClosed &&
        _cachedState != null &&
        _cachedGeneration == generation) {
      return _cachedState!;
    }
    DeviceState remember(DeviceState state) {
      _cachedState = state;
      _cachedGeneration = generation;
      return state;
    }

    if (!_pagedList) {
      // Older firmware: one unpaged reply with every (three) slots.
      final p = await transport.request(1, []);
      if (p.length != 1 + slotCount * 30 || p[0] > slotCount) {
        throw DeviceError(tr("本体の一覧を読み取れませんでした。"));
      }
      return remember(
        DeviceState(p[0], [
          for (var i = 0; i < slotCount; i++)
            _checkedSlot(_slotRecord(p, 1 + i * 30), i + 1),
        ]),
      );
    }
    var selected = -1;
    final slots = <ModelSlot>[];
    for (var start = 0; start < slotCount;) {
      final p = await transport.request(1, [start]);
      if (p.length < 3 || p[1] != start || p[2] < 1) {
        throw DeviceError(tr("本体の一覧を読み取れませんでした。"));
      }
      if (selected < 0) selected = p[0];
      if (p[0] > slotCount) throw DeviceError(tr("不正なスロット一覧です。"));
      final count = p[2];
      if (3 + count * 30 != p.length) {
        throw DeviceError(tr("不正なスロット一覧です。"));
      }
      for (var i = 0; i < count; i++) {
        slots.add(_checkedSlot(_slotRecord(p, 3 + i * 30), start + i + 1));
      }
      start += count;
    }
    if (slots.length != slotCount || selected < 0) {
      throw DeviceError(tr("本体の一覧を読み取れませんでした。"));
    }
    return remember(DeviceState(selected, slots));
  }

  ModelSlot _checkedSlot(ModelSlot s, int expected) {
    if (s.number != expected) throw DeviceError(tr("不正なスロット一覧です。"));
    return s;
  }

  Future<void> select(int slot, {bool save = false}) async {
    await transport.request(6, [slot, save ? 1 : 0]);
  }

  Future<void> delete(int slot) async {
    await transport.request(7, [slot]);
  }

  /// Firmware capabilities include in-place rename (RPC op 9, flags bit 4).
  bool get canRename => (capabilityFlags & 16) != 0;

  /// Older firmware accepted these preset words without applying tone EQ.
  /// Gain/volume work on both; only bit 9 guarantees the three-band EQ.
  bool get canToneEq => (capabilityFlags & 512) != 0;

  /// Rename a stored slot. The firmware rule (like the upload header):
  /// 1..23 printable ASCII bytes at 0x21..0x7E, no spaces, NUL padded to 24.
  Future<void> rename(int slot, String name) async {
    final codes = name.codeUnits;
    if (slot < 1 ||
        slot > slotCount ||
        codes.isEmpty ||
        codes.length > 23 ||
        codes.any((c) => c < 33 || c > 126)) {
      throw DeviceError(tr("モデル名は半角英数字・記号（空白なし）で1〜23文字にしてください。"));
    }
    if (!canRename) {
      throw DeviceError(tr("このファームウェアはモデル名の変更に対応していません。"));
    }
    await transport.request(9, [
      slot,
      ...codes,
      ...List.filled(24 - codes.length, 0),
    ]);
  }

  Future<void> upload(
    int slot,
    NamModel model, {
    required void Function(double) progress,
    required bool Function() cancelled,
    void Function()? committing,
  }) async {
    final wire = transport is WireTransport ? transport as WireTransport : null;
    final generation = wire?.connectionGeneration;
    void checkConnection() {
      if (wire != null &&
          (wire.isClosed || wire.connectionGeneration != generation)) {
        throw DeviceError(tr("転送中に接続が切れました。本体の一覧を確認し、必要なら最初から転送してください。"));
      }
    }

    var token = 0;
    try {
      checkConnection();
      final begin = await transport.request(2, [
        slot,
        ...u16(model.packet.length),
        ...u32(crc32(model.packet)),
      ]);
      if (begin.length != 6 || read16(begin, 4) != 0) {
        throw DeviceError(tr("転送を開始できませんでした。"));
      }
      token = read32(begin, 0);
      if (token == 0) throw DeviceError(tr("転送番号を確認できませんでした。"));
      var offset = 0;
      while (offset < model.packet.length) {
        checkConnection();
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
          throw DeviceError(tr("転送位置が一致しません。再転送してください。"));
        }
        offset = end;
        progress(offset / model.packet.length);
      }
      if (cancelled()) throw TransferCancelled();
      committing?.call();
      checkConnection();
      await transport.request(4, u32(token));
      token = 0;
    } catch (_) {
      if (token != 0 &&
          (wire == null ||
              (!wire.isClosed && wire.connectionGeneration == generation))) {
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
    if (closed) throw DeviceError(tr("デモを終了しました。"));
    await Future<void>.delayed(Duration(milliseconds: op == 3 ? 8 : 80));
    switch (op) {
      case 0:
        return Uint8List.fromList([
          ...u32(48000),
          ...u16(weightCount),
          3,
          64,
          ...u16(packetBytes),
          ...u16(7 | 16 | 32 | 512),
          _selected,
        ]);
      case 1:
        // Paged list like the firmware: [selected][start][count] + records.
        final start = a.isEmpty ? 0 : a[0];
        if (a.length != 1 || start >= 3) throw DeviceError(tr("不正なスロット一覧です。"));
        final out = <int>[_selected, start, 3 - start];
        for (var slot = start + 1; slot <= 3; slot++) {
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
          throw DeviceError(tr("転送位置が不正です。"));
        }
        _pending.addAll(a.sublist(6));
        return Uint8List.fromList([...u32(_token), ...u16(_pending.length)]);
      case 4:
        if (_pending.length != packetBytes || crc32(_pending) != _crc) {
          throw DeviceError(tr("転送データが不正です。"));
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
          throw DeviceError(tr("空のスロットです。"));
        }
        _selected = a[0];
        return Uint8List(0);
      case 7:
        _models.remove(a[0]);
        _names.remove(a[0]);
        if (_selected == a[0]) _selected = 0;
        return Uint8List(0);
      case 9:
        if (!_names.containsKey(a[0])) {
          throw DeviceError(tr("空のスロットです。"));
        }
        _names[a[0]] = String.fromCharCodes(
          a.sublist(1, 25).takeWhile((v) => v != 0),
        );
        return Uint8List(0);
      default:
        throw DeviceError(tr("未対応の操作です。"));
    }
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
