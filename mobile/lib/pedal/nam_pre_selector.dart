import '../localization.dart';

import 'package:flutter/material.dart';

import '../model_kind.dart';
import '../nam_client.dart' show DeviceState;
import '../studio_theme.dart';

/// Preset words of the second NAM, before the first (firmware
/// docs/NAM_FX_BLOCK.md, capability bit 13).
abstract final class NamPre {
  static const mark = 0xe2, slot = 0xe4, gain = 0xe6, level = 0xe8;
  static const marker = 0x324e; // "N2"
}

/// One line under the NAM model: the pre-stage capture and its chooser.
class NamPreSelector extends StatelessWidget {
  final DeviceState? state;

  /// 0: no second NAM.
  final int slot;
  final bool busy;
  final VoidCallback onChoose;
  const NamPreSelector({
    super.key,
    required this.state,
    required this.slot,
    required this.busy,
    required this.onChoose,
  });

  @override
  Widget build(BuildContext context) {
    final model = state?.slots.where((s) => s.number == slot).firstOrNull;
    final name = slot == 0 ? null : model?.name;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: StudioTheme.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: StudioTheme.line),
      ),
      child: Row(
        children: [
          const Text(
            'PRE',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: .8,
              color: StudioTheme.nam,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    slot == 0
                        ? tr("なし（NAMを1段で使用）")
                        : '${slot.toString().padLeft(2, '0')}  ${name ?? tr("モデルなし")}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (model != null &&
                    name != null &&
                    model.kind != ModelKind.unknown) ...[
                  const SizedBox(width: 8),
                  Flexible(child: ModelKindBadge(model.kind)),
                ],
              ],
            ),
          ),
          TextButton(
            key: const ValueKey('choose-nam-pre'),
            onPressed: busy || state == null ? null : onChoose,
            child: Text(tr("選ぶ")),
          ),
        ],
      ),
    );
  }
}
