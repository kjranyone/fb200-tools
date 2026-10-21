import 'dart:async';

import 'package:flutter/foundation.dart';

import 'protocol.dart';

enum RecoveryPhase {
  connected,
  disconnected,
  connecting,
  synchronizing,
  failed,
  closed,
}

class RecoveryDraft {
  final int preset;
  final Uint8List bytes;
  RecoveryDraft(this.preset, List<int> bytes)
    : bytes = Uint8List.fromList(bytes);
}

/// One owner for a pedal connection, shared by every open route. Recovery
/// replaces the link, then runs read-only resynchronizers in registration order.
/// Interrupted mutations are never replayed. Restoring a draft is explicit.
class ConnectionRecovery extends ChangeNotifier {
  final WireTransport transport;
  final Future<FrameLink> Function() openLink;
  final Future<void> Function()? cancelOpening;
  final List<Duration> retryDelays;
  final Duration heartbeatInterval;
  final _resynchronizers = <Future<void> Function()>[];
  RecoveryPhase phase = RecoveryPhase.connected;
  RecoveryDraft? draft;
  int attempt = 0, generation = 0;
  String error = '';
  bool _foreground = true, _disposed = false;
  Timer? _heartbeat, _delay;
  Completer<void>? _delayDone;
  Future<void>? _recovering;

  ConnectionRecovery(
    this.transport,
    this.openLink, {
    this.cancelOpening,
    this.retryDelays = const [
      Duration(milliseconds: 500),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ],
    this.heartbeatInterval = const Duration(seconds: 8),
  }) {
    transport.onDisconnected = _lost;
    if (heartbeatInterval > Duration.zero) {
      _heartbeat = Timer.periodic(
        heartbeatInterval,
        (_) => unawaited(checkConnection()),
      );
    }
  }

  bool get connected => phase == RecoveryPhase.connected && !transport.isClosed;
  bool get busy =>
      phase == RecoveryPhase.connecting || phase == RecoveryPhase.synchronizing;
  void addResynchronizer(Future<void> Function() callback) =>
      _resynchronizers.add(callback);
  void removeResynchronizer(Future<void> Function() callback) =>
      _resynchronizers.remove(callback);

  void keepDraft(int preset, List<int> bytes) {
    draft ??= RecoveryDraft(preset, bytes);
  }

  void clearDraft() {
    draft = null;
    if (!_disposed) notifyListeners();
  }

  void _lost() {
    if (_disposed ||
        phase == RecoveryPhase.closed ||
        phase == RecoveryPhase.failed) {
      return;
    }
    if (busy) {
      return; // the in-flight recovery loop detects the closed transport
    }
    phase = RecoveryPhase.disconnected;
    error = '';
    notifyListeners(); // capture route drafts before reading anything again
    if (_foreground) unawaited(reconnect(automatic: true));
  }

  Future<void> _wait(Duration duration) async {
    if (duration == Duration.zero) return;
    final done = Completer<void>();
    _delayDone = done;
    _delay = Timer(duration, () {
      if (!done.isCompleted) done.complete();
    });
    await done.future;
    if (identical(_delayDone, done)) {
      _delay = null;
      _delayDone = null;
    }
  }

  Future<void> reconnect({bool automatic = false}) {
    if (_disposed || phase == RecoveryPhase.closed || connected) {
      return Future.value();
    }
    if (_recovering != null) return _recovering!;
    final epoch = ++generation;
    final work = _recover(epoch, automatic);
    _recovering = work;
    unawaited(
      work.whenComplete(() {
        if (identical(_recovering, work)) _recovering = null;
      }),
    );
    return work;
  }

  Future<void> _recover(int epoch, bool automatic) async {
    phase = RecoveryPhase.connecting;
    error = '';
    for (var n = 0; n < retryDelays.length; n++) {
      if (_disposed || epoch != generation) return;
      attempt = n + 1;
      phase = RecoveryPhase.connecting;
      notifyListeners();
      await _wait(n == 0 && !automatic ? Duration.zero : retryDelays[n]);
      if (_disposed || epoch != generation) return;
      try {
        // Release the previous GATT connection before opening a new one.
        await transport.detach();
        final link = await openLink();
        if (_disposed || epoch != generation) {
          await link.close();
          return;
        }
        await transport.replaceLink(link);
        phase = RecoveryPhase.synchronizing;
        notifyListeners();
        for (final callback in List.of(_resynchronizers)) {
          if (_disposed || epoch != generation) return;
          if (_resynchronizers.contains(callback)) await callback();
        }
        if (transport.isClosed) throw DeviceError('再同期中に接続が切れました。');
        if (_disposed || epoch != generation) return;
        phase = RecoveryPhase.connected;
        error = '';
        notifyListeners();
        return;
      } catch (e) {
        if (_disposed || epoch != generation) return;
        error = e is DeviceError
            ? e.message
            : '本体との通信を復旧できませんでした。電源とBluetoothを確認してください。';
      }
    }
    if (!_disposed && epoch == generation) {
      phase = RecoveryPhase.failed;
      notifyListeners();
    }
  }

  void cancelRecovery() {
    generation++;
    _delay?.cancel();
    if (_delayDone case final done? when !done.isCompleted) done.complete();
    _recovering = null;
    phase = RecoveryPhase.failed;
    error = '再接続を中止しました。準備ができたら再試行できます。';
    notifyListeners();
    if (cancelOpening case final cancel?) {
      unawaited(cancel().catchError((Object _) {}));
    }
    unawaited(transport.detach().catchError((Object _) {}));
  }

  void setForeground(bool value) {
    _foreground = value;
    if (value && !_disposed) {
      if (phase == RecoveryPhase.disconnected) {
        unawaited(reconnect(automatic: true));
      } else {
        unawaited(checkConnection());
      }
    }
  }

  Future<void> checkConnection() async {
    if (!_foreground || !connected || !transport.isIdle) return;
    try {
      await transport.exchange(0, [], 1);
    } catch (_) {
      // Transport loss/timeout already starts bounded recovery.
    }
  }

  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    generation++;
    phase = RecoveryPhase.closed;
    _heartbeat?.cancel();
    _delay?.cancel();
    if (_delayDone case final done? when !done.isCompleted) done.complete();
    transport.onDisconnected = null;
    try {
      await cancelOpening?.call();
    } catch (_) {}
    await transport.close();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
