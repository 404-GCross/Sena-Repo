/// Download manager — view active and completed downloads.

import "dart:async";

import "dart:io" show Platform;

import "package:file_picker/file_picker.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";

import "dart:convert";

import "../services/logged_http.dart" as http;
import "package:provider/provider.dart";

import "../providers/game_provider.dart";
import "../services/download_service.dart";
import "../services/file_open_service.dart";
import "../services/shortcut_service.dart";
import "../services/steam_integration_service.dart";
import "../widgets/empty_state.dart";
import "../utils/theme_utils.dart";
import "../widgets/app_shell.dart";

class DownloadManagerScreen extends StatefulWidget {
  const DownloadManagerScreen({super.key});

  @override
  State<DownloadManagerScreen> createState() => _DownloadManagerScreenState();
}

class _DownloadManagerScreenState extends State<DownloadManagerScreen> {
  List<DownloadTask> _tasks = [];
  StreamSubscription? _sub;
  final _pwdCtrls = <int, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    _tasks = DownloadService().currentTasks;
    _sub = DownloadService().tasks.listen((t) {
      if (mounted) setState(() => _tasks = t);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activeCount = _tasks
        .where((t) =>
            t.status == "pending" ||
            t.status == "downloading" ||
            t.status == "extracting" ||
            t.status == "paused")
        .length;
    final failedCount = _tasks.where((t) => t.status == "failed").length;
    final doneCount = _tasks.where((t) => t.status == "done").length;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackdrop(
        child: Column(
          children: [
            const AppPageHeader(
              showBack: true,
              leading: Icon(Icons.download_outlined, size: 26),
              title: "下载管理",
              subtitle: "查看下载、解压、失败重试和安装后操作",
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final cardWidth = constraints.maxWidth >= 720
                      ? (constraints.maxWidth - 24) / 4
                      : (constraints.maxWidth - 12) / 2;
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      SizedBox(
                        width: cardWidth,
                        child: AppMetricCard(
                          label: "全部任务",
                          value: "${_tasks.length}",
                          icon: Icons.queue,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      SizedBox(
                        width: cardWidth,
                        child: AppMetricCard(
                          label: "进行中",
                          value: "$activeCount",
                          icon: Icons.sync,
                          color: Colors.blue,
                        ),
                      ),
                      SizedBox(
                        width: cardWidth,
                        child: AppMetricCard(
                          label: "失败",
                          value: "$failedCount",
                          icon: Icons.error_outline,
                          color: failedCount > 0 ? Colors.red : Colors.grey,
                        ),
                      ),
                      SizedBox(
                        width: cardWidth,
                        child: AppMetricCard(
                          label: "已完成",
                          value: "$doneCount",
                          icon: Icons.check_circle_outline,
                          color: Colors.green,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: AppSurface(
                  padding: EdgeInsets.zero,
                  child: _tasks.isEmpty
                      ? EmptyState(
                          icon: Icons.download_outlined, title: "暂无下载任务")
                      : ListView.builder(
                          padding: const EdgeInsets.all(14),
                          itemCount: _tasks.length,
                          itemBuilder: (_, i) => _taskCard(_tasks[i]),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _taskCard(DownloadTask t) {
    return AppSurface(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 560;
          final actions = _taskActions(t, compact: compact);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _statusIcon(t.status),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      t.fileName,
                      maxLines: compact ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.bodyMedium.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (!compact && actions != null) ...[
                    const SizedBox(width: 8),
                    actions,
                  ],
                ],
              ),
              if (compact && actions != null) ...[
                const SizedBox(height: 8),
                actions,
              ],
              const SizedBox(height: 4),
              Text(
                "${t.companyName}/${t.gameName}",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.label.copyWith(color: hintColor(context)),
              ),
              if (_isActiveTask(t)) _progressSection(t, compact: compact),
              if (t.status == "done" && t.outputPath != null)
                _completedSection(t),
              if (t.error != null) _errorSection(t.error!),
            ],
          );
        },
      ),
    );
  }

  bool _isActiveTask(DownloadTask t) =>
      t.status == "downloading" ||
      t.status == "paused" ||
      t.status == "extracting";

  Widget? _taskActions(DownloadTask t, {required bool compact}) {
    if (t.status == "downloading" || t.status == "extracting") {
      return Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          if (t.status == "downloading")
            TextButton(
              onPressed: () => DownloadService().pauseTask(t),
              child: const Text("暂停", style: TextStyle(fontSize: 12)),
            ),
          TextButton(
            onPressed: () => DownloadService().cancelTask(t),
            child: Text(
              "取消",
              style: AppText.label.copyWith(color: Colors.red),
            ),
          ),
        ],
      );
    }
    if (t.status == "paused") {
      return Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          FilledButton(
            onPressed: () => DownloadService().resumeTask(t),
            style: _smallFilledButtonStyle(),
            child: const Text("继续", style: TextStyle(fontSize: 12)),
          ),
          TextButton(
            onPressed: () => DownloadService().cancelTask(t),
            child: Text(
              "取消",
              style: AppText.label.copyWith(color: Colors.red),
            ),
          ),
        ],
      );
    }
    if (t.status == "pending") {
      return TextButton(
        onPressed: () => DownloadService().cancelTask(t),
        child: Text(
          "取消",
          style: AppText.label.copyWith(color: Colors.red),
        ),
      );
    }
    if (t.status == "failed") {
      if (t.needsPassword) {
        return Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          runSpacing: 6,
          children: [
            SizedBox(
              width: compact ? 150 : 130,
              height: 32,
              child: TextField(
                controller: _pwdCtrls.putIfAbsent(
                  t.versionId,
                  () => TextEditingController(),
                ),
                obscureText: true,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  hintText: "解压密码",
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                ),
              ),
            ),
            FilledButton(
              onPressed: () {
                final pwd = (_pwdCtrls[t.versionId]?.text ?? "").trim();
                if (pwd.isNotEmpty) {
                  DownloadService().retryWithPassword(t, pwd);
                }
              },
              style: _smallFilledButtonStyle(horizontal: 10),
              child: const Text("带密码重试", style: TextStyle(fontSize: 12)),
            ),
            FilledButton(
              onPressed: () => DownloadService().retryTask(t),
              style: _smallFilledButtonStyle(horizontal: 10),
              child: const Text("无密码重试", style: TextStyle(fontSize: 12)),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => DownloadService().removeTask(t),
              visualDensity: VisualDensity.compact,
            ),
          ],
        );
      }
      return Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        runSpacing: 6,
        children: [
          FilledButton(
            onPressed: () => DownloadService().retryTask(t),
            style: _smallFilledButtonStyle(),
            child: const Text("重试", style: TextStyle(fontSize: 12)),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => DownloadService().removeTask(t),
            visualDensity: VisualDensity.compact,
          ),
        ],
      );
    }
    if (t.status == "done" || t.status == "cancelled") {
      return IconButton(
        icon: const Icon(Icons.close, size: 18),
        onPressed: () => DownloadService().removeTask(t),
        visualDensity: VisualDensity.compact,
      );
    }
    return null;
  }

  ButtonStyle _smallFilledButtonStyle({double horizontal = 12}) {
    return FilledButton.styleFrom(
      padding: EdgeInsets.symmetric(horizontal: horizontal, vertical: 4),
    );
  }

  Widget _progressSection(DownloadTask t, {required bool compact}) {
    final statusText = t.status == "extracting"
        ? "解压中..."
        : t.totalBytes > 0
            ? "${(t.progress * 100).toStringAsFixed(0)}% · ${_fmtSize(t.receivedBytes)} / ${_fmtSize(t.totalBytes)}"
            : t.receivedBytes > 0
                ? "已下载 ${_fmtSize(t.receivedBytes)}"
                : t.headersReceived
                    ? "已连接，等待数据..."
                    : "正在连接...";
    final trailingText = t.status == "downloading"
        ? _formatSpeed(t.speedBytesPerSecond)
        : t.status == "paused"
            ? "已暂停"
            : null;
    final trailingColor = t.status == "paused" ? Colors.orange[300] : null;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: t.totalBytes > 0 ? t.progress : null,
              minHeight: compact ? 6 : 4,
              backgroundColor: cardBorder(context),
              color: t.status == "paused" ? Colors.orange : null,
            ),
          ),
          const SizedBox(height: 6),
          if (compact)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  statusText,
                  style: AppText.caption.copyWith(color: hintColor(context)),
                ),
                if (trailingText != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    trailingText,
                    style: AppText.caption.copyWith(
                      color: trailingColor ?? hintColor(context),
                    ),
                  ),
                ],
              ],
            )
          else
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    statusText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(color: hintColor(context)),
                  ),
                ),
                if (trailingText != null) ...[
                  const SizedBox(width: 12),
                  Text(
                    trailingText,
                    style: AppText.caption.copyWith(
                      color: trailingColor ?? hintColor(context),
                    ),
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }

  Widget _completedSection(DownloadTask t) {
    if (t.isApk) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 6,
          children: [
            Icon(Icons.android, size: 16, color: Colors.green[300]),
            Text(
              "APK 就绪",
              style: AppText.caption.copyWith(color: Colors.green[300]),
            ),
            FilledButton.icon(
              onPressed: () => _installApk(t.outputPath!),
              icon: const Icon(Icons.install_mobile, size: 16),
              label: const Text("安装", style: TextStyle(fontSize: 12)),
              style: _smallFilledButtonStyle(),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            Platform.isAndroid ? "已下载: ${t.outputPath}" : "已解压到: ${t.outputPath}",
            style: AppText.caption.copyWith(color: hintColor(context)),
          ),
          if (!Platform.isAndroid) ...[
            const SizedBox(height: 6),
            Builder(
              builder: (_) {
                final exes = ShortcutService.findAllExecutables(
                  t.outputPath!,
                  gameName: t.gameName,
                );
                final exeCount = exes.length > 1 ? " (${exes.length}个)" : "";
                return Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _openTargetFolder(t.outputPath!),
                      icon: const Icon(Icons.folder_open, size: 14),
                      label: const Text(
                        "打开文件夹",
                        style: TextStyle(fontSize: 11),
                      ),
                      style: _smallOutlinedButtonStyle(),
                    ),
                    if (exes.isNotEmpty) ...[
                      OutlinedButton.icon(
                        onPressed: () => _addToSteam(t, t.outputPath!),
                        icon: const Icon(Icons.gamepad, size: 14),
                        label: Text(
                          "添加到 Steam$exeCount",
                          style: const TextStyle(fontSize: 11),
                        ),
                        style: _smallOutlinedButtonStyle(),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _createShortcut(t, t.outputPath!),
                        icon: const Icon(Icons.desktop_windows, size: 14),
                        label: const Text(
                          "快捷方式",
                          style: TextStyle(fontSize: 11),
                        ),
                        style: _smallOutlinedButtonStyle(),
                      ),
                    ],
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  ButtonStyle _smallOutlinedButtonStyle() {
    return OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      minimumSize: Size.zero,
    );
  }

  Widget _errorSection(String error) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.red.withValues(alpha: 0.18)),
      ),
      child: Text(
        error,
        style: AppText.caption.copyWith(color: Colors.red[300]),
      ),
    );
  }

  Future<void> _openTargetFolder(String path) async {
    try {
      final ok = await FileOpenService.openTargetFolder(path);
      if (!ok) _toast("无法打开目标文件夹");
    } catch (e) {
      _toast("无法打开目标文件夹: $e");
    }
  }

  Future<String?> _pickExe(String dir) async {
    final exes = ShortcutService.findAllExecutables(dir);
    if (exes.isEmpty) return null;
    if (exes.length == 1) return exes.first;
    return await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("选择启动程序"),
        content: SizedBox(
          width: 400,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: exes.length,
            itemBuilder: (_, i) {
              final name = exes[i].split(RegExp(r"[/\\]")).last;
              return ListTile(
                leading: const Icon(Icons.insert_drive_file, size: 20),
                title: Text(name, style: const TextStyle(fontSize: 13)),
                subtitle: Text(exes[i], style: const TextStyle(fontSize: 11)),
                onTap: () => Navigator.pop(ctx, exes[i]),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("取消"),
          ),
        ],
      ),
    );
  }

  Future<void> _addToSteam(DownloadTask t, String dir) async {
    final exe = await _pickExe(dir);
    if (exe == null) return;

    // Resolve cover/hero URLs: use task values, or refetch from API if missing
    String coverUrl = t.coverUrl ?? "";
    String heroUrl = t.bgUrl ?? "";
    if ((coverUrl.isEmpty || heroUrl.isEmpty) && t.gameId > 0) {
      try {
        final api = context.read<GameProvider>().api;
        final resp = await http.get(
          Uri.parse("${api.baseUrl}/api/games/${t.gameId}"),
          headers: api.headers,
        );
        if (resp.statusCode == 200) {
          final g = jsonDecode(resp.body);
          if (coverUrl.isEmpty &&
              g["cover_path"] != null &&
              g["cover_path"].toString().isNotEmpty) {
            final name =
                g["cover_path"].toString().split(RegExp(r'[/\\]')).last;
            coverUrl = "${api.baseUrl}/api/files/covers/$name";
          }
          if (heroUrl.isEmpty &&
              g["bg_path"] != null &&
              g["bg_path"].toString().isNotEmpty) {
            final name = g["bg_path"].toString().split(RegExp(r'[/\\]')).last;
            heroUrl = "${api.baseUrl}/api/files/backgrounds/$name";
          }
        }
      } catch (_) {}
    }

    var result = await SteamIntegrationService().addToSteam(
      gameName: t.gameName,
      exePath: exe,
      coverUrl: coverUrl,
      heroUrl: heroUrl,
    );
    // If not configured, let user pick directory and retry
    if (!result.success && result.message.contains("未配置 Steam 目录")) {
      final picked = await FilePicker.platform.getDirectoryPath(
        dialogTitle: "选择 Steam steamapps 目录",
      );
      if (picked != null) {
        await SteamIntegrationService().setSteamappsDir(picked);
        result = await SteamIntegrationService().addToSteam(
          gameName: t.gameName,
          exePath: exe,
          coverUrl: coverUrl,
          heroUrl: heroUrl,
        );
      }
    }
    if (!result.success && result.message.contains("Steam 用户 ID")) {
      final ctrl = TextEditingController();
      final hintPath = await SteamIntegrationService().getSteamappsDir();
      final input = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("设置 Steam 用户 ID"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Steam 用户 ID 就是你的 Steam 好友代码", style: AppText.bodySmall),
                  Text(
                    "在 Steam 客户端里点好友 → 添加好友就能看到",
                    style: AppText.bodySmall.copyWith(color: Colors.grey),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: ctrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(hintText: "例如: 12345678"),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("取消"),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text("保存"),
            ),
          ],
        ),
      );
      if (input != null && input.isNotEmpty) {
        await SteamIntegrationService().setSteamUserId(input);
        result = await SteamIntegrationService().addToSteam(
          gameName: t.gameName,
          exePath: exe,
          coverUrl: coverUrl,
          heroUrl: heroUrl,
        );
      }
    }
    _toast(result.message);
  }

  Future<void> _createShortcut(DownloadTask t, String dir) async {
    final exe = await _pickExe(dir);
    if (exe == null) return;
    try {
      final ok = await ShortcutService.createShortcut(
        gameName: t.gameName,
        exePath: exe,
        coverPath: null,
        workingDir: dir,
      );
      _toast(ok ? "快捷方式已创建" : "创建失败");
    } catch (e) {
      _toast("创建失败: $e");
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(msg),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("确定"),
          ),
        ],
      ),
    );
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1048576) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1073741824) return "${(bytes / 1048576).toStringAsFixed(1)} MB";
    return "${(bytes / 1073741824).toStringAsFixed(1)} GB";
  }

  static const _installChannel = MethodChannel("com.github.senarepo/installer");

  Future<void> _installApk(String filePath) async {
    try {
      await _installChannel.invokeMethod("installApk", {"filePath": filePath});
    } catch (e) {
      _toast("安装失败: $e");
    }
  }

  String _formatSpeed(int bytesPerSec) {
    if (bytesPerSec <= 0) return "";
    if (bytesPerSec < 1024) return "$bytesPerSec B/s";
    if (bytesPerSec < 1048576)
      return "${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s";
    return "${(bytesPerSec / 1048576).toStringAsFixed(1)} MB/s";
  }

  Widget _statusIcon(String status) {
    switch (status) {
      case "pending":
        return Icon(Icons.schedule, size: 22, color: hintColor(context));
      case "downloading":
        return SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(Colors.blue[300]),
          ),
        );
      case "extracting":
        return Icon(Icons.folder_zip, size: 22, color: Colors.orange[300]);
      case "paused":
        return Icon(Icons.pause_circle, size: 22, color: Colors.orange[300]);
      case "done":
        return Icon(Icons.check_circle, size: 22, color: Colors.green[300]);
      case "failed":
        return Icon(Icons.error, size: 22, color: Colors.red[300]);
      case "cancelled":
        return Icon(Icons.cancel, size: 22, color: hintColor(context));
      default:
        return Icon(Icons.help, size: 22, color: hintColor(context));
    }
  }
}
