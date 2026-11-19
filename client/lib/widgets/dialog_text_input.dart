import 'package:flutter/material.dart';

import 'app_dialog.dart';

Future<String?> showDialogTextInput(
  BuildContext context, {
  required String section,
  required String title,
  required String label,
  required String hint,
  String? help,
  String initial = '',
  String action = '保存',
  bool allowEmpty = false,
  int maxLines = 1,
  int? maxLength,
  TextInputType? keyboardType,
  String? Function(String)? validate,
}) {
  var value = initial;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (_, update) {
        final error = value.trim().isEmpty
            ? null
            : validate?.call(value.trim());
        final valid = (allowEmpty || value.trim().isNotEmpty) && error == null;
        return AppDialog(
          title: title,
          section: section,
          width: 440,
          child: TextFormField(
            initialValue: initial,
            autofocus: true,
            minLines: 1,
            maxLines: maxLines,
            maxLength: maxLength,
            keyboardType: keyboardType,
            decoration: InputDecoration(
              labelText: label,
              floatingLabelBehavior: FloatingLabelBehavior.always,
              hintText: hint,
              helperText: help,
              helperMaxLines: 4,
              errorText: error,
            ),
            onChanged: (s) => update(() => value = s),
            onFieldSubmitted: (s) {
              if ((allowEmpty || s.trim().isNotEmpty) &&
                  validate?.call(s.trim()) == null)
                Navigator.pop(ctx, s);
            },
          ),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: valid ? () => Navigator.pop(ctx, value) : null,
              child: Text(action),
            ),
          ],
        );
      },
    ),
  );
}

Future<String?> promptSteamUserId(BuildContext context) async {
  final value = await showDialogTextInput(
    context,
    section: '游戏启动　/　导入 Steam',
    title: '设置 Steam 用户 ID',
    label: 'Steam 好友代码',
    hint: '例如：12345678',
    help: '在 Steam 客户端的「好友 → 添加好友」中查看。',
    keyboardType: TextInputType.number,
  );
  return value?.trim();
}
