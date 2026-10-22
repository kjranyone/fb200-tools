import '../localization.dart';

import 'package:flutter/material.dart';

import '../pedal_client.dart';
import 'value_knob.dart';

class LooperTab extends StatelessWidget {
  final bool available, busy;

  /// Null until the first status reply.
  final LooperStatus? status;

  /// Looper op codes 1–6; clear (7) asks first through [onClear].
  final void Function(int op) onAction;
  final VoidCallback onClear;
  final void Function(int level) onLevel;
  final void Function(int slot) onSave, onLoad;
  const LooperTab({
    super.key,
    required this.available,
    required this.busy,
    required this.status,
    required this.onAction,
    required this.onClear,
    required this.onLevel,
    required this.onSave,
    required this.onLoad,
  });

  String get _summary {
    final s = status;
    if (s == null) return tr("状態を確認中…");
    final undo = s.undo == 0
        ? ''
        : s.undo == 1
        ? tr("・元に戻す可")
        : tr("・やり直し可");
    return tr("{0}  長さ {1}秒 / 最大 {2}秒{3}{4}{5}", [
      PedalClient.looperStates[s.state.clamp(0, 5)],
      s.lenS,
      s.maxS,
      undo,
      s.storeBusy ? tr("・保存中") : '',
      s.writing ? tr("・書込中") : '',
    ]);
  }

  @override
  Widget build(BuildContext context) {
    if (!available) {
      return Center(child: Text(tr("ルーパーはこのファームウェアでは利用できません。")));
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _summary,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonal(
              onPressed: busy ? null : () => onAction(1),
              child: Text(tr("タップ")),
            ),
            FilledButton.tonal(
              onPressed: busy ? null : () => onAction(2),
              child: Text(tr("録音")),
            ),
            FilledButton.tonal(
              onPressed: busy ? null : () => onAction(3),
              child: Text(tr("再生")),
            ),
            FilledButton.tonal(
              onPressed: busy ? null : () => onAction(4),
              child: Text(tr("ダビング")),
            ),
            TextButton(
              onPressed: busy ? null : () => onAction(5),
              child: Text(tr("停止")),
            ),
            TextButton(
              onPressed: busy ? null : () => onAction(6),
              child: Text(tr("元に戻す")),
            ),
            TextButton(onPressed: busy ? null : onClear, child: Text(tr("消去"))),
          ],
        ),
        const SizedBox(height: 8),
        Center(
          child: ValueKnob(
            tr("ループの音量"),
            status?.level ?? 100,
            0,
            100,
            onLevel,
            enabled: !busy,
          ),
        ),
        const SizedBox(height: 4),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          children: [
            for (var slot = 1; slot <= 2; slot++) ...[
              TextButton(
                onPressed: busy ? null : () => onSave(slot),
                child: Text(tr("{0}へ保存", [slot])),
              ),
              TextButton(
                onPressed: busy ? null : () => onLoad(slot),
                child: Text(tr("{0}から読込", [slot])),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
