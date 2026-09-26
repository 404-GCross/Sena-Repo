import "package:flutter/material.dart";

import "../services/api_client.dart";
import "../utils/theme_utils.dart";
import "app_shell.dart";

/// Ask the user for their Sena Repo username when registering through NextMoe.
///
/// Returns the `/api/auth/oauth/register` response, or null when cancelled.
Future<Map<String, dynamic>?> showNextmoeUsernameDialog(
  BuildContext context, {
  required ApiClient api,
  required String requestId,
  String nextmoeName = "",
  String suggestedUsername = "",
}) {
  return showDialog<Map<String, dynamic>>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _NextmoeUsernameDialog(
      api: api,
      requestId: requestId,
      nextmoeName: nextmoeName,
      suggestedUsername: suggestedUsername,
    ),
  );
}

class _NextmoeUsernameDialog extends StatefulWidget {
  final ApiClient api;
  final String requestId;
  final String nextmoeName;
  final String suggestedUsername;

  const _NextmoeUsernameDialog({
    required this.api,
    required this.requestId,
    required this.nextmoeName,
    required this.suggestedUsername,
  });

  @override
  State<_NextmoeUsernameDialog> createState() =>
      _NextmoeUsernameDialogState();
}

class _NextmoeUsernameDialogState extends State<_NextmoeUsernameDialog> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final username = _controller.text.trim();
    if (username.length < 2) {
      setState(() => _error = "用户名至少需要 2 个字符");
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.api.oauthRegister(
        requestId: widget.requestId,
        username: username,
      );
      if (mounted) Navigator.pop(context, result);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.nextmoeName.trim();
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      title: const Text("设置用户名"),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "首次通过 鲲Galgame账号 登录需要在本服务器注册，请设置一个用户名。",
              style: AppText.bodySmall.copyWith(
                color: subTextColor(context),
                height: 1.5,
              ),
            ),
            if (name.isNotEmpty) ...[
              const SizedBox(height: AppGap.sm),
              Text(
                "你的 鲲Galgame 昵称：$name",
                style: AppText.label.copyWith(color: hintColor(context)),
              ),
            ],
            const SizedBox(height: AppGap.md),
            TextField(
              controller: _controller,
              autofocus: true,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: "用户名",
                helperText: widget.suggestedUsername.isEmpty
                    ? "2-128 个字符，注册后可在个人信息里修改"
                    : "2-128 个字符；可用：${widget.suggestedUsername}",
                errorText: _error,
              ),
              onSubmitted: (_) => _busy ? null : _submit(),
            ),
            const SizedBox(height: AppGap.sm),
            Text(
              "提交后需要管理员审批通过才能登录。",
              style: AppText.caption.copyWith(color: hintColor(context)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text("取消"),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text("提交注册"),
        ),
      ],
    );
  }
}
