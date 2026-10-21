import 'package:flutter/material.dart';

import '../connection_recovery.dart';

/// Keep the last known editor visible while device writes are disabled.
/// Reconnecting is connection status, not a modal task the user must dismiss.
class RecoveryLayer extends StatelessWidget {
  final ConnectionRecovery? recovery;
  final Widget child;
  const RecoveryLayer({super.key, required this.recovery, required this.child});

  @override
  Widget build(BuildContext context) {
    final session = recovery;
    if (session == null) return child;
    return AnimatedBuilder(
      animation: session,
      builder: (context, _) => Stack(
        fit: StackFit.expand,
        children: [
          AbsorbPointer(absorbing: !session.connected, child: child),
          if (!session.connected)
            Align(
              alignment: Alignment.topCenter,
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                child: SafeArea(
                  bottom: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        child: Wrap(
                          spacing: 16,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              session.phase == RecoveryPhase.synchronizing
                                  ? '本体の状態を再同期中 · 操作は復旧後に再開できます'
                                  : session.busy
                                  ? '本体へ再接続中（${session.attempt}/${session.retryDelays.length}）'
                                  : '本体との接続が切れました',
                            ),
                            if (session.draft != null)
                              const Text('未保存の下書きを保持しています'),
                            TextButton.icon(
                              onPressed: session.busy
                                  ? session.cancelRecovery
                                  : () => session.reconnect(),
                              icon: Icon(
                                session.busy ? Icons.close : Icons.refresh,
                                size: 18,
                              ),
                              label: Text(session.busy ? '再接続を中止' : '同じ本体に再接続'),
                            ),
                          ],
                        ),
                      ),
                      if (!session.busy)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: Text(
                            session.error.isNotEmpty
                                ? session.error
                                : '本体の電源とBluetoothを確認してください。転送や保存は自動で再実行しません。',
                          ),
                        ),
                      if (session.busy)
                        const LinearProgressIndicator(minHeight: 2),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
