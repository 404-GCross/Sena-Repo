import 'package:flutter/material.dart';
import 'app_dialog.dart';

Future<void> showFeedbackDialog(
  BuildContext context,
  String message, {
  String? title,
  bool error = false,
  String? details,
  IconData? icon,
}) async {
  if (!context.mounted) return;
  final text = message.replaceFirst(
    RegExp(r'^(Exception|AuthException):\s*'),
    '',
  );
  final cs = Theme.of(context).colorScheme;
  final split = text.indexOf('\n');
  final separate =
      error &&
      details == null &&
      split > 0 &&
      split < text.trimRight().length - 1;
  final summary = separate ? text.substring(0, split) : text;
  final extra = details ?? (separate ? text.substring(split + 1).trim() : null);
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AppDialog(
      section: '操作结果',
      width: 426,
      tone: error ? cs.error : cs.primary,
      title: title ?? (error ? '操作失败' : '提示'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                icon ?? (error ? Icons.error_outline : Icons.info_outline),
                color: error ? cs.error : cs.primary,
              ),
              const SizedBox(width: 12),
              Expanded(child: SelectableText(summary)),
            ],
          ),
          if (extra != null && extra.isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('查看详情'),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(extra),
                ),
              ],
            ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

Future<void> showPermissionFeedback(BuildContext context, String action) =>
    showFeedbackDialog(
      context,
      '$action仅限管理员使用。请切换到管理员账号，或联系管理员操作。',
      title: '需要管理员权限',
      icon: Icons.lock_outline,
    );
