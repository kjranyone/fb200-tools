import 'package:flutter/material.dart';

/// Discrete algorithms and cabinet slots are named choices, not rotary values.
class EffectChoice extends StatelessWidget {
  final String label, value;
  final bool enabled;
  final VoidCallback onPressed;
  const EffectChoice({
    super.key,
    required this.label,
    required this.value,
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: OutlinedButton(
        onPressed: enabled ? onPressed : null,
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.all(8)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
            const SizedBox(height: 6),
            Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13),
            ),
            const Icon(Icons.unfold_more, size: 18),
          ],
        ),
      ),
    ),
  );
}
