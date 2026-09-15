/// Server backup screen — export, download, import and delete backups.

import "dart:async";
import "dart:convert";
import "dart:io";

import "package:file_picker/file_picker.dart";
import "package:flutter/material.dart";
import "package:path_provider/path_provider.dart";
import "../services/logged_http.dart" as http;

import "../services/api_client.dart";
import "../utils/theme_utils.dart";
import "../widgets/app_shell.dart";

class BackupScreen extends StatefulWidget {
  final ApiClient api;
  const BackupScreen({super.key, required this.api});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  List<Map<String, dynamic>> _backups = [];
  bool _loading = true;
  bool _busy = false;
  bool _uploading = false;
  double _uploadProgress = 0;
  String? _error;
  http.Client? _activeClient;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? Colors.red[700] : null,
    ));
  }

  /// Transfer budget: at least a minute, plus room for a slow 256 KB/s link.
  Duration _transferTimeout(int bytes) {
    final seconds = 60 + (bytes / (256 * 1024)).ceil();
    return Duration(seconds: seconds.clamp(60, 3600));
  }

  void _cancelTransfer() {
    _cancelled = true;
    _activeClient?.close();
  }

  String _sizeText(int bytes) {
    if (bytes <= 0) return "0 B";
    const units = ["B", "KB", "MB", "GB", "TB"];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return unit == 0
        ? "${value.toStringAsFixed(0)} ${units[unit]}"
        : "${value.toStringAsFixed(1)} ${units[unit]}";
  }

  String _timeText(String? iso) {
    if (iso == null || iso.isEmpty) return "";
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso;
    final local = parsed.toLocal();
    String two(int v) => v.toString().padLeft(2, "0");
    return "${local.year}-${two(local.month)}-${two(local.day)} "
        "${two(local.hour)}:${two(local.minute)}";
  }

  Map<String, String> _jsonHeaders() => {
        ...widget.api.headers,
        "Content-Type": "application/json",
      };

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final resp = await http.get(
        Uri.parse("${widget.api.baseUrl}/api/backup/list"),
        headers: widget.api.headers,
      );
      if (resp.statusCode != 200) {
        setState(() {
          _loading = false;
          _error = "读取备份列表失败（HTTP ${resp.statusCode}）";
        });
        return;
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final raw = (data["backups"] as List?) ?? const [];
      setState(() {
        _backups = raw
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = "$e";
      });
    }
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final resp = await http.post(
        Uri.parse("${widget.api.baseUrl}/api/backup/export"),
        headers: _jsonHeaders(),
        body: jsonEncode({"include_media": true}),
      );
      if (resp.statusCode != 200) {
        _toast("导出失败（HTTP ${resp.statusCode}）", error: true);
        return;
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final name = data["name"]?.toString() ?? "";
      _toast(name.isEmpty ? "备份已导出" : "已生成备份：$name");
      await _load();
    } catch (e) {
      _toast("导出失败: $e", error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download(Map<String, dynamic> entry) async {
    final name = entry["name"]?.toString() ?? "";
    if (name.isEmpty) return;
    final fileName = name.split("/").last;
    final totalBytes = (entry["size"] as num?)?.toInt() ?? 0;
    final isMobile = Platform.isAndroid || Platform.isIOS;

    String? target;
    if (!isMobile) {
      target = await FilePicker.platform.saveFile(
        dialogTitle: "保存备份",
        fileName: fileName,
      );
      if (target == null || target.isEmpty) return;
    }

    setState(() {
      _busy = true;
      _cancelled = false;
    });
    File? created;
    final client = http.Client();
    _activeClient = client;
    try {
      if (isMobile) {
        final dir = Directory(
            "${(await getApplicationSupportDirectory()).path}/backups");
        await dir.create(recursive: true);
        target = "${dir.path}/$fileName";
      }
      created = File(target!);
      final request = http.Request(
        "GET",
        Uri.parse("${widget.api.baseUrl}/api/backup/download"
            "?name=${Uri.encodeQueryComponent(name)}"),
      );
      request.headers.addAll(widget.api.headers);
      final response =
          await client.send(request).timeout(_transferTimeout(totalBytes));
      if (response.statusCode != 200) {
        _toast("下载失败（HTTP ${response.statusCode}）", error: true);
        return;
      }
      final sink = created.openWrite();
      await response.stream.pipe(sink).timeout(_transferTimeout(totalBytes));
      _toast(isMobile ? "已保存到 ${created.path}" : "备份已保存");
    } catch (e) {
      if (created != null && await created.exists()) {
        try {
          await created.delete();
        } catch (_) {}
      }
      _toast(_cancelled ? "已取消" : "下载失败: $e", error: !_cancelled);
    } finally {
      client.close();
      _activeClient = null;
      if (mounted) {
        setState(() {
          _busy = false;
          _cancelled = false;
        });
      }
    }
  }

  Future<void> _delete(Map<String, dynamic> entry) async {
    final name = entry["name"]?.toString() ?? "";
    if (name.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("删除备份？"),
        content: Text(name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text("删除"),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      final resp = await http.delete(
        Uri.parse("${widget.api.baseUrl}/api/backup"
            "?name=${Uri.encodeQueryComponent(name)}"),
        headers: widget.api.headers,
      );
      if (resp.statusCode != 200) {
        _toast("删除失败（HTTP ${resp.statusCode}）", error: true);
        return;
      }
      _toast("备份已删除");
      await _load();
    } catch (e) {
      _toast("删除失败: $e", error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Stream<List<int>> _uploadStream(File file, int total) async* {
    var sent = 0;
    var reported = 0.0;
    await for (final chunk in file.openRead()) {
      sent += chunk.length;
      final progress = total > 0 ? sent / total : 0.0;
      if (progress - reported >= 0.02 || progress >= 1) {
        reported = progress;
        if (mounted) {
          setState(() => _uploadProgress = progress.clamp(0.0, 1.0));
        }
      }
      yield chunk;
    }
  }

  Future<void> _import() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ["zip", "json"],
    );
    final filePath = picked?.files.single.path;
    if (filePath == null) return;
    final fileName = picked!.files.single.name;

    if (!mounted) return;
    final options = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => const _ImportOptionsDialog(),
    );
    if (options == null) return;

    setState(() {
      _uploading = true;
      _uploadProgress = 0;
      _error = null;
      _cancelled = false;
    });
    final client = http.Client();
    _activeClient = client;
    try {
      final localFile = File(filePath);
      final total = await localFile.length();
      final request = http.MultipartRequest(
          "POST", Uri.parse("${widget.api.baseUrl}/api/backup/import"));
      request.headers.addAll(widget.api.headers);
      request.fields["scope"] = options["scope"] ?? "all";
      request.fields["mode"] = options["mode"] ?? "merge";
      request.fields["media_policy"] = options["media_policy"] ?? "skip";
      request.files.add(
        http.MultipartFile("file", _uploadStream(localFile, total), total,
            filename: fileName),
      );
      final response =
          await client.send(request).timeout(_transferTimeout(total));
      final body = await response.stream
          .bytesToString()
          .timeout(_transferTimeout(total));
      if (response.statusCode != 200) {
        String detail = "导入失败";
        try {
          detail = (jsonDecode(body) as Map)["detail"]?.toString() ?? detail;
        } catch (_) {}
        _toast(detail, error: true);
        return;
      }
      final data = jsonDecode(body) as Map<String, dynamic>;
      final lines = ((data["detail"] as List?) ?? const [])
          .map((line) => line.toString())
          .toList();
      await _load();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(data["message"]?.toString() ?? "备份已导入"),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final line in lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(line, style: AppText.caption),
                  ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text("知道了"),
            ),
          ],
        ),
      );
    } catch (e) {
      _toast(_cancelled ? "已取消" : "导入失败: $e", error: !_cancelled);
    } finally {
      client.close();
      _activeClient = null;
      if (mounted) {
        setState(() {
          _uploading = false;
          _uploadProgress = 0;
          _cancelled = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: "备份与恢复",
      subtitle: "导出、下载与恢复服务端数据",
      leading: const Icon(Icons.backup_rounded, size: 24),
      scrollable: false,
      padding: EdgeInsets.zero,
      child: _loading && _backups.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                AppSurface(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("导出备份",
                          style: AppText.subtitle
                              .copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(
                        "包含补丁规则、游戏库、账号与图片，导出后可在下方列表下载。"
                        "备份里有密码哈希与解压密码，请妥善保管。",
                        style: AppText.caption
                            .copyWith(color: hintColor(context), height: 1.35),
                      ),
                      const SizedBox(height: AppGap.sm),
                      Wrap(
                        spacing: AppGap.sm,
                        runSpacing: AppGap.sm,
                        children: [
                          AppActionButton(
                            icon: Icons.archive_outlined,
                            label: "导出备份",
                            filled: true,
                            busy: _busy,
                            onPressed: _busy ? null : _export,
                          ),
                          AppActionButton(
                            icon: Icons.upload_file_rounded,
                            label: "导入备份",
                            busy: _uploading,
                            onPressed: _uploading ? null : _import,
                          ),
                          if (_uploading || _busy)
                            AppActionButton(
                              icon: Icons.close_rounded,
                              label: "取消",
                              color: hintColor(context),
                              onPressed: _cancelTransfer,
                            ),
                        ],
                      ),
                      if (_uploading) ...[
                        const SizedBox(height: AppGap.sm),
                        LinearProgressIndicator(
                          value: _uploadProgress > 0 ? _uploadProgress : null,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          "正在上传并导入… "
                          "${(_uploadProgress * 100).clamp(0, 100).toStringAsFixed(0)}%",
                          style: AppText.caption
                              .copyWith(color: hintColor(context)),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Text("服务端上的备份",
                    style:
                        AppText.subtitle.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(_error!,
                        style: AppText.caption.copyWith(color: Colors.red[300])),
                  ),
                if (_backups.isEmpty)
                  AppSurface(
                    padding: const EdgeInsets.all(16),
                    child: Text("还没有备份文件，点上面的「导出备份」生成一份。",
                        style: AppText.caption
                            .copyWith(color: hintColor(context))),
                  )
                else
                  for (final entry in _backups) ...[
                    _backupRow(entry),
                    const SizedBox(height: AppGap.sm),
                  ],
              ],
            ),
    );
  }

  Widget _backupRow(Map<String, dynamic> entry) {
    final name = entry["name"]?.toString() ?? "";
    final shortName = name.split("/").last;
    final size = (entry["size"] as num?)?.toInt() ?? 0;
    final hasMedia = entry["has_media"] == true;
    final meta = [
      _sizeText(size),
      _timeText(entry["modified_at"]?.toString()),
      if (hasMedia) "含图片" else "仅数据",
    ].where((part) => part.isNotEmpty).join(" · ");

    return AppSurface(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Icon(
            shortName.endsWith(".zip")
                ? Icons.folder_zip_outlined
                : Icons.description_outlined,
            color: hintColor(context),
          ),
          const SizedBox(width: AppGap.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(shortName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.bodySmall
                        .copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(meta,
                    style: AppText.caption.copyWith(color: hintColor(context))),
              ],
            ),
          ),
          IconButton(
            tooltip: "下载",
            icon: const Icon(Icons.download_rounded, size: 20),
            onPressed: _busy ? null : () => _download(entry),
          ),
          IconButton(
            tooltip: "删除",
            icon: Icon(Icons.delete_outline_rounded,
                size: 20, color: Colors.red[300]),
            onPressed: _busy ? null : () => _delete(entry),
          ),
        ],
      ),
    );
  }
}

