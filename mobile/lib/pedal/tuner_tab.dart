import '../localization.dart';

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../studio_theme.dart';
import 'value_knob.dart';

typedef TunerChange = Future<void> Function({bool? on, bool? mute, int? a4});

/// One valid NAM RPC op 8 snapshot.
class TunerReading {
  /// Firmware note numbers 1..12 run A♯ .. A.
  static const notes = [
    '—',
    'A♯',
    'B',
    'C',
    'C♯',
    'D',
    'D♯',
    'E',
    'F',
    'F♯',
    'G',
    'G♯',
    'A',
  ];
  final int note, octave;
  final double frequency, cents;
  const TunerReading(this.note, this.octave, this.frequency, this.cents);

  /// Null while the tuner is off, silent or unsure.
  static TunerReading? parse(Uint8List p) {
    if (p.length != 16) return null;
    final bytes = ByteData.sublistView(p);
    final frequency = bytes.getFloat32(4, Endian.little);
    final cents = bytes.getFloat32(8, Endian.little);
    if (p[0] == 0 ||
        p[1] == 0 ||
        p[2] < 1 ||
        p[2] > 12 ||
        !frequency.isFinite ||
        !cents.isFinite) {
      return null;
    }
    return TunerReading(p[2], bytes.getInt8(3), frequency, cents);
  }

  String get name => notes[note];

  @override
  bool operator ==(Object other) =>
      other is TunerReading &&
      other.note == note &&
      other.octave == octave &&
      other.frequency == frequency &&
      other.cents == cents;

  @override
  int get hashCode => Object.hash(note, octave, frequency, cents);

  /// Halves the jitter of a held note; a new note shows at once.
  TunerReading smoothed(TunerReading? previous) =>
      previous == null || previous.note != note || previous.octave != octave
      ? this
      : TunerReading(
          note,
          octave,
          frequency,
          previous.cents + (cents - previous.cents) * .5,
        );

  String get text =>
      '$name  ${frequency.toStringAsFixed(1)} Hz  ${cents >= 0 ? '+' : ''}${cents.toStringAsFixed(1)} cent';
}

class TunerTab extends StatelessWidget {
  final Uint8List settings;
  final bool available, busy;

  /// NAM firmware streams the detected pitch; stock firmware shows it only on
  /// the pedal display.
  final bool showsPitch;
  final TunerReading? reading;
  final TunerChange onTuner;
  const TunerTab({
    super.key,
    required this.settings,
    required this.available,
    required this.busy,
    required this.showsPitch,
    required this.reading,
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
        if (showsPitch) ...[
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: TunerIndicator(reading: s[8] != 0 ? reading : null),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            reading?.text ?? '—',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ] else
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

/// Note name over a ±50 cent scale with a needle, like a pedal tuner.
class TunerIndicator extends StatelessWidget {
  /// Null hides the needle.
  final TunerReading? reading;
  const TunerIndicator({super.key, required this.reading});

  /// Within ±3 cents counts as in tune.
  static Color colorFor(double cents) {
    final c = cents.abs();
    if (c <= 3) return StudioTheme.ready;
    if (c <= 15) return const Color(0xffe4bd69);
    return const Color(0xffff7a5a);
  }

  @override
  Widget build(BuildContext context) {
    final r = reading;
    final color = r == null ? const Color(0xff8390a1) : colorFor(r.cents);
    return Semantics(
      label: tr("チューナー"),
      value: r == null
          ? tr("音を検出していません")
          : '${r.name}${r.octave} ${r.cents >= 0 ? '+' : ''}${r.cents.toStringAsFixed(0)} cent',
      child: ExcludeSemantics(
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  r == null ? '—' : r.name,
                  style: TextStyle(
                    fontSize: 64,
                    height: 1,
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
                if (r != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 6),
                    child: Text(
                      '${r.octave}',
                      style: TextStyle(fontSize: 22, color: color),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('♭', style: TextStyle(fontSize: 18)),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: CustomPaint(painter: _ScalePainter(r?.cents, color)),
                  ),
                ),
                const SizedBox(width: 8),
                const Text('♯', style: TextStyle(fontSize: 18)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ScalePainter extends CustomPainter {
  final double? cents;
  final Color color;
  _ScalePainter(this.cents, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    double x(double c) => size.width * (c.clamp(-50, 50) + 50) / 100;
    final mid = size.height / 2;
    final tick = Paint()
      ..color = const Color(0xff8390a1)
      ..strokeWidth = 1;
    for (var c = -50; c <= 50; c += 10) {
      final h = c == 0 ? mid : (c % 50 == 0 ? mid * .7 : mid * .4);
      canvas.drawLine(
        Offset(x(c.toDouble()), mid - h),
        Offset(x(c.toDouble()), mid + h),
        tick,
      );
    }
    // In-tune window.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(x(-3), mid - 4, x(3), mid + 4),
        const Radius.circular(2),
      ),
      Paint()..color = StudioTheme.ready.withValues(alpha: .35),
    );
    final c = cents;
    if (c == null) return;
    final at = x(c);
    canvas.drawLine(
      Offset(at, 0),
      Offset(at, size.height),
      Paint()
        ..color = color
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(Offset(at, mid), 6, Paint()..color = color);
    // Offscreen notes pin to the scale end; show which way to tune.
    if (c.abs() > 50) {
      canvas.drawCircle(
        Offset(at, mid),
        10,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_ScalePainter old) =>
      old.cents != cents || old.color != color;
}
