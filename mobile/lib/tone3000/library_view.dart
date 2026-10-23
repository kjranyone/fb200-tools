import '../localization.dart';

import 'package:flutter/material.dart';

import '../tone_library.dart';
import 'widgets.dart';

/// Device tab: instant local search and multi-select, grouped by tone.
class ToneLibraryView extends StatelessWidget {
  final List<LibraryEntry> entries;
  final String query;
  final Set<int> selected;
  final bool enabled, canTransfer;
  final void Function(String query) onQuery;
  final void Function(int modelId, bool selected) onToggle;
  const ToneLibraryView({
    super.key,
    required this.entries,
    required this.query,
    required this.selected,
    required this.enabled,
    required this.canTransfer,
    required this.onQuery,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final groups = <int, List<LibraryEntry>>{};
    for (final entry in entries.where((e) => e.matches(query))) {
      groups.putIfAbsent(entry.tone.id, () => []).add(entry);
    }
    return ToneScroll([
      TextField(
        key: const ValueKey('tone-local-query'),
        onChanged: onQuery,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search),
          hintText: tr("保存したモデルを検索（モデル・トーン・作者）"),
          isDense: true,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        canTransfer
            ? tr("転送するモデルを選んでください。空きスロットへ順番に転送します。")
            : tr("端末に保存したモデルはオフラインで使えます。本体に接続してモデル管理から転送できます。"),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 12),
      if (entries.isEmpty)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(tr("まだモデルがありません。TONE3000タブからダウンロードしてください。")),
        )
      else if (groups.isEmpty)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(tr("一致するモデルがありません")),
        ),
      for (final group in groups.values)
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: ToneAttribution(group.first.tone),
                ),
                for (final entry in group)
                  CheckboxListTile(
                    dense: true,
                    value: selected.contains(entry.variant.id),
                    onChanged: enabled
                        ? (value) => onToggle(entry.variant.id, value == true)
                        : null,
                    title: Text(entry.variant.name),
                    subtitle: const Text('NAM A2 · A2-Lite'),
                  ),
              ],
            ),
          ),
        ),
    ]);
  }
}
