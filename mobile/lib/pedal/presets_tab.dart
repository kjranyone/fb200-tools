import '../localization.dart';

import 'package:flutter/material.dart';

import '../pedal_client.dart';
import '../studio_theme.dart';

class _BankField extends StatelessWidget {
  final int bank;
  final bool busy, expanded;
  final void Function(int bank) onBank;
  const _BankField(this.bank, this.busy, this.onBank, {this.expanded = false});

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<int>(
    key: ValueKey(bank),
    initialValue: bank,
    decoration: InputDecoration(labelText: tr("バンク")),
    isExpanded: expanded,
    items: [
      for (var i = 0; i < 10; i++)
        DropdownMenuItem(value: i, child: Text('BANK $i')),
    ],
    onChanged: busy ? null : (v) => onBank(v!),
  );
}

/// Address, name and save state of the edited preset.
class PresetHeader extends StatelessWidget {
  final int selected;
  final String name;
  final bool dirty, busy;
  final VoidCallback onSave;
  const PresetHeader({
    super.key,
    required this.selected,
    required this.name,
    required this.dirty,
    required this.busy,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Text(
        PedalClient.address(selected),
        style: const TextStyle(
          fontSize: 36,
          fontWeight: FontWeight.w800,
          color: StudioTheme.blue,
          height: 1.1,
        ),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 3),
            Text(
              dirty ? tr("●  EDITED · 未保存") : tr("PRESET · 本体と同期済み"),
              style: TextStyle(
                fontSize: 10,
                letterSpacing: .8,
                color: dirty ? StudioTheme.nam : const Color(0xff8390a1),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(width: 6),
      FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: StudioTheme.nam,
          foregroundColor: StudioTheme.background,
        ),
        onPressed: busy ? null : onSave,
        icon: const Icon(Icons.save_outlined, size: 17),
        label: Text(tr("保存")),
      ),
    ],
  );
}

/// Wide-layout bank browser beside the editor.
class PresetSidebar extends StatelessWidget {
  final int bank, selected;
  final Map<int, PedalPreset> presets;
  final String version;
  final bool busy;
  final void Function(int bank) onBank;
  final void Function(int index) onSelect;
  const PresetSidebar({
    super.key,
    required this.bank,
    required this.selected,
    required this.presets,
    required this.version,
    required this.busy,
    required this.onBank,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'PRESETS',
        style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 1.8),
      ),
      const SizedBox(height: 16),
      _BankField(bank, busy, onBank),
      const SizedBox(height: 14),
      for (var i = bank * 4; i < bank * 4 + 4; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Material(
            color: i == selected
                ? StudioTheme.blue.withValues(alpha: .12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              leading: Text(
                PedalClient.address(i),
                style: TextStyle(
                  color: i == selected
                      ? StudioTheme.blue
                      : const Color(0xff8390a1),
                ),
              ),
              title: Text(
                presets[i]?.name ?? tr("読み込み前"),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
              onTap: busy ? null : () => onSelect(i),
            ),
          ),
        ),
      const SizedBox(height: 14),
      Text(
        '40 PRESETS  /  $version',
        style: const TextStyle(fontSize: 10, color: Color(0xff8390a1)),
      ),
    ],
  );
}

/// Bank grid with backup, restore, rename and copy of the selected preset.
class PresetsTab extends StatelessWidget {
  final int bank, selected;
  final Map<int, PedalPreset> presets;
  final bool busy;
  final void Function(int bank) onBank;
  final void Function(int index) onSelect;
  final VoidCallback onBackup, onRestore, onSave, onRename, onCopy;
  const PresetsTab({
    super.key,
    required this.bank,
    required this.selected,
    required this.presets,
    required this.busy,
    required this.onBank,
    required this.onSelect,
    required this.onBackup,
    required this.onRestore,
    required this.onSave,
    required this.onRename,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(child: _BankField(bank, busy, onBank, expanded: true)),
          const SizedBox(width: 8),
          PopupMenuButton<String>(
            enabled: !busy,
            onSelected: (v) => v == 'backup' ? onBackup() : onRestore(),
            itemBuilder: (context) => [
              PopupMenuItem(value: 'backup', child: Text(tr("全プリセットをファイルへ保存"))),
              PopupMenuItem(value: 'restore', child: Text(tr("バックアップから復元"))),
            ],
          ),
        ],
      ),
      const SizedBox(height: 8),
      GridView.count(
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 2.6,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (var i = bank * 4; i < bank * 4 + 4; i++)
            Card(
              margin: EdgeInsets.zero,
              color: i == selected
                  ? Theme.of(context).colorScheme.primaryContainer
                  : null,
              child: InkWell(
                onTap: busy ? null : () => onSelect(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          Text(
                            PedalClient.address(i),
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                          const Spacer(),
                          if (i == selected)
                            Icon(
                              Icons.check_circle,
                              size: 16,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                        ],
                      ),
                      Text(
                        presets[i]?.name ?? tr("読み込み前"),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      Wrap(
        alignment: WrapAlignment.spaceEvenly,
        children: [
          TextButton(
            onPressed: busy ? null : onSave,
            child: Text(tr("編集内容を保存")),
          ),
          TextButton(
            onPressed: busy ? null : onRename,
            child: Text(tr("名前の変更")),
          ),
          TextButton(onPressed: busy ? null : onCopy, child: Text(tr("コピー"))),
        ],
      ),
    ],
  );
}
