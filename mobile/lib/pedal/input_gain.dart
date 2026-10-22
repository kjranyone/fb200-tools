/// The pedal's global input gain (settings byte 2), a stock table
/// (firmware/audio/src/dsp/gain.c kInputGain): 0 mutes, 1..11 are -55..-5 dB
/// in 5 dB steps, 12 and 13 are both 0 dB, 14..25 add 0.5 dB each (+6 dB).
abstract final class InputGain {
  static const max = 25;

  /// Null for the muted step.
  static double? db(int index) {
    final i = index.clamp(0, max);
    if (i == 0) return null;
    if (i <= 11) return -60.0 + 5 * i;
    if (i <= 13) return 0;
    return (i - 13) * .5;
  }

  static String format(int index) {
    final value = db(index);
    if (value == null) return 'MUTE';
    final text = value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return '${value > 0 ? '+' : ''}$text dB';
  }
}
