/// Log viewer — list and read log files.

import "dart:io";

import "package:flutter/material.dart";

import "../services/logger_service.dart";

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
    if (mounted) setState(() { _files = files; _loading = false; });
  }

  Future<void> _openFile(FileSystemEntity file) async {
    final content = await LoggerService().readLog(file as dynamic);
    if (mounted) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => Scaffold(
        appBar: AppBar(title: Text(file.path.split("/").last)),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText(content, style: const TextStyle(fontSize: 12, fontFamily: "monospace")),
        ),
      )));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("日志")),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _files.isEmpty
              ? Center(child: Text("暂无日志", style: TextStyle(color: Colors.grey[500], fontSize: 15)))
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _files.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final f = _files[i];
                    final name = f.path.split("/").last;
                    final size = f is dynamic ? "" : "";
                    return ListTile(
                      leading: const Icon(Icons.description_outlined),
                      title: Text(name),
                      trailing: const Icon(Icons.chevron_right, size: 18),
                      onTap: () => _openFile(f),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    );
                  },
                ),
    );
  }
}
