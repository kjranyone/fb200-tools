import 'package:fb200_nam/effect_parameters.dart';
import 'package:fb200_nam/pedal_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final preset = PedalPreset(List.filled(256, 0));
  test(
    'only audible fields are exposed; type selectors use documented names',
    () {
      expect(
        EffectParameters.forModule(pedalModules[3], preset).map((p) => p.field),
        [1],
      );
      expect(
        EffectParameters.forModule(pedalModules[6], preset).map((p) => p.field),
        [1, 3, 4, 5],
      );
      expect(
        EffectParameters.forModule(pedalModules[5], preset).map((p) => p.field),
        [2, 3, 4],
      );
      expect(
        EffectParameters.forModule(pedalModules[2], preset)[4].choices![4],
        '3 kHz',
      );
      expect(EffectParameters.mods[8], 'Analog Chorus');
      expect(EffectParameters.cabs[7], 'HK 421');
    },
  );
  test('modulation controls follow the selected DSP algorithm', () {
    for (var type = 0; type < 12; type++) {
      final controls = EffectParameters.forModule(
        pedalModules[4],
        preset.setWord(0x76, type),
      );
      expect(controls.any((p) => p.field == 5), type == 8 || type == 9);
      expect(controls.any((p) => p.field == 6), isFalse);
      expect(controls[2].label, type == 6 ? 'ピッチの深さ' : 'ミックス');
    }
    final filter = EffectParameters.forModule(
      pedalModules[4],
      preset.setWord(0x76, 11),
    );
    expect(filter.last.label, '帯域幅');
    expect(filter.last.format!(50), '105 Hz');
    expect(EffectParameters.modRate(10, 0), closeTo(32.739, .01));
  });
  test('cabinet wire types map to the exact user IR slot and read name', () {
    const slots = [
      IrSlotInfo(1, true, 'EBS PL410'),
      IrSlotInfo(9, true, 'V30 Bass'),
      IrSlotInfo(4, false, ''),
    ];
    expect(EffectParameters.cabName(11, slots), 'IR1 · EBS PL410');
    expect(EffectParameters.cabName(19, slots), 'IR9 · V30 Bass');
    expect(EffectParameters.cabName(14, slots), 'IR4 · 空き');
  });
}
