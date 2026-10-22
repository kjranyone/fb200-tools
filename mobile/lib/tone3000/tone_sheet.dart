import '../localization.dart';

import 'package:flutter/material.dart';

import '../tone3000.dart';
import '../tone_library.dart';
import 'widgets.dart';

class ToneChoice {
  final List<ToneModel> models;

  /// True when the stored models go on to transfer.
  final bool transfer;
  ToneChoice(this.models, this.transfer);
}

/// Model picker for one tone; pops a [ToneChoice] or null.
class ToneSheet extends StatefulWidget {
  final TonePack tone;
  final List<ToneModel> models;
  final ToneLibrary library;
  final bool canTransfer;
  const ToneSheet({
    super.key,
    required this.tone,
    required this.models,
    required this.library,
    required this.canTransfer,
  });
  @override
  State<ToneSheet> createState() => _ToneSheetState();
}

class _ToneSheetState extends State<ToneSheet> {
  /// New variants start selected; stored ones can be added for transfer.
  late final Set<int> _chosen = {
    for (final m in widget.models)
      if (!widget.library.has(m.id)) m.id,
  };

  List<ToneModel> get _models =>
      widget.models.where((m) => _chosen.contains(m.id)).toList();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ToneAttribution(widget.tone),
        if (widget.tone.description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              widget.tone.description,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        const SizedBox(height: 12),
        Text(
          tr("モデルを選択"),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        Text(tr("取得後に48 kHz・固定A2-Lite構成を確認します。取り込みだけでは本体へ送信されません。")),
        Expanded(
          child: widget.models.isEmpty
              ? Center(child: Text(tr("A2モデルがありません。別のトーンを選択してください。")))
              : ListView(
                  children: [
                    for (final model in widget.models)
                      CheckboxListTile(
                        value: _chosen.contains(model.id),
                        onChanged: (value) => setState(
                          () => value == true
                              ? _chosen.add(model.id)
                              : _chosen.remove(model.id),
                        ),
                        title: Text(model.name),
                        subtitle: Text(
                          widget.library.has(model.id)
                              ? tr("端末に保存済み")
                              : 'NAM A2',
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 8),
        if (widget.canTransfer)
          FilledButton.icon(
            onPressed: _chosen.isEmpty
                ? null
                : () => Navigator.pop(context, ToneChoice(_models, true)),
            icon: const Icon(Icons.upload_outlined),
            label: Text(tr("{0} 件を保存して転送へ", [_chosen.length])),
          ),
        OutlinedButton.icon(
          onPressed: _chosen.isEmpty
              ? null
              : () => Navigator.pop(context, ToneChoice(_models, false)),
          icon: const Icon(Icons.download_outlined),
          label: Text(tr("{0} 件を端末に保存", [_chosen.length])),
        ),
      ],
    ),
  );
}
