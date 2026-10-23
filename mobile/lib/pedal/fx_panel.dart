import '../localization.dart';

import 'package:flutter/material.dart';

import '../fx_block.dart';
import '../studio_theme.dart';
import '../widgets/effect_choice.dart';
import '../widgets/knob.dart';
import '../widgets/parameter_deck.dart';

/// The FX block's editor: mode, position and the controls the pedal
/// describes for the mode (op 14). Every change goes out as the edit-buffer
/// words [FxBlock.change] picks.
class FxPanel extends StatelessWidget {
  /// Null while the pedal is asked for them.
  final List<FxMode>? modes;
  final FxBlock block;
  final bool busy;
  final Color accent;

  /// Keeps knobs apart across presets.
  final int editIndex;
  final ValueChanged<Map<int, int>> onWords;
  const FxPanel({
    super.key,
    required this.modes,
    required this.block,
    required this.busy,
    required this.accent,
    required this.editIndex,
    required this.onWords,
  });

  /// The edit buffer's mode, or the first one for an unset block.
  static FxMode? current(List<FxMode>? modes, FxBlock block) {
    if (modes == null || modes.isEmpty) return null;
    return modes.where((m) => m.number == block.mode).firstOrNull ??
        modes.first;
  }

  @override
  Widget build(BuildContext context) {
    final modes = this.modes;
    if (modes == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final mode = current(modes, block);
    if (mode == null) {
      return Center(child: Text(tr("本体にエフェクトがありません。")));
    }
    final values = block.valuesFor(mode);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (modes.length > 1)
              DropdownButton<int>(
                key: const ValueKey('fx-mode'),
                value: mode.number,
                onChanged: busy
                    ? null
                    : (n) {
                        if (n == null || n == mode.number) return;
                        final next = modes.firstWhere((m) => m.number == n);
                        onWords(
                          FxBlock.words(next, on: block.on, post: block.post),
                        );
                      },
                items: [
                  for (final m in modes)
                    DropdownMenuItem(value: m.number, child: Text(m.name)),
                ],
              )
            else
              Text(
                mode.name,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: .8,
                  color: accent,
                ),
              ),
            SegmentedButton<bool>(
              key: const ValueKey('fx-position'),
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: false, label: Text(tr("NAMの前"))),
                ButtonSegment(value: true, label: Text(tr("キャビの後"))),
              ],
              selected: {block.post},
              onSelectionChanged: busy
                  ? null
                  : (s) => onWords(block.change(mode, post: s.first)),
            ),
          ],
        ),
        if (mode.heavy)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              tr("プリ段のNAMと同時には使えません。"),
              style: const TextStyle(fontSize: 11, color: Color(0xffa6b0bd)),
            ),
          ),
        const SizedBox(height: 6),
        Expanded(
          child: ParameterDeck(
            key: ValueKey('fx-parameters-${mode.number}'),
            count: mode.params.length,
            itemBuilder: (i, size) {
              final p = mode.params[i];
              if (p.unit == FxUnit.choice) {
                return EffectChoice(
                  label: p.name,
                  value: p.format(values[i]),
                  enabled: !busy,
                  onPressed: () async {
                    final v = await _pick(context, p, values[i]);
                    if (v != null && v != values[i]) {
                      onWords(block.change(mode, param: (i, v)));
                    }
                  },
                );
              }
              return Knob(
                key: ValueKey('preset-$editIndex-fx-${mode.number}-$i'),
                label: p.name,
                value: values[i],
                min: p.min,
                max: p.max,
                step: p.step,
                defaultValue: p.def,
                size: size,
                accent: accent,
                format: p.format,
                enabled: !busy,
                onChanged: (v) => onWords(block.change(mode, param: (i, v))),
              );
            },
          ),
        ),
      ],
    );
  }

  static Future<int?> _pick(BuildContext context, FxParam p, int value) =>
      showDialog<int>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(p.name),
          children: [
            for (var v = p.min; v <= p.max; v++)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, v),
                child: Row(
                  children: [
                    Icon(
                      v == value ? Icons.check : null,
                      size: 18,
                      color: StudioTheme.nam,
                    ),
                    const SizedBox(width: 10),
                    Text(p.format(v)),
                  ],
                ),
              ),
          ],
        ),
      );
}
