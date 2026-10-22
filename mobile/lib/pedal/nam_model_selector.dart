import '../localization.dart';

import 'package:flutter/material.dart';

import '../nam_client.dart' show DeviceState;
import '../studio_theme.dart';

/// Loaded NAM slot of the edited preset, with model choice and library entry.
class NamModelSelector extends StatelessWidget {
  /// Null when the slot list could not be read.
  final DeviceState? state;
  final String? activeModel;

  /// Shown instead of the slot when [state] is unknown.
  final String? fallbackModel;
  final bool namOn, busy, canChoose;
  final VoidCallback onChoose;

  /// Null without NAM model management.
  final VoidCallback? onOpenLibrary;
  const NamModelSelector({
    super.key,
    required this.state,
    required this.activeModel,
    required this.fallbackModel,
    required this.namOn,
    required this.busy,
    required this.canChoose,
    required this.onChoose,
    required this.onOpenLibrary,
  });

  @override
  Widget build(BuildContext context) {
    final state = this.state;
    final selected = state?.selected ?? 0;
    final name = activeModel;
    final empty = state != null && !state.slots.any((s) => s.name != null);
    final status = state == null
        ? tr("モデルの状態を取得できません")
        : empty
        ? tr("保存済みモデルなし · 追加・転送へ")
        : selected == 0
        ? tr("NAMをバイパス中")
        : name == null
        ? tr("選択したスロットは空です。モデルを選び直してください")
        : !namOn
        ? tr("ロード済み · NAMはOFF")
        : tr("NAM有効 · ドラッグ中も音に反映");
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: StudioTheme.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: StudioTheme.nam.withValues(alpha: .45)),
      ),
      child: LayoutBuilder(
        builder: (context, box) => Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    state == null
                        ? fallbackModel ?? 'NAM MODEL'
                        : selected == 0
                        ? '00  BYPASS'
                        : '${selected.toString().padLeft(2, '0')}  ${name ?? tr("モデルなし")}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: StudioTheme.ready,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              key: const ValueKey('choose-nam-model'),
              style: FilledButton.styleFrom(
                backgroundColor: StudioTheme.nam,
                foregroundColor: StudioTheme.background,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              onPressed: busy || state == null || !canChoose ? null : onChoose,
              icon: const Icon(Icons.swap_horiz, size: 18),
              label: Text(box.maxWidth >= 560 ? tr("モデルを選ぶ") : tr("選ぶ")),
            ),
            if (onOpenLibrary != null)
              IconButton(
                key: const ValueKey('open-nam-library'),
                tooltip: tr("追加・転送"),
                onPressed: busy ? null : onOpenLibrary,
                icon: const Icon(Icons.add),
              ),
          ],
        ),
      ),
    );
  }
}
