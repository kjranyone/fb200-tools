import '../localization.dart';

import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'value_knob.dart';

typedef TunerChange = Future<void> Function({bool? on, bool? mute, int? a4});

class TunerTab extends StatelessWidget {
  final Uint8List settings;
  final bool available, busy;

  /// NAM firmware streams the detected pitch; stock firmware shows it only on
  /// the pedal display.
  final bool showsPitch;
  final String pitch;
  final TunerChange onTuner;
  const TunerTab({
    super.key,
    required this.settings,
    required this.available,
    required this.busy,
    required this.showsPitch,
    required this.pitch,
    required this.onTuner,
  });

  @override
  Widget build(BuildContext context) {
    final s = settings;
    if (!available) {
      return Center(child: Text(tr("チューナーは本体の更新後に利用できます。")));
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showsPitch)
          Text(
            pitch,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.displayMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: Theme.of(context).colorScheme.primary,
            ),
          )
        else
          Text(
            tr("音程は本体のディスプレイで確認できます。"),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: s[8] != 0,
                  onChanged: busy ? null : (v) => onTuner(on: v),
                ),
                Text(tr("チューナー")),
              ],
            ),
            ValueKnob(
              tr("基準 A4"),
              435 + s[7],
              435,
              450,
              (v) => onTuner(a4: v),
              enabled: !busy,
            ),
          ],
        ),
        SwitchListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 48),
          title: Text(tr("チューニング中はミュート")),
          value: s[9] != 0,
          onChanged: busy ? null : (v) => onTuner(mute: v),
        ),
      ],
    );
  }
}
