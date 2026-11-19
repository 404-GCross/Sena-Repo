import 'package:flutter/material.dart';

import '../utils/theme_utils.dart';
import 'app_dialog.dart';

enum PatchConfigurationMode { smart, manual }

class PatchIdentityHeader extends StatelessWidget {
  const PatchIdentityHeader({
    super.key,
    required this.game,
    required this.appId,
    required this.filename,
  });
  final String game, appId, filename;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.outlineVariant),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(
            Icons.description_outlined,
            size: 22,
            color: cs.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      game,
                      style: AppText.body.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      'AppID $appId',
                      style: AppText.label.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
                Text(
                  filename,
                  style: AppText.bodySmall.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class PatchConfigurationDialog extends StatelessWidget {
  final String game, appId, filename;
  final Future<String?> unavailableReason;
  final bool remote;
  const PatchConfigurationDialog({
    super.key,
    required this.game,
    required this.appId,
    required this.filename,
    required this.unavailableReason,
    this.remote = false,
  });

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      section: 'Steam 补丁　/　注入规则',
      title: '选择配置方式',
      width: 528,
      footnote: '仅保存规则，不会安装补丁',
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PatchIdentityHeader(game: game, appId: appId, filename: filename),
          const SizedBox(height: 14),
          FutureBuilder<String?>(
            future: unavailableReason,
            builder: (_, state) {
              final checking = state.connectionState != ConnectionState.done;
              final reason = checking
                  ? '正在检查本地游戏目录及智能体设置。'
                  : state.hasError
                  ? '无法检查智能配置条件，仍可手动配置。'
                  : state.data;
              return DialogActionCard(
                title: '智能配置',
                icon: Icons.auto_awesome_outlined,
                highlight: true,
                badge: reason == null
                    ? null
                    : checking
                    ? '检查中'
                    : '不可用',
                description:
                    reason ??
                    (remote
                        ? '下载或复用网盘补丁，按包内与游戏相对路径分析规则。'
                        : '服务端读取本地补丁，客户端仅提供游戏相对路径。'),
                onTap: reason == null
                    ? () => Navigator.pop(context, PatchConfigurationMode.smart)
                    : null,
              );
            },
          ),
          const SizedBox(height: 8),
          DialogActionCard(
            title: '手动配置',
            icon: Icons.tune_rounded,
            description: '指定补丁源目录与游戏内的目标目录。',
            onTap: () => Navigator.pop(context, PatchConfigurationMode.manual),
          ),
        ],
      ),
    );
  }
}
