import '../localization.dart';

import 'package:flutter/material.dart';

import '../effect_parameters.dart';
import '../pedal_client.dart';

String moduleName(int index) {
  final names = [
    tr("コンプレッサー"),
    tr("ノイズゲート"),
    tr("アンプ"),
    tr("キャビネット / IR"),
    tr("モジュレーション"),
    tr("ディレイ"),
    tr("リバーブ"),
  ];
  return names[index.clamp(0, 6)];
}

/// Returns the reordered modules, or null when cancelled. [stored] is the
/// preset's order bytes.
Future<List<int>?> editModuleOrder(
  BuildContext context,
  List<int> stored,
) async {
  // Real presets can carry a stale/unknown sequence; repair it into a full
  // permutation (keep the valid prefix, append missing modules in default
  // order) instead of refusing to edit.
  final order = <int>[];
  final used = <int>{};
  for (final v in stored) {
    if (v < 0 || v > 6 || used.contains(v)) break;
    order.add(v);
    used.add(v);
  }
  for (var m = 0; m <= 6; m++) {
    if (!used.contains(m)) order.add(m);
  }
  var matches = order.length == stored.length;
  for (var i = 0; matches && i < order.length; i++) {
    matches = order[i] == stored[i];
  }
  final repaired = !matches;
  final changed = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialog) => AlertDialog(
        title: Text(tr("モジュールの接続順")),
        content: SizedBox(
          width: 320,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (repaired)
                  Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      tr("プリセットの順序データが壊れていたため、標準順で補いました。"),
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                for (var i = 0; i < order.length; i++)
                  Row(
                    children: [
                      Expanded(child: Text(moduleName(order[i]))),
                      IconButton(
                        icon: const Icon(Icons.arrow_upward),
                        onPressed: i == 0
                            ? null
                            : () => setDialog(() {
                                final t = order[i - 1];
                                order[i - 1] = order[i];
                                order[i] = t;
                              }),
                      ),
                      IconButton(
                        icon: const Icon(Icons.arrow_downward),
                        onPressed: i == order.length - 1
                            ? null
                            : () => setDialog(() {
                                final t = order[i + 1];
                                order[i + 1] = order[i];
                                order[i] = t;
                              }),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr("キャンセル")),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr("変更")),
          ),
        ],
      ),
    ),
  );
  return changed == true ? order : null;
}

Future<void> showEditorHelp(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    scrollable: true,
    title: Text(tr("音作りの操作")),
    content: Text(
      tr(
        "上下ドラッグで値を調整します。NAMノブはドラッグ中も音に反映し、指を離すと本体の値を確認します。他のエフェクトは指を離すと反映します。横に指を離すと微調整できます。数値タップで直接入力・標準値への復帰ができます。\n\nNAMのGAINはモデル前の入力ドライブ、BASS・MID・TREBLEはモデル後のEQ、MID FREQはMIDの中心周波数、VOLUMEはモデル後の出力レベルです。NAMがOFFまたはBYPASSの間は効きません。Bluetoothの再生音と通常のUSB再生音はNAMを通りません。\n\nモデル選択は試聴です。「保存」でモデルとパラメーターをプリセットに記録します。音声の接続順は固定です。",
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr("閉じる")),
      ),
    ],
  ),
);

/// Named choices of [parameter]; user IR entries are disabled for empty slots.
Future<int?> pickEffectChoice(
  BuildContext context, {
  required PedalModule module,
  required EffectParameter parameter,
  required int value,
  required List<IrSlotInfo>? irSlots,
}) => showModalBottomSheet<int>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .7,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              parameter.label,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final option in parameter.choices!.entries)
                  ListTile(
                    selected: option.key == value,
                    enabled:
                        !(module.command == 0x83 &&
                            option.key >= 11 &&
                            irSlots
                                    ?.where(
                                      (s) =>
                                          s.slot == option.key - 10 && s.used,
                                    )
                                    .isEmpty !=
                                false),
                    leading: Icon(
                      option.key == value
                          ? Icons.check_circle
                          : Icons.circle_outlined,
                    ),
                    title: Text(option.value),
                    subtitle: module.command == 0x83 && option.key >= 11
                        ? Text(tr("ユーザーIR {0}", [option.key - 10]))
                        : null,
                    onTap: () => Navigator.pop(context, option.key),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  ),
);
