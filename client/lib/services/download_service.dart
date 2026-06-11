/// Download service — stream download with progress + 7z extraction.
/// Windows: 7z.exe + 7z.dll (x64, full format support incl. RAR)
/// Linux:   7zz (standalone x64)
///
/// Flow: download(tmp) → validate(disk size) → extract

import "dart:async";
import "dart:io";

import "package:flutter/services.dart" show rootBundle;
import "package:http/http.dart" as http;
import "package:path_provider/path_provider.dart";
import "package:shared_preferences/shared_preferences.dart";

// ────────────────────────────────────────────────────
// DownloadTask
// ────────────────────────────────────────────────────

class DownloadTask {
  final int gameId;
  final int versionId;
  final String fileName;
  final String downloadUrl;
  final String gameName;
  final String companyName;

  String status; // pending, downloading, retrying, extracting, done, failed, paused, cancelled
  double progress;
  int receivedBytes;
  int totalBytes;
  String? error;
  String? outputPath;
  final DateTime startedAt;
  http.Client? _client;
  bool _cancelled = false;

  DownloadTask({
    required this.gameId,
    required this.versionId,
    required this.fileName,
    required this.downloadUrl,
    required this.gameName,
    required this.companyName,
    this.status = "pending",
    this.progress = 0,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.error,
    this.outputPath,
  }) : startedAt = DateTime.now();

  Map<String, dynamic> toJson() => {
    "gameId": gameId,
    "versionId": versionId,
    "fileName": fileName,
    "downloadUrl": downloadUrl,
    "gameName": gameName,
    "companyName": companyName,
    "status": status,
    "progress": progress,
    "error": error,
    "outputPath": outputPath,
    "startedAt": startedAt.toIso8601String(),
  };
}

// ────────────────────────────────────────────────────
// DownloadService
// ────────────────────────────────────────────────────

class DownloadService {
  static final DownloadService _instance = DownloadService._();
  factory DownloadService() => _instance;
  DownloadService._();

  final List<DownloadTask> _tasks = [];
  final _controller = StreamController<List<DownloadTask>>.broadcast();

  Stream<List<DownloadTask>> get tasks => _controller.stream;
  List<DownloadTask> get currentTasks => List.unmodifiable(_tasks);

  // ── download directory ──

  String? _downloadDir;
  Future<String> get downloadDir async {
    if (_downloadDir != null) return _downloadDir!;
    final prefs = await SharedPreferences.getInstance();
    _downloadDir = prefs.getString("local_download_dir") ??
        "${(await getApplicationSupportDirectory()).path}/downloads";
    await Directory(_downloadDir!).create(recursive: true);
    return _downloadDir!;
  }

  Future<void> setDownloadDir(String path) async {
    _downloadDir = path;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("local_download_dir", path);
    await Directory(path).create(recursive: true);
  }

  // ── public API ──

  DownloadTask startDownload({
    required int gameId,
    required int versionId,
    required String fileName,
    required String downloadUrl,
    required String gameName,
    required String companyName,
  }) {
    final task = DownloadTask(
      gameId: gameId, versionId: versionId, fileName: fileName,
      downloadUrl: downloadUrl, gameName: gameName, companyName: companyName,
    );
    _tasks.insert(0, task);
    _emit();
    _run(task);
    return task;
  }

  void pauseTask(DownloadTask task) {
    if (task.status == "downloading" || task.status == "retrying") {
      task._client?.close();
      task._client = null;
      task.status = "paused";
      _emit();
    } else if (task.status == "extracting") {
      _killExtractor();
      task.status = "paused";
      _emit();
    }
  }

  void resumeTask(DownloadTask task) {
    if (task.status == "paused") {
      task.status = "pending";
      _emit();
      _run(task);
    }
  }

  void retryTask(DownloadTask task) {
    if (task.status == "failed") {
      task.status = "pending";
      task.error = null;
      task.progress = task.totalBytes > 0 ? task.receivedBytes / task.totalBytes : 0;
      _emit();
      _run(task);
    }
  }

