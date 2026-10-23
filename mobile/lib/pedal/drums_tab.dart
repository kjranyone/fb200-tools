import '../localization.dart';

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../protocol.dart' show read16;
import 'value_knob.dart';

typedef RhythmChange = Future<void> Function({
  bool? on,
  int? pattern,
  int? level,
  int? bpm,
});

class DrumsTab extends StatelessWidget {
  final Uint8List rhythm;
  final bool available, busy;
  final RhythmChange onRhythm;
  final VoidCallback onTapTempo;
  const DrumsTab({
    super.key,
    required this.rhythm,
    required this.available,
    required this.busy,
    required this.onRhythm,
    required this.onTapTempo,
  });

  @override
  Widget build(BuildContext context) {
    final r = rhythm;
    if (!available) {
      return Center(child: Text(tr("ドラムは本体の更新後に利用できます。")));
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ValueKnob(
              tr("パターン"),
              r[2] + 1,
              1,
              40,
              (v) => onRhythm(pattern: v - 1),
              enabled: !busy,
            ),
            ValueKnob(
              tr("テンポ"),
              read16(r, 4),
              40,
              260,
              (v) => onRhythm(bpm: v),
              enabled: !busy,
            ),
            ValueKnob(
              tr("音量"),
              r[3],
              0,
              100,
              (v) => onRhythm(level: v),
              enabled: !busy,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            FilledButton.tonal(
              onPressed: busy ? null : () => onRhythm(on: r[0] == 0),
              child: Text(r[0] != 0 ? tr("停止") : tr("再生")),
            ),
            OutlinedButton(
              onPressed: busy ? null : onTapTempo,
              child: Text(tr("タップテンポ")),
            ),
          ],
        ),
      ],
    );
  }
}
