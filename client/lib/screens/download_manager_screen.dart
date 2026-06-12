/// Download manager — view active and completed downloads.

import "dart:async";

import "package:file_picker/file_picker.dart";
import "package:flutter/material.dart";

import "../services/download_service.dart";
import "../widgets/empty_state.dart";
import "../utils/theme_utils.dart";

class DownloadManagerScreen extends StatefulWidget {
  const DownloadManagerScreen({super.key});

  @override
  State<DownloadManagerScreen> createState() => _DownloadManagerScreenState();
}

class _DownloadManagerScreenState extends State<DownloadManagerScreen> {
  List<DownloadTask> _tasks = [];
  StreamSubscription? _sub;
  String _downloadDir = "";

  @override
  void initState() {
    super.initState();
    _tasks = DownloadService().currentTasks;
    _sub = DownloadService().tasks.listen((t) {
      if (mounted) setState(() => _tasks = t);
    });
    _loadDir();
  }

  Future<void> _loadDir() async {
    final dir = await DownloadService().downloadDir;
    if (mounted) setState(() => _downloadDir = dir);
  }

  Future<void> _changeDir() async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: "选择下载目录",
    );
    if (result != null) {
      await DownloadService().setDownloadDir(result);
      if (mounted) setState(() => _downloadDir = result);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("下载管理")),
      body: Column(children: [
        // ── Download directory ──
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          decoration: BoxDecoration(
            color: cardBg(context),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cardBorder(context)),
          ),
          child: Row(children: [
            Icon(Icons.folder_outlined, size: 20, color: sectionIconColor(context)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(_downloadDir.isEmpty ? "加载中..." : _downloadDir,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: AppText.bodySmall.copyWith( color: subTextColor(context))),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: _changeDir,
              icon: const Icon(Icons.edit, size: 16),
              label: const Text("更改", style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
            ),
          ]),
        ),
        // ── Task list ──
        Expanded(
          child: _tasks.isEmpty
              ? EmptyState(icon: Icons.download_outlined, title: "暂无下载任务")
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _tasks.length,
                  itemBuilder: (_, i) => _taskCard(_tasks[i]),
                ),
          ),
        ]),
    );
  }

  Widget _taskCard(DownloadTask t) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardBg(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cardBorder(context)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _statusIcon(t.status),
          const SizedBox(width: 10),
          Expanded(
            child: Text(t.fileName, style: AppText.bodyMedium.copyWith( fontWeight: FontWeight.w500)),
          ),
          if (t.status == "downloading" || t.status == "extracting")
            Row(mainAxisSize: MainAxisSize.min, children: [
              if (t.status == "downloading")
                TextButton(
                  onPressed: () => DownloadService().pauseTask(t),
                  child: const Text("暂停", style: TextStyle(fontSize: 12)),
                ),
              TextButton(
                onPressed: () => DownloadService().cancelTask(t),
                child: Text("取消", style: AppText.label.copyWith( color: Colors.red)),
              ),
            ])
          else if (t.status == "paused")
            Row(mainAxisSize: MainAxisSize.min, children: [
              FilledButton(
                onPressed: () => DownloadService().resumeTask(t),
                child: const Text("继续", style: TextStyle(fontSize: 12)),
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4)),
              ),
              const SizedBox(width: 4),
              TextButton(
                onPressed: () => DownloadService().cancelTask(t),
                child: Text("取消", style: AppText.label.copyWith( color: Colors.red)),
              ),
            ])
          else if (t.status == "pending")
            TextButton(
              onPressed: () => DownloadService().cancelTask(t),
              child: Text("取消", style: AppText.label.copyWith( color: Colors.red)),
            )
          else if (t.status == "failed")
            Row(mainAxisSize: MainAxisSize.min, children: [
              FilledButton(
                onPressed: () => DownloadService().retryTask(t),
                child: const Text("重试", style: TextStyle(fontSize: 12)),
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4)),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => DownloadService().removeTask(t),
                visualDensity: VisualDensity.compact,
              ),
            ])
          else if (t.status == "done" || t.status == "cancelled")
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => DownloadService().removeTask(t),
              visualDensity: VisualDensity.compact,
            ),
        ]),
        const SizedBox(height: 4),
        Text("${t.companyName}/${t.gameName}",
            style: AppText.label.copyWith( color: hintColor(context))),
        if (t.status == "downloading" || t.status == "paused" || t.status == "extracting") ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: t.progress,
              minHeight: 4,
              backgroundColor: cardBorder(context),
              color: t.status == "paused" ? Colors.orange : null,
            ),
          ),
          const SizedBox(height: 4),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(t.status == "extracting" ? "解压中..." : "${(t.progress * 100).toStringAsFixed(0)}%",
                style: AppText.caption.copyWith( color: hintColor(context))),
            if (t.status == "downloading")
              Text(_formatSpeed(t.speedBytesPerSecond),
                  style: AppText.caption.copyWith( color: hintColor(context))),
            if (t.status == "paused")
              Text("已暂停", style: AppText.caption.copyWith( color: Colors.orange[300])),
          ]),
        ],
        if (t.status == "done" && t.outputPath != null)
          Text("已解压到: ${t.outputPath}",
              style: AppText.caption.copyWith( color: hintColor(context))),
        if (t.error != null)
          Text(t.error!, style: AppText.caption.copyWith( color: Colors.red[300])),
      ]),
    );
  }

  String _formatSpeed(int bytesPerSec) {
    if (bytesPerSec <= 0) return "";
    if (bytesPerSec < 1024) return "$bytesPerSec B/s";
    if (bytesPerSec < 1048576) return "${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s";
    return "${(bytesPerSec / 1048576).toStringAsFixed(1)} MB/s";
  }

  Widget _statusIcon(String status) {
    switch (status) {
      case "pending": return Icon(Icons.schedule, size: 22, color: hintColor(context));
      case "downloading": return SizedBox(
        width: 22, height: 22,
        child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.blue[300])),
      );
      case "extracting": return Icon(Icons.folder_zip, size: 22, color: Colors.orange[300]);
      case "paused": return Icon(Icons.pause_circle, size: 22, color: Colors.orange[300]);
      case "done": return Icon(Icons.check_circle, size: 22, color: Colors.green[300]);
      case "failed": return Icon(Icons.error, size: 22, color: Colors.red[300]);
      case "cancelled": return Icon(Icons.cancel, size: 22, color: hintColor(context));
      default: return Icon(Icons.help, size: 22, color: hintColor(context));
    }
  }
}