  void cancelTask(DownloadTask task) {
    if (task.status == "downloading" || task.status == "pending" ||
        task.status == "retrying" || task.status == "extracting") {
      task._client?.close();
      task._client = null;
      _killExtractor();
      task._cancelled = true;
      task.status = "cancelled";
      task.error = "已取消";
      _emit();
      _cleanupTemp(task);
    }
  }

  void removeTask(DownloadTask task) {
    cancelTask(task);
    _tasks.remove(task);
    _emit();
  }

  // ── binary management ──

  String? _sevenZipPath;
  Process? _extractionProcess;
  bool _userSkippedSetup = false;
  Future<bool> Function()? onSetupNeeded;

  static const int _min7zaVersion = 1600; // 16.00 = first RAR5 support

  Future<int?> _get7zaVersion(String path) async {
    try {
      final r = await Process.run(path, []);
      final m = RegExp(r'(\d+)\.(\d+)').firstMatch("${r.stdout}${r.stderr}");
      if (m != null) { return int.parse(m.group(1)!) * 100 + int.parse(m.group(2)!); }
      return null;
    } catch (_) { return null; }
  }

  Future<String> _getSevenZipPath() async {
    if (_sevenZipPath != null) return _sevenZipPath!;

    final dir = await getApplicationSupportDirectory();
    final exeName = Platform.isWindows ? "7z.exe" : "7zz";
    final dest = File("${dir.path}/$exeName");

    // Replace old binary (<16.00) or old 7za.exe
    if (await dest.exists()) {
      final v = await _get7zaVersion(dest.path);
      if (v != null && v < _min7zaVersion) {
        try { await dest.delete(); } catch (_) {}
        try { await File("${dir.path}/7z.dll").delete(); } catch (_) {}
      }
      // Also clean up old 7za from previous versions
      try { await File("${dir.path}/7za.exe").delete(); } catch (_) {}
      try { await File("${dir.path}/7za.dll").delete(); } catch (_) {}
    }

    if (!await dest.exists()) {
      // Extract from bundled assets
      bool ok = false;
      try {
        final data = await rootBundle.load("assets/binaries/$exeName");
        await dest.writeAsBytes(data.buffer.asUint8List());
        // 7z.dll (Windows only — full format support incl. RAR)
        if (Platform.isWindows) {
          try {
            final dll = await rootBundle.load("assets/binaries/7z.dll");
            await File("${dir.path}/7z.dll").writeAsBytes(dll.buffer.asUint8List());
          } catch (_) {}
        }
        if (Platform.isLinux) await Process.run("chmod", ["+x", dest.path]);
        if (await dest.exists()) ok = true;
      } catch (_) {}

      // Download fallback
      if (!ok && onSetupNeeded != null && !_userSkippedSetup) {
        if (!await onSetupNeeded!()) {
          _userSkippedSetup = true;
          throw Exception("需要 7-Zip 才能解压。请安装后再试。");
        }
        await _downloadBinary(dest, dir.path);
      }

      if (!await dest.exists()) {
        throw Exception("解压组件未就绪。请将 $exeName 放到 ${dir.path}");
      }
    }

    _sevenZipPath = dest.path;
    return _sevenZipPath!;
  }

  Future<void> _downloadBinary(File dest, String dir) async {
    if (Platform.isWindows) {
      // Download installer, run silently, copy 7z.exe + 7z.dll
      final tmp = File("$dir/_7z_installer.exe");
      final client = http.Client();
      try {
        final resp = await client.send(http.Request("GET",
            Uri.parse("https://www.7-zip.org/a/7z2601-x64.exe")));
        if (resp.statusCode != 200) throw Exception("HTTP ${resp.statusCode}");
        final sink = tmp.openWrite();
        await for (final c in resp.stream) sink.add(c);
        await sink.flush();
        await sink.close();
        await Process.run(tmp.path, ["/S"]);
        for (final d in ["C:/Program Files/7-Zip", r"C:\Program Files (x86)\7-Zip"]) {
          final src = File("$d/7z.exe");
          if (await src.exists()) {
            await src.copy(dest.path);
            try { await File("$d/7z.dll").copy("${dir}/7z.dll"); } catch (_) {}
            break;
          }
        }
        await tmp.delete();
      } finally { client.close(); }
    } else {
      // Linux: extract from tar.xz
      final tmp = File("$dir/_7z_dl");
      final client = http.Client();
      try {
        final resp = await client.send(http.Request("GET",
            Uri.parse("https://www.7-zip.org/a/7z2409-linux-x64.tar.xz")));
        if (resp.statusCode != 200) throw Exception("HTTP ${resp.statusCode}");
        final sink = tmp.openWrite();
        await for (final c in resp.stream) sink.add(c);
        await sink.close();
        await Process.run("tar", ["-xf", tmp.path, "-C", dir]);
        await tmp.delete();
      } finally { client.close(); }
    }
  }

