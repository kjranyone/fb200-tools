import '../localization.dart';

import 'package:flutter/material.dart';

/// Cancel / accept dialog. Dismissing it counts as cancel.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required Widget content,
  required String accept,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: content,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr("キャンセル")),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(accept),
          ),
        ],
      ),
    ) ??
    false;

/// Single-line text entry; null when cancelled.
Future<String?> askText(
  BuildContext context, {
  required String title,
  required String initial,
  required int maxLength,
  required String helper,
  required String accept,
}) async {
  final controller = TextEditingController(text: initial);
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        maxLength: maxLength,
        decoration: InputDecoration(helperText: helper),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr("キャンセル")),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: Text(accept),
        ),
      ],
    ),
  );
  // The dialog route is still animating out when its Future completes.
  Future<void>.delayed(const Duration(milliseconds: 500), controller.dispose);
  return value;
}
