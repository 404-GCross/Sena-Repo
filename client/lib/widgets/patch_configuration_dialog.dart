import 'package:flutter/material.dart';

enum PatchConfigurationMode { smart, manual }

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
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('选择配置方式'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '$game · AppID $appId',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          Text(filename),
          const SizedBox(height: 12),
          FutureBuilder<String?>(
            future: unavailableReason,
            builder: (_, state) {
              final reason = state.connectionState != ConnectionState.done
                  ? '正在检查目录和智能体设置…'
                  : state.hasError
                  ? '无法检查智能配置条件'
                  : state.data;
              return ListTile(
                leading: const Icon(Icons.auto_fix_high),
                title: const Text('智能配置'),
                subtitle: Text(
                  reason ??
                      (remote
                          ? '下载或复用网盘补丁，将包内及本地游戏相对路径发给服务端分析。'
                          : '服务端直接读取本地补丁，客户端仅提供游戏相对路径。'),
                ),
                enabled: reason == null,
                onTap: reason == null
                    ? () => Navigator.pop(context, PatchConfigurationMode.smart)
                    : null,
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('手动配置'),
            subtitle: const Text('直接设置此补丁的源目录和游戏内目标目录。'),
            onTap: () => Navigator.pop(context, PatchConfigurationMode.manual),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
    ],
  );
}