  // ── core run loop ──

  Future<void> _run(DownloadTask t) async {
    final dir = await downloadDir;
    final tmp = File("$dir/.tmp_${t.versionId}_${t.fileName}");
    final outDir = _outDir(t, dir);
    try {
      t._cancelled = false;
      await Directory(outDir).create(recursive: true);

      // Download + extract with extract-level retry
      const maxExtractRetries = 2;
      for (int retry = 0; retry <= maxExtractRetries; retry++) {
        if (_stopped(t)) { try { await tmp.delete(); } catch (_) {} return; }

        // Phase 1: download
        t.status = "downloading";
        _emit();
        await _download(t, tmp);
        if (_stopped(t)) { try { await tmp.delete(); } catch (_) {} return; }

        // Phase 2: extract — yield to let UI show extracting state first
        t.status = "extracting";
        t.progress = 0.0;
        _emit();
        await Future.delayed(const Duration(milliseconds: 100));
        try {
          await _extract(tmp.path, outDir, (p) {
            if (p > t.progress) { t.progress = p; _emit(); }
          });
          t.progress = 1.0;
          _emit();

          await tmp.delete();
          break; // success
        } catch (e) {
          if (_stopped(t)) {
            try { await tmp.delete(); } catch (_) {}
            return;
          }
          if (retry < maxExtractRetries) {
            // Corrupted file — delete and re-download
            try { await tmp.delete(); } catch (_) {}
            t.receivedBytes = 0;
            t.totalBytes = 0;
            t.status = "retrying";
            _emit();
            await Future.delayed(const Duration(seconds: 2));
            continue;
          }
          rethrow;
        }
      }

      // Phase 3: done
      t.status = "done";
      t.outputPath = outDir;
      _emit();
    } catch (e) {
      if (t._cancelled || t.status == "paused") {
        try { await tmp.delete(); } catch (_) {}
        return;
      }
      try { await tmp.delete(); } catch (_) {}
      t.status = "failed";
      t.error = "$e";
      _emit();
    }
  }

  // ── download ──

  static const _maxRetries = 3;
  static const _retryDelays = [1, 3, 7]; // seconds

  Future<void> _download(DownloadTask t, File dest) async {
    for (int attempt = 0; attempt <= _maxRetries; attempt++) {
      if (_stopped(t)) return;

      // Sync counter with disk (crash recovery)
      if (t.receivedBytes > 0 && await dest.exists()) {
        final sz = await dest.length();
        if (sz != t.receivedBytes) t.receivedBytes = sz;
      }

      // Already complete?
      if (t.totalBytes > 0 && t.receivedBytes >= t.totalBytes) return;

      try {
        await _attempt(t, dest);
        return; // success
      } on http.ClientException catch (e) {
        if (_stopped(t)) return;
        if (attempt >= _maxRetries) throw Exception("网络中断（重试${_maxRetries}次后仍失败）: $e");
        _setStatus(t, "retrying");
        await Future.delayed(Duration(seconds: _retryDelays[attempt]));
        _setStatus(t, "downloading");
      } on SocketException catch (e) {
        if (_stopped(t)) return;
        if (attempt >= _maxRetries) throw Exception("网络不通（重试${_maxRetries}次后仍失败）: $e");
        _setStatus(t, "retrying");
        await Future.delayed(Duration(seconds: _retryDelays[attempt]));
        _setStatus(t, "downloading");
      }
    }
  }

