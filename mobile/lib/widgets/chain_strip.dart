import 'package:flutter/material.dart';

import '../studio_theme.dart';

/// The edit buffer's module order. Selection is a position in [order].
class ChainStrip extends StatelessWidget {
  final List<int> order;
  final Set<int> enabled;
  final Set<int> unavailable;
  final int? selected;
  final ValueChanged<int> onTap;
  final bool restrictedNam;
  final String? namModel;
  final bool compact;

  const ChainStrip({
    super.key,
    required this.order,
    required this.enabled,
    required this.onTap,
    required this.restrictedNam,
    this.selected,
    this.namModel,
    this.unavailable = const {},
    this.compact = false,
  });

  /// 7: the FX block of NAM firmware (capability bit 14), not a stock module.
  static const names = [
    'COMP',
    'GATE',
    'AMP',
    'CAB',
    'MOD',
    'DLY',
    'REV',
    'FX',
  ];
  static const icons = [
    Icons.compress,
    Icons.graphic_eq,
    Icons.memory,
    Icons.speaker,
    Icons.waves,
    Icons.timer_outlined,
    Icons.blur_on,
    Icons.auto_fix_high,
  ];

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (compact) {
        final minimum = 40 + MediaQuery.textScalerOf(context).scale(11) * 4;
        final columns = (box.maxWidth / minimum).floor().clamp(1, order.length);
        final width = (box.maxWidth - (columns - 1) * 6) / columns;
        return Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var position = 0; position < order.length; position++)
              _compactBlock(position, width),
          ],
        );
      }
      final width = box.maxWidth >= 680
          ? (box.maxWidth - (order.length - 1) * 16) / order.length
          : 88.0;
      return SizedBox(
        height: 96,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: order.length,
          separatorBuilder: (_, _) => const SizedBox(
            width: 16,
            child: Center(
              child: Icon(
                Icons.arrow_right_alt,
                size: 16,
                color: StudioTheme.line,
              ),
            ),
          ),
          itemBuilder: (context, position) {
            final module = order[position];
            final isNam = restrictedNam && module == 2;
            final available = !unavailable.contains(module);
            final active = available && enabled.contains(module);
            final accent = StudioTheme.moduleColors[module];
            final chosen = selected == position;
            final label = isNam ? 'NAM' : names[module];
            final status = !available
                ? 'N/A'
                : active
                ? 'ON'
                : 'OFF';
            return Semantics(
              button: true,
              selected: chosen,
              label: '$label, $status',
              child: Material(
                key: ValueKey(module),
                color: chosen
                    ? accent.withValues(alpha: .09)
                    : StudioTheme.background,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(
                    color: chosen
                        ? accent
                        : active
                        ? accent.withValues(alpha: .5)
                        : StudioTheme.line,
                    width: chosen ? 1.5 : 1,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => onTap(position),
                  child: SizedBox(
                    width: width,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 10,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            icons[module],
                            size: 23,
                            color: active || chosen
                                ? accent
                                : const Color(0xff7e8999),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            label,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1,
                            ),
                          ),
                          if (isNam)
                            Text(
                              namModel ?? 'A2 LITE',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 9,
                                color: Color(0xffa6b0bd),
                              ),
                            ),
                          const Spacer(),
                          Text(
                            status,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: active ? accent : const Color(0xff7e8999),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
    },
  );

  Widget _compactBlock(int position, double width) {
    final module = order[position];
    final isNam = restrictedNam && module == 2;
    final label = isNam ? 'NAM' : names[module];
    final chosen = position == selected;
    final available = !unavailable.contains(module);
    final active = available && enabled.contains(module);
    final status = !available
        ? 'N/A'
        : active
        ? 'ON'
        : 'OFF';
    final accent = StudioTheme.moduleColors[module];
    return Semantics(
      button: true,
      selected: chosen,
      label: '$label, $status',
      child: Material(
        key: ValueKey(module),
        color: chosen ? accent.withValues(alpha: .12) : StudioTheme.background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: chosen ? accent : StudioTheme.line,
            width: chosen ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onTap(position),
          child: SizedBox(
            width: width,
            height: 52,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        icons[module],
                        size: 14,
                        color: chosen || active
                            ? accent
                            : const Color(0xff8390a1),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: chosen ? accent : null,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    isNam ? namModel ?? 'A2 LITE' : status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9,
                      color: active ? accent : const Color(0xff8390a1),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
