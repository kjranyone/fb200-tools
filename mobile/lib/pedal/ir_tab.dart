import '../localization.dart';

import 'package:flutter/material.dart';

import '../pedal_client.dart';
import '../studio_theme.dart';

enum IrSlotAction { import, rename, delete }

class IrTab extends StatelessWidget {
  /// Null until the slot list has been read.
  final List<IrSlotInfo>? slots;
  final PedalPreset edit;
  final bool busy;

  /// False when the running firmware does not process cabinet IRs.
  final bool cabinetProcessed;
  final VoidCallback onLoad;
  final void Function(IrSlotInfo slot) onSlot;
  const IrTab({
    super.key,
    required this.slots,
    required this.edit,
    required this.busy,
    required this.cabinetProcessed,
    required this.onLoad,
    required this.onSlot,
  });

  @override
  Widget build(BuildContext context) {
    final slots = this.slots;
    if (slots == null) {
      return Center(
        child: OutlinedButton.icon(
          onPressed: busy ? null : onLoad,
          icon: const Icon(Icons.refresh),
          label: Text(tr("IR一覧を読み込む")),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!cabinetProcessed)
          Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text(
              tr(
                "現在のNAMファームウェアではキャビネットIRは音声処理に使われません。保存したIRはストックファームウェアで利用できます。",
              ),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12),
            ),
          ),
        GridView(
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 360,
            mainAxisExtent:
                104 + (MediaQuery.textScalerOf(context).scale(14) - 14) * 3,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
          ),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            for (final s in slots)
              Card(
                margin: EdgeInsets.zero,
                shape: edit.word(0x46) == s.slot + 10
                    ? RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: const BorderSide(color: StudioTheme.nam),
                      )
                    : null,
                child: InkWell(
                  onTap: busy ? null : () => onSlot(s),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'IR${s.slot}${edit.word(0x46) == s.slot + 10 ? tr(" · CABに割当（{0}）", [edit.word(0x44) == 0 ? 'OFF' : 'ON']) : ''}',
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                        Text(
                          s.used ? s.name : tr("空き"),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                color: s.used
                                    ? null
                                    : Theme.of(context).colorScheme.outline,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        Text(
          tr(
            "スロットをタップしてWAV取り込み・名前変更・削除。変換は公式エディタと同じ44.1 kHz・チャンネル0・1024サンプルです。",
          ),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12),
        ),
      ],
    );
  }
}

/// Rename and delete are offered only for a used slot.
Future<IrSlotAction?> pickIrSlotAction(BuildContext context, IrSlotInfo s) =>
    showModalBottomSheet<IrSlotAction>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                'IR${s.slot}  ${s.used ? s.name : tr("空き")}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: Text(tr("WAVから取り込み")),
              onTap: () => Navigator.pop(context, IrSlotAction.import),
            ),
            if (s.used) ...[
              ListTile(
                leading: const Icon(Icons.text_fields),
                title: Text(tr("名前の変更")),
                onTap: () => Navigator.pop(context, IrSlotAction.rename),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: Text(tr("削除")),
                onTap: () => Navigator.pop(context, IrSlotAction.delete),
              ),
            ],
          ],
        ),
      ),
    );
