/// Log viewer — list and read log files.

import "dart:io";

import "package:flutter/material.dart";

import "../services/logger_service.dart";
import "../utils/theme_utils.dart";
import "../widgets/app_shell.dart";

class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  List<FileSystemEntity> _files = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final files = await LoggerService().getLogFiles();
    if (mounted) {
      setState(() {
        _files = files;
        _loading = false;
      });
    }
  }

  Future<void> _openFile(FileSystemEntity file) async {
    final content = await LoggerService().readLog(file as dynamic);
    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AppScaffold(
            title: file.path.split("/").last,
            subtitle: "日志文件详情",
            leading: const Icon(Icons.description_outlined, size: 24),
            maxWidth: 1000,
            child: AppSurface(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                content,
                style: AppText.label.copyWith(fontFamily: "monospace"),
              ),
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: "日志",
      subtitle: "查看客户端运行记录和错误信息",
      leading: const Icon(Icons.article_outlined, size: 24),
      actions: [
        AppActionButton(
          icon: Icons.refresh_rounded,
          label: "刷新",
          onPressed: () {
            setState(() => _loading = true);
            _load();
          },
        ),
      ],
      scrollable: false,
      child: _loading
          ? const AppStateView.loading(title: "正在读取日志")
          : _files.isEmpty
              ? const AppStateView(
                  icon: Icons.article_outlined,
                  title: "暂无日志",
                  message: "当前设备还没有生成可查看的客户端日志",
                )
              : AppSurface(
                  padding: const EdgeInsets.all(6),
                  child: ListView.separated(
                    itemCount: _files.length,
                    separatorBuilder: (_, __) => Divider(
                      height: 1,
                      color: cardBorder(context).withValues(alpha: 0.45),
                    ),
                    itemBuilder: (_, i) {
                      final f = _files[i];
                      final name = f.path.split("/").last;
                      return AppListTile(
                        icon: Icons.description_outlined,
                        title: name,
                        subtitle: f.path,
                        onTap: () => _openFile(f),
                      );
                    },
                  ),
                ),
    );
  }
}
