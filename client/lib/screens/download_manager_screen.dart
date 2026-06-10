/// Download manager — view active and completed downloads.

import "dart:async";

import "package:flutter/material.dart";

import "../services/download_service.dart";

class DownloadManagerScreen extends StatefulWidget {
  const DownloadManagerScreen({super.key});

  @override
  State<DownloadManagerScreen> createState() => _DownloadManagerScreenState();
}

class _DownloadManagerScreenState extends State<DownloadManagerScreen> {
  List<DownloadTask> _tasks = [];
  StreamSubscription? _sub;

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
    return Scaffold(
      appBar: AppBar(title: const Text("下载管理")),
      body: _tasks.isEmpty
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.download_outlined, size: 64, color: Colors.grey[600]),
                const SizedBox(height: 12),
                Text("暂无下载任务", style: TextStyle(fontSize: 16, color: Colors.grey[500])),
              ]))
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _tasks.length,
              itemBuilder: (_, i) => _taskCard(_tasks[i]),
            ),
    );
  }

  Widget _taskCard(DownloadTask t) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _statusIcon(t.status),
          const SizedBox(width: 10),
          Expanded(
            child: Text(t.fileName, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          ),
          if (t.status == "downloading")
            Row(mainAxisSize: MainAxisSize.min, children: [
              TextButton(
                onPressed: () => DownloadService().pauseTask(t),
                child: const Text("暂停", style: TextStyle(fontSize: 12)),
              ),
              TextButton(
                onPressed: () => DownloadService().cancelTask(t),
                child: const Text("取消", style: TextStyle(fontSize: 12, color: Colors.red)),
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
                child: const Text("取消", style: TextStyle(fontSize: 12, color: Colors.red)),
              ),
            ])
          else if (t.status == "pending")
            TextButton(
              onPressed: () => DownloadService().cancelTask(t),
              child: const Text("取消", style: TextStyle(fontSize: 12, color: Colors.red)),
            )
          else if (t.status == "done" || t.status == "failed" || t.status == "cancelled")
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => DownloadService().removeTask(t),
              visualDensity: VisualDensity.compact,
            ),
        ]),
        const SizedBox(height: 4),
        Text("${t.companyName}/${t.gameName}",
            style: TextStyle(fontSize: 12, color: Colors.grey[500])),
        if (t.status == "downloading" || t.status == "paused") ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: t.progress,
              minHeight: 4,
              backgroundColor: Colors.white.withValues(alpha: 0.08),
              color: t.status == "paused" ? Colors.orange : null,
            ),
          ),
          const SizedBox(height: 4),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text("${(t.progress * 100).toStringAsFixed(0)}%",
                style: TextStyle(fontSize: 11, color: Colors.grey[500])),
            if (t.status == "paused")
              Text("已暂停", style: TextStyle(fontSize: 11, color: Colors.orange[300])),
          ]),
        ],
        if (t.status == "done" && t.outputPath != null)
          Text("已解压到: ${t.outputPath}",
              style: TextStyle(fontSize: 11, color: Colors.grey[500])),
        if (t.error != null)
          Text(t.error!, style: TextStyle(fontSize: 11, color: Colors.red[300])),
      ]),
    );
  }

  Widget _statusIcon(String status) {
    switch (status) {
      case "pending": return Icon(Icons.schedule, size: 22, color: Colors.grey[500]);
      case "downloading": return SizedBox(
        width: 22, height: 22,
        child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.blue[300])),
      );
      case "extracting": return Icon(Icons.folder_zip, size: 22, color: Colors.orange[300]);
      case "paused": return Icon(Icons.pause_circle, size: 22, color: Colors.orange[300]);
      case "done": return Icon(Icons.check_circle, size: 22, color: Colors.green[300]);
      case "failed": return Icon(Icons.error, size: 22, color: Colors.red[300]);
      case "cancelled": return Icon(Icons.cancel, size: 22, color: Colors.grey[500]);
      default: return Icon(Icons.help, size: 22, color: Colors.grey[500]);
    }
  }
}
