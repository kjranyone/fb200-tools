import 'localization.dart';

import 'dart:typed_data';

import 'pedal_client.dart' show PedalPreset;
import 'protocol.dart';

/// Preset words of the FX block (firmware docs/NAM_FX_BLOCK.md, capability
/// bit 14). An unset tail reads 0: no block.
abstract final class FxWords {
  static const mark = 0xea, mode = 0xec, flags = 0xee, params = 0xf0;
  static const marker = 0x5846; // "FX"
  static const on = 1, post = 2;
  static const paramCount = 8;
  static int param(int i) => params + i * 2;
}

enum FxUnit { none, percent, db18, ms, cents, choice }

/// One parameter as the pedal describes it (op 14).
class FxParam {
  final String name;
  final int min, max, def;
  final FxUnit unit;

  /// [FxUnit.choice]: one label per value from [min].
  final List<String> labels;
  const FxParam(
    this.name,
    this.min,
    this.max,
    this.def, [
    this.unit = FxUnit.none,
    this.labels = const [],
  ]);

  /// Semitone steps on a pitch knob: the intervals players ask for.
  int get step => unit == FxUnit.cents ? 100 : 1;

  String format(int v) => switch (unit) {
    FxUnit.percent => '$v%',
    FxUnit.db18 =>
      '${v >= 50 ? '+' : ''}${((v - 50) * .36).toStringAsFixed(1)} dB',
    FxUnit.ms => '$v ms',
    FxUnit.cents => tr("{0} 半音", [_semitones(v - 2400)]),
    FxUnit.choice =>
      v - min >= 0 && v - min < labels.length ? labels[v - min] : '$v',
    FxUnit.none => '$v',
  };

  static String _semitones(int cents) {
    final sign = cents > 0
        ? '+'
        : cents < 0
        ? '−'
        : '±';
    final c = cents.abs();
    return c % 100 == 0
        ? '$sign${c ~/ 100}'
        : '$sign${(c / 100).toStringAsFixed(2)}';
  }
}

/// A mode of the FX block (op 14 reply).
class FxMode {
  final int number;
  final String name;

  /// Takes the arena: exclusive with the second NAM, which wins.
  final bool heavy;
  final List<FxParam> params;
  const FxMode(this.number, this.name, this.params, {this.heavy = false});

  static const _record = 43;

  /// `[mode][heavy][name 16][count]` then count records of
  /// `{name 12, min, max, def i16 LE, unit u8, labels 24}`.
  factory FxMode.parse(Uint8List p) {
    String text(int off, int len) => String.fromCharCodes(
      p.sublist(off, off + len).takeWhile((v) => v != 0),
    );
    int i16(int off) => read16(p, off).toSigned(16);
    if (p.length < 19 || p[1] > 1) throw DeviceError(tr("不正なエフェクト情報です。"));
    final count = p[18];
    if (count > FxWords.paramCount || p.length != 19 + count * _record) {
      throw DeviceError(tr("不正なエフェクト情報です。"));
    }
    return FxMode(p[0], text(2, 16), [
      for (var k = 0; k < count; k++)
        () {
          final off = 19 + k * _record;
          final unit = p[off + 18];
          final labels = text(off + 19, 24);
          return FxParam(
            text(off, 12),
            i16(off + 12),
            i16(off + 14),
            i16(off + 16),
            unit < FxUnit.values.length ? FxUnit.values[unit] : FxUnit.none,
            labels.isEmpty ? const [] : labels.split('|'),
          );
        }(),
    ], heavy: p[1] == 1);
  }
}

/// The FX block as the edit buffer holds it.
class FxBlock {
  /// The marker is set: the words below are the preset's, not defaults.
  final bool configured;
  final int mode;
  final bool on, post;
  final List<int> values;
  const FxBlock(this.configured, this.mode, this.on, this.post, this.values);

  factory FxBlock.of(PedalPreset edit) {
    final configured = edit.word(FxWords.mark) == FxWords.marker;
    final flags = configured ? edit.word(FxWords.flags) : 0;
    return FxBlock(
      configured,
      configured ? edit.word(FxWords.mode) : 0,
      flags & FxWords.on != 0,
      flags & FxWords.post != 0,
      [
        for (var i = 0; i < FxWords.paramCount; i++)
          edit.word(FxWords.param(i)),
      ],
    );
  }

  /// [mode]'s parameter values: the stored ones for the stored mode, the
  /// defaults otherwise.
  List<int> valuesFor(FxMode mode) => [
    for (var i = 0; i < mode.params.length; i++)
      configured && this.mode == mode.number
          ? values[i].clamp(mode.params[i].min, mode.params[i].max)
          : mode.params[i].def,
  ];

  /// The words a change to [mode]'s block writes: only the changed word when
  /// the edit buffer already holds the block for [mode], every word
  /// otherwise (defaults for the rest).
  Map<int, int> change(FxMode mode, {bool? on, bool? post, (int, int)? param}) {
    final values = valuesFor(mode);
    if (param != null) values[param.$1] = param.$2;
    final newOn = on ?? this.on, newPost = post ?? this.post;
    if (!configured || this.mode != mode.number) {
      return words(mode, on: newOn, post: newPost, values: values);
    }
    return {
      if (on != null || post != null)
        FxWords.flags: (newOn ? FxWords.on : 0) | (newPost ? FxWords.post : 0),
      if (param != null) FxWords.param(param.$1): param.$2 & 0xffff,
    };
  }

  /// Every word of the block for [mode], [on] and [post], with [values]
  /// (the mode's defaults when null): one edit-buffer write.
  static Map<int, int> words(
    FxMode mode, {
    required bool on,
    required bool post,
    List<int>? values,
  }) => {
    FxWords.mode: mode.number,
    FxWords.flags: (on ? FxWords.on : 0) | (post ? FxWords.post : 0),
    for (var i = 0; i < FxWords.paramCount; i++)
      FxWords.param(i): i < mode.params.length
          ? (values?[i] ?? mode.params[i].def) & 0xffff
          : 0,
    FxWords.mark: FxWords.marker,
  };
}
