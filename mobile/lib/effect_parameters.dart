import 'localization.dart';

import 'dart:math' as math;

import 'pedal_client.dart';

/// Audible controls only. Source: src/fb200/params.py, DSP implementations,
/// and the manufacturer's FB200 manual (cab/model names). Wire words stay intact.
class EffectParameter {
  final int field;
  final String label;
  final int min, max;
  final Map<int, String>? choices;
  final String Function(int)? format;
  const EffectParameter(
    this.field,
    this.label, {
    this.min = 0,
    this.max = 100,
    this.choices,
    this.format,
  });
}

abstract final class EffectParameters {
  static const amps = {
    1: 'Ampog 2OD',
    2: 'Ampog B18 CL',
    3: 'Ampog SVT4',
    4: 'Ampog SVT VALVE',
    5: 'Mvrkbass 500',
    6: 'Mvrkbass 501',
    7: 'Akuila 750 CL',
    8: 'Akuila 750 DS',
    9: 'Akuila 751',
    10: 'BASSER CRUNCH',
  };
  static const cabs = {
    1: 'SV810 U47',
    2: 'SV810 121',
    3: 'SV810 7B',
    4: 'HK U47',
    5: 'HK 7B',
    6: 'HK 121',
    7: 'HK 421',
    8: 'Akuila U47',
    9: 'Akuila 7B',
    10: 'Akuila 121',
  };
  static const mods = {
    0: 'Phaser',
    1: 'Step Phaser',
    2: 'Flanger',
    3: 'Jet Flanger',
    4: 'Tremolo',
    5: 'Stutter Tremolo',
    6: 'Vibrato',
    7: 'Rotary',
    8: 'Analog Chorus',
    9: 'Multi Chorus',
    10: 'Ring Modulator',
    11: 'Filter',
  };
  static const reverbs = {
    0: 'Room',
    1: 'Hall',
    2: 'Plate',
    3: 'Spring',
    4: 'Modulated Reverb',
  };
  static const midFrequencies = {
    0: '200 Hz',
    1: '400 Hz',
    2: '800 Hz',
    3: '1.6 kHz',
    4: '3 kHz',
  };
  static String percent(int v) => '$v%';

  static String cabName(int type, List<IrSlotInfo>? slots) {
    if (cabs.containsKey(type)) return cabs[type]!;
    if (type >= 11 && type <= 19) {
      final slot = type - 10;
      final ir = slots?.where((s) => s.slot == slot).firstOrNull;
      return 'IR$slot · ${ir == null
          ? tr("読込待ち")
          : ir.used
          ? ir.name
          : tr("空き")}';
    }
    return type == 0 ? tr("未選択") : tr("未対応のキャビネット ({0})", [type]);
  }

  static double modRate(int type, int value) {
    final p = value / 100, a = value * .007;
    return switch (type) {
      0 => .1164 + 13.332 * a * a,
      1 => .681 + 13.7781 * p,
      2 => 3 * (.1002 + 1.9714 * a),
      3 => .1 + 4 * p * p,
      4 => (.2 + 17.143 * p) * .5 * 44100 / 32768,
      5 => (4.25 + 127.1 * p) / 8,
      6 =>
        7.7223 * math.pow(a, 4) +
            13.7215 * math.pow(a, 3) -
            16.2925 * a * a +
            7.8802 * a +
            .1,
      7 => (.681 + 38.5 * p) / 4,
      8 => .6 + 4 * p * p,
      9 => .6 + 5 * p,
      10 => (.0007423687423687 + .02333 * p) * 44100,
      _ => 9.3065 * p * p * p - 1.3809 * p * p + 1.4835 * p + .1164,
    };
  }

  /// [delayMax]: the longest delay the firmware plays (stored times above it
  /// play clamped); null for the stock format's 2500 ms.
  static List<EffectParameter> forModule(
    PedalModule m,
    PedalPreset preset, {
    List<IrSlotInfo>? irSlots,
    int? delayMax,
  }) {
    EffectParameter knob(int f, String label, {String Function(int)? format}) =>
        EffectParameter(f, label, format: format ?? percent);
    switch (m.command) {
      case 0x80:
        return [
          knob(2, tr("アタック")),
          knob(
            3,
            tr("スレッショルド"),
            format: (v) => '${(-60 + .6 * v).toStringAsFixed(1)} dB',
          ),
          knob(
            4,
            tr("レシオ"),
            format: (v) =>
                '${(1 + 9 * math.sqrt(v / 100)).toStringAsFixed(1)}:1',
          ),
          knob(5, tr("出力レベル")),
        ];
      case 0x81:
        return [knob(2, tr("スレッショルド"))];
      case 0x82:
        return [
          EffectParameter(1, tr("アンプモデル"), min: 1, max: 10, choices: amps),
          knob(2, tr("ゲイン")),
          knob(3, tr("ベース")),
          knob(4, tr("ミドル")),
          EffectParameter(5, tr("ミドル周波数"), max: 4, choices: midFrequencies),
          knob(6, tr("トレブル")),
          knob(7, tr("ボリューム")),
        ];
      case 0x83:
        return [
          EffectParameter(
            1,
            tr("キャビネット / IR"),
            min: 1,
            max: 19,
            choices: {for (var i = 1; i <= 19; i++) i: cabName(i, irSlots)},
          ),
        ];
      case 0x84:
        final type = preset.word(m.offset + 2);
        return [
          EffectParameter(1, tr("モジュレーション"), max: 11, choices: mods),
          knob(
            2,
            type == 10 ? tr("キャリア周波数") : tr("スピード"),
            format: (v) => '${modRate(type, v).toStringAsFixed(2)} Hz',
          ),
          knob(3, type == 6 ? tr("ピッチの深さ") : tr("ミックス")),
          knob(
            4,
            switch (type) {
              0 => tr("スイープ幅"),
              1 => tr("ステップ幅"),
              2 || 3 => tr("フィードバック"),
              11 => tr("帯域幅"),
              _ => tr("トーン"),
            },
            format: type == 11
                ? (v) => '${(10 + v * 1.9).toStringAsFixed(0)} Hz'
                : null,
          ),
          if (type == 8 || type == 9) knob(5, tr("コーラスの深さ")),
        ];
      case 0x85:
        // The current DSP uses one bass-delay algorithm; stored type changes
        // only load defaults. Do not offer a selector that cannot change sound.
        return [
          knob(2, tr("ミックス")),
          knob(3, tr("フィードバック")),
          EffectParameter(
            4,
            tr("ディレイタイム"),
            min: 40,
            max: delayMax ?? 2500,
            format: _milliseconds,
          ),
        ];
      case 0x86:
        return [
          EffectParameter(1, tr("リバーブ"), max: 4, choices: reverbs),
          knob(3, tr("残響レベル")),
          knob(4, tr("ディケイ")),
          knob(5, tr("トーン")),
        ];
      default:
        return [];
    }
  }

  static String _milliseconds(int value) => '$value ms';
}
