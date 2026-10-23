import '../localization.dart';

import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'input_gain.dart';
import 'value_knob.dart';

class SettingsTab extends StatelessWidget {
  final Uint8List settings;
  final bool busy, cabinetAvailable, btAudioAvailable;
  final void Function(int index, int value) onSetting;
  final VoidCallback onBtName;
  const SettingsTab({
    super.key,
    required this.settings,
    required this.busy,
    required this.cabinetAvailable,
    required this.btAudioAvailable,
    required this.onSetting,
    required this.onBtName,
  });

  @override
  Widget build(BuildContext context) {
    final s = settings;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            Expanded(
              child: ValueKnob(
                tr("入力ゲイン"),
                s[2],
                0,
                InputGain.max,
                (v) => onSetting(2, v),
                enabled: !busy,
                format: InputGain.format,
              ),
            ),
            Expanded(
              child: ValueKnob(
                tr("LED色"),
                s[11],
                0,
                9,
                (v) => onSetting(11, v),
                enabled: !busy,
              ),
            ),
            Expanded(
              child: ValueKnob(
                tr("LED明るさ"),
                s[12],
                0,
                100,
                (v) => onSetting(12, v),
                enabled: !busy,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          dense: true,
          title: Text(tr("グローバル・キャビネット")),
          value: s[1] != 0,
          onChanged: busy || !cabinetAvailable
              ? null
              : (v) => onSetting(1, v ? 1 : 0),
        ),
        SwitchListTile(
          dense: true,
          title: Text(tr("Bluetoothオーディオ")),
          value: s[10] != 0,
          onChanged: busy || !btAudioAvailable
              ? null
              : (v) => onSetting(10, v ? 1 : 0),
        ),
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(tr("Bluetooth名の変更")),
          subtitle: Text(tr("半角英数字・記号で1〜20文字。変更は再接続後に本体側で確認してください。")),
          trailing: const Icon(Icons.chevron_right),
          onTap: busy ? null : onBtName,
        ),
      ],
    );
  }
}
