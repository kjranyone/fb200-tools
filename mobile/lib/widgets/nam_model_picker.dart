import '../localization.dart';

import 'package:flutter/material.dart';

import '../model_kind.dart';
import '../nam_client.dart';
import '../studio_theme.dart';

/// Returns a slot, null on dismissal, or -1 for the model library.
Future<int?> pickNamModel(
  BuildContext context,
  DeviceState state, {
  bool transfer = false,
  bool canAdd = false,
}) => showModalBottomSheet<int>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: MediaQuery.sizeOf(context).height >= 480,
  builder: (context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: FractionallySizedBox(
      heightFactor:
          MediaQuery.sizeOf(context).height < 480 ||
              MediaQuery.viewInsetsOf(context).bottom > 0
          ? .96
          : .85,
      child: NamModelPicker(state: state, transfer: transfer, canAdd: canAdd),
    ),
  ),
);

class NamModelPicker extends StatefulWidget {
  final DeviceState state;
  final bool transfer, canAdd;
  const NamModelPicker({
    super.key,
    required this.state,
    this.transfer = false,
    this.canAdd = false,
  });

  @override
  State<NamModelPicker> createState() => _NamModelPickerState();
}

class _NamModelPickerState extends State<NamModelPicker> {
  String _query = '';

  /// Null shows every kind.
  ModelKind? _kind;

  @override
  Widget build(BuildContext context) {
    final all = [
      if (!widget.transfer) const ModelSlot(0, 'BYPASS'),
      for (final slot in widget.state.slots)
        if (widget.transfer || slot.name != null) slot,
    ];
    final query = _query.trim().toLowerCase();
    final kinds = {
      for (final s in widget.state.slots)
        if (s.name != null) s.kind,
    };
    final slots = all
        .where(
          (s) =>
              (_kind == null || s.number == 0 || s.kind == _kind) &&
              '${s.number.toString().padLeft(2, '0')} ${s.name ?? tr("空きスロット")} ${s.name == null || s.number == 0 ? '' : s.kind.label}'
                  .toLowerCase()
                  .contains(query),
        )
        .toList();
    return LayoutBuilder(
      builder: (context, box) {
        final compact = box.maxHeight < 320;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.transfer ? tr("転送先を選ぶ") : tr("本体のNAMモデル"),
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (compact && widget.canAdd)
                    IconButton(
                      tooltip: tr("モデルを追加・転送"),
                      onPressed: () => Navigator.pop(context, -1),
                      icon: const Icon(Icons.add),
                    ),
                  IconButton(
                    tooltip: tr("閉じる"),
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              TextField(
                key: const ValueKey('nam-model-search'),
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: tr("名前・スロット番号で検索"),
                  isDense: true,
                ),
              ),
              if (!compact && kinds.length > 1 && !widget.transfer) ...[
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final kind in [null, ...ModelKind.values])
                        if (kind == null || kinds.contains(kind))
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              key: ValueKey(
                                'nam-kind-filter-${kind?.name ?? 'all'}',
                              ),
                              label: Text(kind?.label ?? tr("すべて")),
                              selected: _kind == kind,
                              onSelected: (_) => setState(() => _kind = kind),
                            ),
                          ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Expanded(
                child: slots.isEmpty
                    ? Center(child: Text(tr("一致するモデルがありません")))
                    : ListView.separated(
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        itemCount: slots.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 6),
                        itemBuilder: (context, index) {
                          final slot = slots[index];
                          final loaded = slot.number == widget.state.selected;
                          return Material(
                            color: loaded && !widget.transfer
                                ? StudioTheme.nam.withValues(alpha: .12)
                                : StudioTheme.background,
                            borderRadius: BorderRadius.circular(8),
                            child: ListTile(
                              key: ValueKey('nam-slot-${slot.number}'),
                              minVerticalPadding: 12,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                                side: BorderSide(
                                  color: loaded && !widget.transfer
                                      ? StudioTheme.nam
                                      : StudioTheme.line,
                                ),
                              ),
                              leading: Text(
                                slot.number.toString().padLeft(2, '0'),
                                style: const TextStyle(
                                  fontSize: 21,
                                  color: StudioTheme.nam,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              title: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      slot.name ?? tr("空きスロット"),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (slot.name != null &&
                                      slot.kind != ModelKind.unknown) ...[
                                    const SizedBox(width: 8),
                                    Flexible(child: ModelKindBadge(slot.kind)),
                                  ],
                                ],
                              ),
                              subtitle: Text(
                                widget.transfer
                                    ? slot.name == null
                                          ? tr("新しく保存")
                                          : tr("上書き前に確認します")
                                    : loaded
                                    ? tr("本体で選択中")
                                    : slot.number == 0
                                    ? tr("NAMを通さない")
                                    : tr("タップしてロード・試聴"),
                              ),
                              trailing: loaded && !widget.transfer
                                  ? const Icon(
                                      Icons.check_circle,
                                      color: StudioTheme.ready,
                                    )
                                  : const Icon(Icons.chevron_right),
                              onTap: () => Navigator.pop(context, slot.number),
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 10),
              if (widget.canAdd && !compact)
                OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context, -1),
                  icon: const Icon(Icons.add),
                  label: Text(tr("モデルを追加・転送")),
                ),
              if (!compact)
                Text(
                  widget.transfer
                      ? tr("転送後にロードして試聴できます。")
                      : tr("選択で試聴 · プリセットへの記録は「保存」"),
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xff9daaba),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
