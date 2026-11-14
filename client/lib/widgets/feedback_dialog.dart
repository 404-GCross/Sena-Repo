import 'package:flutter/material.dart';

Future<void> showFeedbackDialog(
  BuildContext context,
  String message, {
  String? title,
  bool error = false,
}) async {
  if (!context.mounted) return;
  final text = message.replaceFirst(RegExp(r'^(Exception|AuthException):\s*'), '');
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title ?? (error ? '操作失败' : '提示')),
      scrollable: true,
      content: SelectableText(text),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('确定'),
        ),
      ],
    ),
  );
}
