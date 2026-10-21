import 'package:flutter/material.dart';

import '../connection_recovery.dart';

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
          if (!session.connected) ...[
            const ModalBarrier(color: Color(0xcc0c0f13), dismissible: false),
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 430),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            session.phase == RecoveryPhase.synchronizing
                                ? '本体の状態を再同期中'
                                : session.busy
                                ? '本体へ再接続中（${session.attempt}/${session.retryDelays.length}）'
                                : '本体との接続が切れました',
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            '本体の電源とBluetoothを確認してください。転送や保存は自動で再実行しません。',
                          ),
                          if (session.draft != null)
                            const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: Text('未保存の編集を下書きとして保持しています。'),
                            ),
                          if (session.error.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(session.error),
                            ),
                          const SizedBox(height: 16),
                          if (session.busy) ...[
                            const LinearProgressIndicator(),
                            TextButton(
                              onPressed: session.cancelRecovery,
                              child: const Text('再接続を中止'),
                            ),
                          ] else
                            FilledButton.icon(
                              onPressed: () => session.reconnect(),
                              icon: const Icon(Icons.refresh),
                              label: const Text('同じ本体に再接続'),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