  Future<void> _attempt(DownloadTask t, File dest) async {
    final client = http.Client();
    t._client = client;
    try {
      final req = http.Request("GET", Uri.parse(t.downloadUrl));

      // Range for resume
      if (t.receivedBytes > 0 && await dest.exists()) {
        req.headers["Range"] = "bytes=${t.receivedBytes}-";
      }

      final resp = await client.send(req);

      // 416 = Range not satisfiable → already complete
      if (resp.statusCode == 416) {
        if (t.totalBytes > 0 && t.receivedBytes >= t.totalBytes) return;
        // Reset and retry
        t.receivedBytes = 0;
        t.totalBytes = 0;
        throw http.ClientException("Range not satisfiable");
      }

      if (resp.statusCode != 200 && resp.statusCode != 206) {
        throw Exception("HTTP ${resp.statusCode}");
      }

      // Server doesn't support Range → reset
      if (t.receivedBytes > 0 && resp.statusCode != 206) {
        t.receivedBytes = 0;
        t.totalBytes = 0;
      }

      // Track total size
      final int cl = (resp.contentLength ?? 0) as int;
      final int total = t.receivedBytes + cl;
      if (total > 0) t.totalBytes = total;

      // Stream to file
      int received = t.receivedBytes;
      final sink = dest.openWrite(
          mode: (resp.statusCode == 206) ? FileMode.append : FileMode.write);

      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        t.receivedBytes = received;
        if (t.totalBytes > 0) {
          t.progress = received / t.totalBytes;
          _emit();
        }
      }
      await sink.flush();
      await sink.close();

      // Validate disk
      final fileSize = await dest.length();
      if (t.totalBytes > 0 && fileSize != t.totalBytes) {
        t.receivedBytes = 0;
        t.totalBytes = 0;
        try { await dest.delete(); } catch (_) {}
        throw Exception("文件不完整: 预期${t.totalBytes}B 实际${fileSize}B");
      }
      if (fileSize == 0) {
        throw Exception("未收到任何数据");
      }
      // Sync counter
      if (t.receivedBytes != fileSize) t.receivedBytes = fileSize;
    } finally {
      client.close();
      t._client = null;
    }
  }

  // ── extract ──

  /// Parse `7z l` output to get top-level entries in the archive.
  /// Returns null if parsing fails.
  Future<List<String>?> _listTopLevel(String filePath) async {
    try {
      final exe = await _getSevenZipPath();
      final proc = await Process.start(exe, ["l", filePath]);
      final out = <int>[];
      proc.stdout.listen((d) => out.addAll(d));
      proc.stderr.drain<void>();
      await proc.exitCode.timeout(const Duration(seconds: 60));

      final text = String.fromCharCodes(out);
      final lines = text.split("\n");
      final entries = <String>{};
      bool inList = false;
      for (final line in lines) {
        // Detect the separator line before file listing
        if (line.contains("---") && line.contains("-")) { inList = true; continue; }
        if (!inList || line.trim().isEmpty) continue;
        // Parse the name column (last field after spaces)
        final fields = line.trim().split(RegExp(r'\s{2,}'));
        if (fields.length < 3) continue;
        final name = fields.last.trim();
        if (name.isEmpty) continue;
        // Only top-level: no path separator
        if (!name.contains("\\") && !name.contains("/")) {
          entries.add(name);
        }
      }
      return entries.isEmpty ? null : entries.toList();
    } catch (_) {
      return null;
    }
  }

  Future<void> _extract(String filePath, String outDir,
      [void Function(double)? onProgress]) async {
    final exe = await _getSevenZipPath();

    // Pre-scan: if archive contains one top-level folder, extract to parent
    // to eliminate double-nesting (e.g. 会社/游戏名/游戏名 → 会社/游戏名)
    final topLevel = await _listTopLevel(filePath);
    final extParent = File(outDir).parent.path;
    if (topLevel != null && topLevel.length == 1) {
      // Single folder at root — extract one level up, then rename if needed
      final archiveFolder = topLevel.first;
      final expectedName = outDir.split(Platform.pathSeparator).last;
      await _runTool(exe, ["x", "-y", "-o$extParent", filePath],
          onProgress: onProgress);
      // Rename if archive folder name differs from expected
      if (archiveFolder != expectedName) {
        try {
          await Directory("$extParent/$archiveFolder")
              .rename("$extParent/$expectedName");
        } catch (_) {}
      }
      return;
    }

    // Multiple top-level items (or pre-scan failed) — extract to outDir as normal
    try { await _runTool(exe, ["t", filePath], onProgress: onProgress, timeout: 300); } catch (_) {}
    await _runTool(exe, ["x", "-y", "-o$outDir", filePath],
        onProgress: onProgress);

    // Safety net: flatten if archive created a single same-name subfolder
    await _flattenSameName(outDir);
  }

  /// If outDir contains exactly one subfolder with the same name as outDir itself,
  /// move its contents up and delete it. Fixes "会社/游戏名/游戏名" double-nesting.
  Future<void> _flattenSameName(String outDir) async {
    final dir = Directory(outDir);
    List<FileSystemEntity> entries;
    try { entries = await dir.list().toList(); } catch (_) { return; }
    if (entries.length != 1) return;
    final single = entries.first;
    if (single is! Directory) return;
    final childName = single.uri.pathSegments.last;
    final parentName = outDir.split(Platform.pathSeparator).last;
    if (childName != parentName) return;

    try {
      for (final child in await single.list().toList()) {
        await child.rename("$outDir/${child.uri.pathSegments.last}");
      }
      await single.delete();
    } catch (_) {}
  }

  Future<void> _runTool(String exe, List<String> args,
      {void Function(double)? onProgress, int timeout = 1800}) async {
    final proc = await Process.start(exe, args);
    _extractionProcess = proc;

    // 7z outputs progress (e.g. " 45%") to stderr, not stdout.
    // Parse stderr for both progress and error messages.
    final stderrChunks = <int>[];
    final stderrSub = proc.stderr.listen((d) {
      if (stderrChunks.length < 8192) stderrChunks.addAll(d);
      if (onProgress != null) {
        final s = String.fromCharCodes(d);
        final m = RegExp(r'\s+(\d+)%').firstMatch(s);
        if (m != null) {
          onProgress(int.parse(m.group(1)!) / 100.0);
        }
      }
    });
    // Drain stdout (file listing, not useful for progress)
    final stdoutSub = proc.stdout.listen((_) {});

    // Wait with timeout
    int exitCode = -1;
    try {
      exitCode = await proc.exitCode.timeout(Duration(seconds: timeout));
    } on TimeoutException {
      proc.kill();
      await stdoutSub.cancel();
      await stderrSub.cancel();
      _extractionProcess = null;
      throw Exception("超时（${timeout}s）");
    } catch (e) {
      proc.kill();
      throw Exception("$e");
    }

    await stdoutSub.cancel();
    await stderrSub.cancel();
    _extractionProcess = null;

    if (exitCode != 0) {
      final err = String.fromCharCodes(stderrChunks).trim();
      throw Exception(err.isNotEmpty ? err : "exit code $exitCode");
    }
  }

  // ── helpers ──

  String _outDir(DownloadTask t, String dir) {
    final sub = t.companyName.isNotEmpty ? t.companyName : "_unknown";
    final game = t.gameName.isNotEmpty ? t.gameName : t.fileName;
    return "$dir/$sub/$game";
  }

  bool _stopped(DownloadTask t) => t._cancelled || t.status == "paused";

  void _setStatus(DownloadTask t, String s) { t.status = s; _emit(); }

  void _killExtractor() {
    _extractionProcess?.kill();
    _extractionProcess = null;
  }

  Future<void> _cleanupTemp(DownloadTask t) async {
    try {
      final dir = await downloadDir;
      await File("$dir/.tmp_${t.versionId}_${t.fileName}").delete();
    } catch (_) {}
  }

  void _emit() => _controller.add(List.unmodifiable(_tasks));
}
