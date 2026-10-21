import 'package:flutter/material.dart';

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

  @override
  Widget build(BuildContext context) {
    final all = [
      if (!widget.transfer) const ModelSlot(0, 'BYPASS'),
      for (final slot in widget.state.slots)
        if (widget.transfer || slot.name != null) slot,
    ];
    final query = _query.trim().toLowerCase();
    final slots = all
        .where(
          (s) => '${s.number.toString().padLeft(2, '0')} ${s.name ?? '空きスロット'}'
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
                      widget.transfer ? '転送先を選ぶ' : '本体のNAMモデル',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (compact && widget.canAdd)
                    IconButton(
                      tooltip: 'モデルを追加・転送',
                      onPressed: () => Navigator.pop(context, -1),
                      icon: const Icon(Icons.add),
                    ),
                  IconButton(
                    tooltip: '閉じる',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              TextField(
                key: const ValueKey('nam-model-search'),
                onChanged: (value) => setState(() => _query = value),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: '名前・スロット番号で検索',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: slots.isEmpty
                    ? const Center(child: Text('一致するモデルがありません'))
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
                              title: Text(
                                slot.name ?? '空きスロット',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                widget.transfer
                                    ? slot.name == null
                                          ? '新しく保存'
                                          : '上書き前に確認します'
                                    : loaded
                                    ? '本体で選択中'
                                    : slot.number == 0
                                    ? 'NAMを通さない'
                                    : 'タップしてロード・試聴',
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
                  label: const Text('モデルを追加・転送'),
                ),
              if (!compact)
                Text(
                  widget.transfer
                      ? '転送後にロードして試聴できます。'
                      : '選択で試聴 · プリセットへの記録は「保存」',
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
