import 'package:flutter/material.dart';

import '../widgets/knob.dart';

/// Knob for a device setting; the value is clamped into range for display.
class ValueKnob extends StatelessWidget {
  final String label;
  final int value, min, max;
  final bool enabled;
  final String Function(int)? format;
  final void Function(int) onChanged;
  const ValueKnob(
    this.label,
    this.value,
    this.min,
    this.max,
    this.onChanged, {
    super.key,
    required this.enabled,
    this.format,
  });

  @override
  Widget build(BuildContext context) => Knob(
    label: label,
    value: value.clamp(min, max),
    min: min,
    max: max,
    enabled: enabled,
    format: format,
    onChanged: onChanged,
  );
}
