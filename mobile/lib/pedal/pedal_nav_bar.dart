import '../localization.dart';

import 'package:flutter/material.dart';

import '../studio_theme.dart';

/// Controller sections, in tab order.
enum PedalTab { presets, effects, drums, tuner, looper, ir, settings }

class PedalNavBar extends StatelessWidget {
  final PedalTab tab;

  /// Null while tab changes are locked.
  final void Function(PedalTab tab)? onSelect;
  const PedalNavBar({super.key, required this.tab, required this.onSelect});

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Material(
      color: StudioTheme.background,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height < 480 ? 50 : 68,
        child: LayoutBuilder(
          builder: (context, box) {
            final labels = [
              tr("プリセット"),
              tr("エフェクト"),
              tr("ドラム"),
              tr("チューナー"),
              tr("ルーパー"),
              'IR',
              tr("設定"),
            ];
            const icons = [
              Icons.grid_view_outlined,
              Icons.route_outlined,
              Icons.music_note_outlined,
              Icons.straighten,
              Icons.loop,
              Icons.speaker_outlined,
              Icons.settings_outlined,
            ];
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final t in PedalTab.values)
                    Semantics(
                      selected: tab == t,
                      child: SizedBox(
                        width: (box.maxWidth / 7).clamp(48.0, 180.0),
                        child: InkWell(
                          onTap: onSelect == null ? null : () => onSelect!(t),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                icons[t.index],
                                size: 21,
                                color: tab == t
                                    ? StudioTheme.blue
                                    : const Color(0xff8390a1),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                labels[t.index],
                                style: TextStyle(
                                  fontSize: 10,
                                  color: tab == t
                                      ? StudioTheme.blue
                                      : const Color(0xff9daaba),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    ),
  );
}
