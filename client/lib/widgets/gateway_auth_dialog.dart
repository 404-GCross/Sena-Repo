import "package:flutter/material.dart";

import "../services/gateway_auth_service.dart";

Future<bool> showGatewayAuthDialog(
  BuildContext context,
  GatewayAuthChallenge challenge,
) async {
  final retry = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text("需要认证"),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("该服务端受 fn-knock 保护，请认证后尝试重新登录。"),
            const SizedBox(height: 8),
            Text(
              challenge.serverUri.toString(),
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text("取消"),
        ),
        FilledButton.tonal(
          onPressed: () async {
            final opened = await GatewayAuthService.openAuthPage(challenge);
            if (!opened && ctx.mounted) {
              await showDialog<void>(
                context: ctx,
                builder: (errCtx) => AlertDialog(
                  title: const Text("无法打开浏览器"),
                  content: Text("请手动打开认证地址：\n${challenge.authUri}"),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(errCtx),
                      child: const Text("确定"),
                    ),
                  ],
                ),
              );
            }
          },
          child: const Text("跳转浏览器认证"),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text("重试登录"),
        ),
      ],
    ),
  );
  return retry == true;
}
