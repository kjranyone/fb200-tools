import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

int crc32(List<int> data) {
  var crc = 0xffffffff;
  for (final byte in data) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc >>> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

int crc16(List<int> bytes) {
  var crc = 0;
  for (final byte in bytes) {
    crc ^= byte << 8;
    for (var i = 0; i < 8; i++) {
      crc = ((crc << 1) ^ ((crc & 0x8000) != 0 ? 0x1021 : 0)) & 0xffff;
    }
  }
  return crc ^ 0xffff;
}

Uint8List u16(int n) => Uint8List.fromList([n & 255, (n >> 8) & 255]);
Uint8List u32(int n) =>
    Uint8List.fromList(List.generate(4, (i) => (n >> (8 * i)) & 255));
int read16(List<int> p, int offset) => p[offset] | p[offset + 1] << 8;
int read32(List<int> p, int offset) =>
    (p[offset] |
        p[offset + 1] << 8 |
        p[offset + 2] << 16 |
        p[offset + 3] << 24) &
    0xffffffff;

Uint8List frame(int command, List<int> payload) {
  if (payload.length > 1017) throw ArgumentError('Frame too large');
  final body = [...u16(payload.length + 1), command, ...payload];
  final crc = crc16(body);
  return Uint8List.fromList([0xaa, 0x55, ...body, crc >> 8, crc & 255]);
}

class Frame {
  final int command;
  final Uint8List payload;
  Frame(this.command, this.payload);
}

class FrameDecoder {
  final List<int> _buffer = [];
  Iterable<Frame> add(List<int> bytes) sync* {
    for (final byte in bytes) {
      _buffer.add(byte);
      while (_buffer.isNotEmpty) {
        if (_buffer.first != 0xaa ||
            (_buffer.length >= 2 && _buffer[1] != 0x55)) {
          _buffer.removeAt(0);
          continue;
        }
        if (_buffer.length < 4) break;
        final length = read16(_buffer, 2);
        if (length < 1 || length > 1018) {
          _buffer.removeAt(0);
          continue;
        }
        if (_buffer.length < length + 6) break;
        final crc = crc16(_buffer.sublist(2, 4 + length));
        if (_buffer[4 + length] != crc >> 8 ||
            _buffer[5 + length] != (crc & 255)) {
          _buffer.removeAt(0);
          continue;
        }
        yield Frame(
          _buffer[4],
          Uint8List.fromList(_buffer.sublist(5, 4 + length)),
        );
        _buffer.removeRange(0, length + 6);
      }
    }
  }
}

class DeviceError implements Exception {
  final String message;
  final int? status;
  DeviceError(this.message, [this.status]);
  @override
  String toString() => message;
}

abstract class RpcTransport {
  Future<Uint8List> request(int operation, List<int> arguments);
  Future<void> close();
}

abstract class FrameLink {
  Stream<List<int>> get bytes;
  Future<void> write(Uint8List value);
  Future<void> close();
}

class WireTransport implements RpcTransport {
  FrameLink link;
  final Duration timeout;
  final int retries;
  StreamSubscription<List<int>>? _subscription;
  FrameDecoder _decoder = FrameDecoder();
  Completer<Uint8List>? _pending;
  Completer<Frame>? _legacyPending;
  bool Function(Frame)? _legacyAccept;
  bool _legacyWriting = false;
  final _frames = StreamController<Frame>.broadcast();
  Stream<Frame> get frames => _frames.stream;
  int _id = Random().nextInt(65536), _operation = 0;
  bool _closed = false, _disposed = false;
  int _binding = 0;
  bool get isClosed => _closed;
  int get connectionGeneration => _binding;
  bool get isIdle =>
      _pending == null && _legacyPending == null && !_legacyWriting;
  Future<void> waitIdle() async {
    await _pending?.future;
    await _legacyPending?.future;
  }

  void Function()? onDisconnected;
  WireTransport(
    this.link, {
    this.timeout = const Duration(seconds: 1),
    this.retries = 2,
  }) {
    _listen();
  }

  void _listen() {
    final binding = _binding;
    _subscription = link.bytes.listen(
      (bytes) {
        if (_closed || binding != _binding) return;
        for (final incoming in _decoder.add(bytes)) {
          _frames.add(incoming);
          if (_legacyPending != null &&
              !_legacyPending!.isCompleted &&
              _legacyAccept!(incoming)) {
            _legacyPending!.complete(incoming);
          }
          final p = incoming.payload;
          if (incoming.command != 0xe1 ||
              p.length < 5 ||
              p[0] != 1 ||
              read16(p, 2) != _id ||
              p[1] != _operation ||
              _pending == null ||
              _pending!.isCompleted) {
            continue;
          }
          _pending!.complete(p);
        }
      },
      onError: (Object error) {
        if (binding == _binding) _disconnected();
      },
      onDone: () {
        if (binding == _binding) _disconnected();
      },
    );
  }

  /// Replace only the link. Clients and frame subscriptions keep their identity.
  /// No queued command, save or upload is replayed across connections.
  Future<void> detach() async {
    _closed = true;
    _binding++;
    _fail('接続が切れました。操作結果を再接続後に確認してください。');
    _pending = null;
    _legacyPending = null;
    _legacyAccept = null;
    _legacyWriting = false;
    final subscription = _subscription;
    final previous = link;
    _subscription = null;
    await subscription?.cancel();
    await previous.close();
  }

  Future<void> replaceLink(FrameLink next) async {
    if (_disposed) {
      await next.close();
      throw DeviceError('接続は終了しています。');
    }
    try {
      await detach();
    } catch (_) {
      await next.close();
      rethrow;
    }
    if (_disposed) {
      await next.close();
      throw DeviceError('接続は終了しています。');
    }
    link = next;
    _decoder = FrameDecoder();
    _closed = false;
    _listen();
  }

  Future<void> _write(Uint8List data) async {
    final binding = _binding;
    try {
      await link.write(data);
    } catch (_) {
      if (binding == _binding) _disconnected();
      rethrow;
    }
  }

  void _disconnected() {
    if (_closed) return;
    _closed = true;
    _fail('接続が切れました。再接続して一覧を確認してください。');
    onDisconnected?.call();
  }

  void _fail(String text) {
    if (_pending != null && !_pending!.isCompleted) {
      _pending!.completeError(DeviceError(text));
    }
    if (_legacyPending != null && !_legacyPending!.isCompleted) {
      _legacyPending!.completeError(DeviceError(text));
    }
  }

  void _checkAvailable() {
    if (_closed) throw DeviceError('再接続してください。');
    if (_pending != null || _legacyPending != null || _legacyWriting) {
      throw DeviceError('別の操作の完了を待ってください。');
    }
  }

  /// Legacy commands have no request ID. Serialize them with NAM RPC and never
  /// automatically retry mutations whose acknowledgement may have been lost.
  Future<void> sendCommand(int command, List<int> payload) async {
    _checkAvailable();
    _legacyWriting = true;
    final binding = _binding;
    try {
      await _write(frame(command, payload));
    } catch (_) {
      if (binding == _binding) _disconnected();
      rethrow;
    } finally {
      if (binding == _binding) _legacyWriting = false;
    }
  }

  Future<Frame> exchange(
    int command,
    List<int> payload,
    int reply, {
    bool Function(Frame)? accept,
  }) async {
    _checkAvailable();
    final pending = Completer<Frame>();
    unawaited(pending.future.then<void>((_) {}, onError: (Object _) {}));
    _legacyPending = pending;
    _legacyAccept = (f) => f.command == reply && (accept?.call(f) ?? true);
    try {
      await _write(frame(command, payload));
      return await pending.future.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      _disconnected();
      throw DeviceError('本体から応答がありません。再接続後に操作結果を確認してください。');
    } catch (_) {
      if (identical(_legacyPending, pending)) _disconnected();
      rethrow;
    } finally {
      if (identical(_legacyPending, pending)) {
        _legacyPending = null;
        _legacyAccept = null;
      }
    }
  }

  @override
  Future<Uint8List> request(int operation, List<int> arguments) async {
    _checkAvailable();
    _id = (_id + 1) & 65535;
    _operation = operation;
    final pending = Completer<Uint8List>();
    // A disconnect can arrive while write() is still awaiting a GATT chunk.
    // Observe errors immediately; the request's await below still propagates.
    unawaited(pending.future.then<void>((_) {}, onError: (Object _) {}));
    _pending = pending;
    final encoded = frame(0xe0, [1, operation, ...u16(_id), ...arguments]);
    try {
      Uint8List? result;
      for (var attempt = 0; attempt <= retries; attempt++) {
        if (!pending.isCompleted) await _write(encoded);
        try {
          result = await pending.future.timeout(timeout);
          break;
        } on TimeoutException {
          if (attempt == retries) rethrow;
        }
      }
      final p = result!;
      if (p[4] != 0) {
        const messages = {
          1: 'モデルまたは送信内容を確認してください。',
          2: '本体が別の転送を処理中です。少し待ってから再試行してください。',
          3: 'モデルの整合性を確認できませんでした。再転送してください。',
          4: '本体の保存・読み込みに失敗しました。電池残量とスロットを確認してください。',
          5: 'この機能に対応するファームウェアが必要です。',
          6: '転送が中断されました。最初から再転送してください。',
        };
        throw DeviceError(messages[p[4]] ?? '本体が操作を受け付けませんでした。', p[4]);
      }
      return Uint8List.sublistView(p, 5);
    } on TimeoutException {
      // Optional NAM capability probing must still allow stock firmware.
      if (operation != 0) _disconnected();
      throw DeviceError('本体から応答がありません。対応ファームウェアと接続を確認してください。');
    } finally {
      if (identical(_pending, pending)) _pending = null;
    }
  }

  @override
  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    onDisconnected = null;
    try {
      await detach();
    } finally {
      if (!_frames.isClosed) await _frames.close();
    }
  }
}
