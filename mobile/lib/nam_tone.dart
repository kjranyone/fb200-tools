import 'dart:math' as math;

/// Display units mirror firmware/audio/src/dsp/nam_tone.c. Wire values stay
/// in the original preset words (0..100); no model weights are modified.
abstract final class NamTone {
  static const labels = {
    2: 'GAIN',
    3: 'BASS',
    4: 'MID',
    5: 'MID FREQ',
    6: 'TREBLE',
    7: 'VOLUME',
  };
  static String format(int field, int value) => switch (field) {
    2 => '${math.pow(2, (value - 50) * .02).toStringAsFixed(2)}×',
    3 || 4 || 6 =>
      '${value >= 50 ? '+' : ''}${((value - 50) * .24).toStringAsFixed(1)} dB',
    5 => '${(200 * math.pow(10, value / 100)).round()} Hz',
    7 => '${(value * .02).toStringAsFixed(2)}×',
    _ => '$value',
  };
}
