import 'package:flutter/material.dart';

/// The signal chain as a horizontal strip of module blocks, in the edit
/// buffer's own order (preset bytes 0xBC..0xC2): tap a block to select it
/// for editing. Under NAM firmware the amp block shows the running model
/// instead of the stock amp. `enabled` holds the module indexes whose block
/// is switched on in the edit buffer.
class ChainStrip extends StatelessWidget {
  final List<int> order; // module indexes 0..6 in chain order
  final Set<int> enabled;
  final int? selected;
  final ValueChanged<int> onTap;
  final bool restrictedNam;
  final String? namModel;

  const ChainStrip({
    super.key,
    required this.order,
    required this.enabled,
    required this.onTap,
    required this.restrictedNam,
    this.selected,
    this.namModel,
  });

  static const names = ['COMP', 'GATE', 'AMP', 'CAB', 'MOD', 'DLY', 'REV'];
  static const icons = [
    Icons.compress,
    Icons.graphic_eq,
    Icons.album,
    Icons.speaker,
    Icons.waves,
    Icons.timer,
    Icons.blur_on,
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 92,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: order.length,
        separatorBuilder: (_, _) => _chevron(scheme),
        itemBuilder: (context, i) {
          final module = order[i];
          final isNAM = restrictedNam && module == 2;
          return _Block(
            key: ValueKey(module),
            label: isNAM ? 'NAM' : names[module],
            sub: isNAM ? namModel : null,
            icon: icons[module],
            on: enabled.contains(module),
            selected: selected == i,
            accent: scheme.primary,
            onTap: () => onTap(i),
          );
        },
      ),
    );
  }

  Widget _chevron(ColorScheme scheme) => Center(
    child: Icon(
      Icons.chevron_right,
      size: 16,
      color: scheme.outlineVariant.withValues(alpha: 0.6),
    ),
  );
}

class _Block extends StatelessWidget {
  final String label;
  final String? sub;
  final IconData icon;
  final bool on;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  const _Block({
    super.key,
    required this.label,
    required this.icon,
    required this.on,
    required this.selected,
    required this.accent,
    required this.onTap,
    this.sub,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 76,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.12)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? accent
                : scheme.outlineVariant.withValues(alpha: 0.4),
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 22, color: on ? accent : scheme.outline),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: on ? scheme.onSurface : scheme.outline,
              ),
            ),
            if (sub != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  sub!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 9, color: scheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