class _ImportOptionsDialog extends StatefulWidget {
  const _ImportOptionsDialog();

  @override
  State<_ImportOptionsDialog> createState() => _ImportOptionsDialogState();
}

class _ImportOptionsDialogState extends State<_ImportOptionsDialog> {
  String _scope = "all";
  String _mode = "merge";
  String _mediaPolicy = "skip";

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("导入备份"),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _scope,
              decoration: const InputDecoration(labelText: "恢复范围"),
              items: const [
                DropdownMenuItem(value: "all", child: Text("全部（补丁 + 游戏库 + 账号）")),
                DropdownMenuItem(value: "patch", child: Text("仅补丁规则")),
                DropdownMenuItem(value: "library", child: Text("仅游戏库与账号")),
              ],
              onChanged: (value) => setState(() => _scope = value ?? "all"),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _mode,
              decoration: const InputDecoration(labelText: "已存在的条目"),
              items: const [
                DropdownMenuItem(value: "merge", child: Text("合并更新（保留现有条目）")),
                DropdownMenuItem(value: "replace", child: Text("清空重建（先删除游戏库与账号）")),
              ],
              onChanged: (value) => setState(() => _mode = value ?? "merge"),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _mediaPolicy,
              decoration: const InputDecoration(labelText: "同名图片"),
              items: const [
                DropdownMenuItem(value: "skip", child: Text("跳过已有文件")),
                DropdownMenuItem(value: "overwrite", child: Text("全部覆盖")),
              ],
              onChanged: (value) =>
                  setState(() => _mediaPolicy = value ?? "skip"),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("取消"),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, {
            "scope": _scope,
            "mode": _mode,
            "media_policy": _mediaPolicy,
          }),
          child: const Text("开始导入"),
        ),
      ],
    );
  }
}
