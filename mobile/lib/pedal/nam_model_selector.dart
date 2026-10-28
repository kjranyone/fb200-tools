import '../localization.dart';

import 'package:flutter/material.dart';

import '../model_kind.dart';
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

  /// Whether the cabinet / IR stage runs after NAM; null without one.
  final bool? cabOn;

  /// Null when the firmware cannot store a kind.
  final VoidCallback? onEditKind;

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
    this.cabOn,
    this.onEditKind,
  });

  @override
  Widget build(BuildContext context) {
    final state = this.state;
    final selected = state?.selected ?? 0;
    final name = activeModel;
    final empty = state != null && !state.slots.any((s) => s.name != null);
    final slot = state?.slots.where((s) => s.number == selected).firstOrNull;
    final kind = name == null ? null : slot?.kind;
    final wantsCab = kind?.wantsCab;
    final warning = !namOn || cabOn == null || wantsCab == null
        ? null
        : wantsCab && !cabOn!
        ? tr("アンプのみのモデルです。キャビネット/IRをオンにしてください")
        : !wantsCab && cabOn!
        ? tr("キャビ込みのモデルに、キャビネット/IRが重なっています")
        : null;
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
    // The whole strip opens the picker, which also offers add / transfer;
    // with nothing stored yet it goes straight to the library.
    final onTap = busy || state == null
        ? null
        : empty && onOpenLibrary != null
        ? onOpenLibrary
        : canChoose
        ? onChoose
        : null;
    return Semantics(
      button: true,
      label: empty ? tr("追加・転送") : tr("モデルを選ぶ"),
      child: Material(
        color: StudioTheme.background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: StudioTheme.nam.withValues(alpha: .45)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('choose-nam-model'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
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
                          ),
                          if (kind != null &&
                              (kind != ModelKind.unknown ||
                                  onEditKind != null)) ...[
                            const SizedBox(width: 8),
                            Flexible(
                              child: ModelKindBadge(
                                kind,
                                key: const ValueKey('nam-model-kind'),
                                onTap: busy ? null : onEditKind,
                              ),
                            ),
                          ],
                        ],
                      ),
                      Text(
                        warning ?? status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: warning == null
                              ? StudioTheme.ready
                              : const Color(0xffe4bd69),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  empty ? Icons.add : Icons.unfold_more,
                  size: 20,
                  color: onTap == null ? StudioTheme.line : StudioTheme.nam,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
