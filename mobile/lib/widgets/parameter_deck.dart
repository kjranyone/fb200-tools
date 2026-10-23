import '../localization.dart';

import 'package:flutter/material.dart';

/// A bounded control surface. Short screens use explicit parameter pages;
/// the playing surface never moves vertically while adjusting a control.
class ParameterDeck extends StatefulWidget {
  final int count;
  final Widget Function(int index, double dialSize) itemBuilder;
  const ParameterDeck({
    super.key,
    required this.count,
    required this.itemBuilder,
  });

  @override
  State<ParameterDeck> createState() => _ParameterDeckState();
}

class _ParameterDeckState extends State<ParameterDeck> {
  int _page = 0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final columns =
          (box.maxWidth >= 560
                  ? (box.maxWidth >= 8 * 76 ? 8 : 7)
                  : box.maxWidth >= 400
                  ? 4
                  : box.maxWidth >= 260
                  ? 3
                  : 2)
              .clamp(1, widget.count);
      final allRows = (widget.count / columns).ceil();
      final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final minimum = 56 + 64 * textScale;
      final fits = allRows * minimum + (allRows - 1) * 8 <= box.maxHeight;
      final rows = fits
          ? allRows
          : ((box.maxHeight - 44) / (minimum + 8)).floor().clamp(1, allRows);
      final perPage = rows * columns;
      final pages = (widget.count / perPage).ceil();
      final page = _page.clamp(0, pages - 1);
      final height =
          (box.maxHeight - (pages > 1 ? 44 : 0) - (rows - 1) * 8) / rows;
      final cellWidth = (box.maxWidth - (columns - 1) * 8) / columns;
      final dial = (height - 64 * textScale).clamp(
        40.0,
        cellWidth.clamp(40.0, 86.0),
      );
      return Column(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var row = 0; row < rows; row++) ...[
                  if (row != 0) const SizedBox(height: 8),
                  SizedBox(
                    height: height,
                    child: Row(
                      children: [
                        for (var col = 0; col < columns; col++) ...[
                          if (col != 0) const SizedBox(width: 8),
                          Expanded(
                            child:
                                page * perPage + row * columns + col <
                                    widget.count
                                ? Center(
                                    child: widget.itemBuilder(
                                      page * perPage + row * columns + col,
                                      dial,
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (pages > 1)
            SizedBox(
              height: 44,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: tr("前のパラメーター"),
                    onPressed: page == 0
                        ? null
                        : () => setState(() => _page = page - 1),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text(
                    tr("パラメーター {0} / {1}", [page + 1, pages]),
                    style: const TextStyle(fontSize: 12),
                  ),
                  IconButton(
                    tooltip: tr("次のパラメーター"),
                    onPressed: page == pages - 1
                        ? null
                        : () => setState(() => _page = page + 1),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ),
        ],
      );
    },
  );
}
