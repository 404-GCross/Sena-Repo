/// Download service — stream download with progress + 7z extraction.
/// Windows: 7z.exe + 7z.dll (x64, full format support incl. RAR)
/// Linux:   7zz (standalone x64)
///
/// Flow: download(tmp) → validate(disk size) → extract

import "dart:async";
import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart" show debugPrint;
import "package:flutter/services.dart" show rootBundle;
import "package:flutter/widgets.dart" show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import "../services/logger_service.dart";
import "package:http/http.dart" as http;
import "package:path_provider/path_provider.dart";
import "package:shared_preferences/shared_preferences.dart";

import "notification_service.dart";

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
  int speedBytesPerSecond = 0;
  String? error;
  String? outputPath;
  final DateTime startedAt;
  http.Client? _client;
  bool _cancelled = false;
  bool needsPassword = false;
  bool isApk = false;
  String? coverUrl;
  String? bgUrl;
  int _lastBytes = 0;
  DateTime _lastSpeedTime = DateTime.now();

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

class DownloadService with WidgetsBindingObserver {
  static final DownloadService _instance = DownloadService._();
  factory DownloadService() => _instance;
  DownloadService._() {
    _restoreTasks();
  }

  bool _lifecycleInitialized = false;

  /// Call this once at app startup to enable auto-pause on lock screen (Android).
  void initLifecycle() {
    if (_lifecycleInitialized) return;
    _lifecycleInitialized = true;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Platform.isAndroid) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      // App going to background / lock screen — pause all active downloads
      for (final t in _tasks) {
        if (t.status == "downloading" || t.status == "retrying" || t.status == "extracting") {
          pauseTask(t);
        }
      }
    } else if (state == AppLifecycleState.resumed) {
      // App back to foreground — resume paused downloads
      for (final t in _tasks) {
        if (t.status == "paused") {
          resumeTask(t);
        }
      }
    }
  }

  Future<void> _restoreTasks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getStringList("saved_tasks") ?? [];
      for (final json in data) {
        final m = Map<String, dynamic>.from(
            const JsonDecoder().convert(json) as Map);
        final task = DownloadTask(
          gameId: m["gameId"] ?? 0,
          versionId: m["versionId"] ?? 0,
          fileName: m["fileName"] ?? "",
          downloadUrl: m["downloadUrl"] ?? "",
          gameName: m["gameName"] ?? "",
          companyName: m["companyName"] ?? "",
        )
          ..status = m["status"] ?? "failed"
          ..receivedBytes = m["receivedBytes"] ?? 0
          ..totalBytes = m["totalBytes"] ?? 0
          ..progress = (m["progress"] ?? 0).toDouble()
          ..error = m["error"]
          ..outputPath = m["outputPath"];
        _tasks.add(task);
        // Re-run active tasks
        if (task.status == "downloading" || task.status == "pending" ||
            task.status == "retrying" || task.status == "extracting") {
          task.status = "pending";
          _run(task);
        }
      }
      if (_tasks.isNotEmpty) _emit();
    } catch (_) {}
  }

  Future<void> _saveTasks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = _tasks
          .where((t) => t.status != "done" && t.status != "cancelled")
          .map((t) => const JsonEncoder().convert({
                "gameId": t.gameId,
                "versionId": t.versionId,
                "fileName": t.fileName,
                "downloadUrl": t.downloadUrl,
                "gameName": t.gameName,
                "companyName": t.companyName,
                "status": t.status,
                "receivedBytes": t.receivedBytes,
                "totalBytes": t.totalBytes,
                "progress": t.progress,
                "error": t.error,
                "outputPath": t.outputPath,
              }))
          .toList();
      await prefs.setStringList("saved_tasks", data);
    } catch (_) {}
  }

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

  // ── storage permission (Android) ──

  bool needsStoragePermission(String path) {
    if (!Platform.isAndroid) return false;
    final extPaths = ["/storage/emulated/0/", "/sdcard/", "/mnt/sdcard/"];
    return extPaths.any((p) => path.startsWith(p));
  }

  Future<bool> checkStoragePermissionGranted() async {
    if (!Platform.isAndroid) return true;
    try {
      final dir = await downloadDir;
      await Directory(dir).create(recursive: true);
      final result = await Process.run("sh", ["-c", "echo 1 > '$dir/.sena_perm_test' 2>/dev/null && rm '$dir/.sena_perm_test' && echo ok"]);
      return result.exitCode == 0 && result.stdout.toString().contains("ok");
    } catch (_) {}
    return false;
  }

  Future<void> openStoragePermissionSettings() async {
    if (!Platform.isAndroid) return;
    const pkg = "com.github.senarepo";
    try {
      await Process.run("sh", ["-c", "am start -a android.settings.MANAGE_APP_ALL_FILES_ACCESS_PERMISSION -d 'package:$pkg'"]);
    } catch (_) {
      try {
        await Process.run("sh", ["-c", "am start -a android.settings.APPLICATION_DETAILS_SETTINGS -d 'package:$pkg'"]);
      } catch (_) {}
    }
  }

  // ── Patch download (reuses the same pipeline as game downloads) ──

  /// Download a patch file to temp, extract to installDir, return (error, outputDir) tuple.
  /// [onProgress] receives (progress 0-1, receivedBytes, totalBytes, speed).
  Future<(String?, String?)> downloadPatch({
    required String appId,
    required String downloadUrl,
    required String patchFilename,
    required String installDir,
    String? patchDir,
    String? targetDir,
    void Function(double progress, int received, int total, int speed)? onProgress,
  }) async {
    final dir = await downloadDir;
    final ext = patchFilename.contains(".") ? patchFilename.substring(patchFilename.lastIndexOf(".")) : "";
    final tmp = File("$dir/.patch_${appId}$ext");
    try {
      // Download via proven stream pipeline
      final task = DownloadTask(
        gameId: appId.hashCode, versionId: appId.hashCode,
        fileName: patchFilename, downloadUrl: downloadUrl,
        gameName: "Steam Patch", companyName: "Steam",
      );
      // Listen to task progress
      StreamSubscription<List<DownloadTask>>? sub;
      if (onProgress != null) {
        sub = _controller.stream.listen((_) {
          onProgress(task.progress, task.receivedBytes, task.totalBytes, task.speedBytesPerSecond);
        });
      }
      try {
        await _download(task, tmp);
      } finally {
        await sub?.cancel();
      }
      if (task.status == "failed" || task.status == "paused") return (task.error ?? "下载失败", null);

      // Resolve target directory
      String destDir = installDir;
      if (targetDir != null && targetDir.isNotEmpty) {
        destDir = "$installDir${Platform.pathSeparator}$targetDir";
      }
      await Directory(destDir).create(recursive: true);

      final exe = await _getSevenZipPath();
      if ((patchDir == null || patchDir.isEmpty) && (targetDir == null || targetDir.isEmpty)) {
        // No custom paths — extract directly to destination
        await _runTool(exe, ["x", "-y", "-o$destDir", tmp.path], timeout: 1800);
      } else {
        // Custom patchDir → extract to temp, resolve, merge to dest
        final tmpExtract = "$dir/.patch_ext_${appId}_${DateTime.now().millisecondsSinceEpoch}";
        await Directory(tmpExtract).create(recursive: true);
        await _runTool(exe, ["x", "-y", "-o$tmpExtract", tmp.path], timeout: 1800);
        String sourceDir = tmpExtract;
        if (patchDir != null && patchDir.isNotEmpty) {
          final pd = "$tmpExtract${Platform.pathSeparator}$patchDir";
          if (await Directory(pd).exists()) sourceDir = pd;
        } else {
          final entries = Directory(tmpExtract).listSync();
          if (entries.length == 1 && entries.first is Directory) sourceDir = entries.first.path;
        }
        await _copyMerge2(sourceDir, destDir);
        await Directory(tmpExtract).delete(recursive: true);
      }
      try { await tmp.delete(); } catch (_) {}
      return (null, destDir); // success
    } catch (e) {
      try { await tmp.delete(); } catch (_) {}
      return ("$e", null);
    }
  }

  /// Recursive copy/merge, overwriting existing files.
  Future<void> _copyMerge2(String from, String to) async {
    await Directory(to).create(recursive: true);
    await for (final child in Directory(from).list()) {
      final name = child.uri.pathSegments.last;
      if (child is Directory) {
        await _copyMerge2(child.path, "$to${Platform.pathSeparator}$name");
      } else if (child is File) {
        try { await child.copy("$to${Platform.pathSeparator}$name"); } catch (_) {}
      }
    }
  }

  // ── public API ──

  DownloadTask startDownload({
    required int gameId,
    required int versionId,
    required String fileName,
    required String downloadUrl,
    required String gameName,
    required String companyName,
    String? coverUrl,
    String? bgUrl,
  }) {
    final task = DownloadTask(
      gameId: gameId, versionId: versionId, fileName: fileName,
      downloadUrl: downloadUrl, gameName: gameName, companyName: companyName,
    )
      ..coverUrl = coverUrl
      ..bgUrl = bgUrl;
    _tasks.insert(0, task);
    _emit();
    _run(task);
    return task;
  }

  void pauseTask(DownloadTask task) async {
    if (task.status == "downloading" || task.status == "retrying") {
      // Save state BEFORE closing client
      final received = task.receivedBytes;
      final total = task.totalBytes;
      task._client?.close();
      task._client = null;
      task.status = "paused";
      // Persist byte counts to a dedicated key for safe resume
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt("resume_${task.gameId}_${task.versionId}", received);
      await prefs.setInt("resume_total_${task.gameId}_${task.versionId}", total);
      _saveTasks();
      _emit();
    } else if (task.status == "extracting") {
      _killExtractor();
      task.status = "paused";
      _emit();
    }
  }

  void resumeTask(DownloadTask task) async {
    if (task.status == "paused") {
      // Restore byte counts from dedicated key if live object lost them
      if (task.receivedBytes == 0) {
        final prefs = await SharedPreferences.getInstance();
        final r = prefs.getInt("resume_${task.gameId}_${task.versionId}");
        final t = prefs.getInt("resume_total_${task.gameId}_${task.versionId}");
        if (r != null && r > 0) task.receivedBytes = r;
        if (t != null && t > 0) task.totalBytes = t;
      }
      task.status = "pending";
      _emit();
      _run(task);
    }
  }

  void retryTask(DownloadTask task) {
    if (task.status == "failed") {
      task.status = "pending";
      task.error = null;
      task.needsPassword = false;
      task.progress = task.totalBytes > 0 ? task.receivedBytes / task.totalBytes : 0;
      _emit();
      _run(task);
    }
  }

  void retryWithPassword(DownloadTask task, String password) {
    if (task.status == "failed" && task.needsPassword) {
      task.status = "extracting";
      task.error = null;
      task.needsPassword = false;
      _emit();
      _runWithPassword(task, password);
    }
  }

  Future<void> _runWithPassword(DownloadTask t, String password) async {
    final dir = await downloadDir;
    final supportDir = (await getApplicationSupportDirectory()).path;
    final tmp = File("$supportDir/.tmp_${t.versionId}_${t.fileName}");
    final outDir = _outDir(t, dir);
    final gameDir = t.gameName.isNotEmpty ? t.gameName : t.fileName;
    try {
      t._cancelled = false;
      await Directory(outDir).create(recursive: true);
      t.status = "extracting";
      t.progress = 0.0;
      _emit();
      await Future.delayed(const Duration(milliseconds: 100));
      await _extract(tmp.path, outDir, gameDir, null, password);
      await _fixLayout(outDir, gameDir);
      await tmp.delete();
      t.status = "done";
      t.outputPath = outDir;
      _emit();
      NotificationService().showCompleted(id: t.gameId, gameName: t.gameName);
    } catch (e) {
      NotificationService().cancel(t.gameId);
      final errStr = "$e";
      if (_isEncryptedError(errStr)) {
        t.needsPassword = true;
        t.status = "failed";
        t.error = "需要密码";
      } else {
        t.status = "failed";
        t.error = errStr;
      }
      _emit();
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
    } else if (task.status == "failed") {
      task.status = "cancelled";
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
        debugPrint("[SenaRepo] Loading 7zz from assets: assets/binaries/$exeName");
        final data = await rootBundle.load("assets/binaries/$exeName");
        debugPrint("[SenaRepo] 7zz size from assets: ${data.buffer.lengthInBytes} bytes");
        await dest.writeAsBytes(data.buffer.asUint8List());
        // 7z.dll (Windows only — full format support incl. RAR)
        if (Platform.isWindows) {
          try {
            final dll = await rootBundle.load("assets/binaries/7z.dll");
            await File("${dir.path}/7z.dll").writeAsBytes(dll.buffer.asUint8List());
          } catch (_) {}
        }
        if (Platform.isLinux || Platform.isAndroid) {
          try {
            await Process.run(Platform.isAndroid ? "/system/bin/chmod" : "chmod",
              ["+x", dest.path]);
          } catch (_) {}
        }
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
    // Temp file in app internal storage — external storage may delete it
    final supportDir = (await getApplicationSupportDirectory()).path;
    final tmp = File("$supportDir/.tmp_${t.versionId}_${t.fileName}");
    final outDir = _outDir(t, dir);
    final gameDir = t.gameName.isNotEmpty ? t.gameName : t.fileName;
    try {
      t._cancelled = false;
      await Directory(outDir).create(recursive: true);

      // Download + extract with extract-level retry
      const maxExtractRetries = 2;
      for (int retry = 0; retry <= maxExtractRetries; retry++) {
        if (t._cancelled) { try { LoggerService().warn("DELETING temp file: $tmp"); await tmp.delete(); } catch (_) {} return; }
        if (t.status == "paused") return;

        // Phase 1: download
        t.status = "downloading";
        _emit();
        NotificationService().showDownloadProgress(
          id: t.gameId, gameName: t.gameName,
          progress: 0, receivedBytes: 0, totalBytes: t.totalBytes);
        await _download(t, tmp);
        if (t._cancelled) { try { LoggerService().warn("DELETING temp file: $tmp"); await tmp.delete(); } catch (_) {} return; }
        if (t.status == "paused") return;

        // Check if APK — move to output dir, skip extraction
        if (t.fileName.toLowerCase().endsWith(".apk")) {
          t.isApk = true;
          final apkFile = File("$outDir/${t.fileName}");
          try { await apkFile.parent.create(recursive: true); } catch (_) {}
          try { await tmp.rename(apkFile.path); } catch (e) {
            try { await tmp.copy(apkFile.path); await tmp.delete(); } catch (_) {
              throw Exception("无法保存 APK 文件: $e");
            }
          }
          t.status = "done";
          t.outputPath = apkFile.path;
          t.progress = 1.0;
          _emit();
          NotificationService().showCompleted(id: t.gameId, gameName: t.gameName);
          return;
        }

        // Phase 2: extract
        t.status = "extracting";
        t.progress = 0.0;
        _emit();
        await Future.delayed(const Duration(milliseconds: 100));
        try {
          await _extract(tmp.path, outDir, gameDir, (p) {
            if (p > t.progress) { t.progress = p; _emit(); }
          });
          t.progress = 1.0;
          _emit();

          await tmp.delete();
          break; // success
        } catch (e) {
          if (t._cancelled) { try { LoggerService().warn("DELETING temp file: $tmp"); await tmp.delete(); } catch (_) {} return; }
          if (t.status == "paused") return;
          // Encrypted or no-extractor error — throw immediately, don't waste retries
          final errStr = "$e";
          if (_isEncryptedError(errStr)) rethrow;
          if (_isExtractorMissingError(errStr)) rethrow;
          if (retry < maxExtractRetries) {
            // Corrupted file — delete and re-download
            try { LoggerService().warn("DELETING temp file: $tmp"); await tmp.delete(); } catch (_) {}
            t.receivedBytes = 0;
            t.totalBytes = 0;
            t.status = "retrying";
            _emit();
            await Future.delayed(const Duration(seconds: 2));
            if (_stopped(t)) return;
            continue;
          }
          rethrow;
        }
      }

      // Phase 3: done
      t.status = "done";
      t.outputPath = outDir;
      _emit();
      NotificationService().showCompleted(id: t.gameId, gameName: t.gameName);
    } catch (e) {
      if (t._cancelled) {
        NotificationService().cancel(t.gameId);
        try { LoggerService().warn("DELETING temp file: $tmp"); await tmp.delete(); } catch (_) {}
        return;
      }
      if (t.status == "paused") return;
      NotificationService().cancel(t.gameId);
      final errStr = "$e";
      // Check if archive is password-protected
      if (_isEncryptedError(errStr)) {
        t.needsPassword = true;
        t.status = "failed";
        t.error = "需要密码";
      } else {
        t.status = "failed";
        t.error = errStr;
      }
      _emit();
    }
  }

  bool _isEncryptedError(String err) {
    final lower = err.toLowerCase();
    return lower.contains("password") ||
        lower.contains("encrypted") ||
        lower.contains("wrong password") ||
        lower.contains("can't open encrypted") ||
        lower.contains("crc error") ||
        lower.contains("crc_error") ||
        lower.contains("data error");
  }

  bool _isExtractorMissingError(String err) {
    final lower = err.toLowerCase();
    return lower.contains("permission denied") ||
        lower.contains("cannot run") ||
        lower.contains("no such file") ||
        lower.contains("解压组件未就绪");
  }

  // ── download ──

  static const _maxRetries = 3;
  static const _retryDelays = [1, 3, 7]; // seconds

  Future<void> _download(DownloadTask t, File dest) async {
    for (int attempt = 0; attempt <= _maxRetries; attempt++) {
      if (_stopped(t)) return;

      // Sync counter with disk
      if (t.receivedBytes > 0) {
        LoggerService().info("Resume: checking dest=${dest.path}");
        if (await dest.exists()) {
          final sz = await dest.length();
          LoggerService().info("Resume: receivedBytes=$t.receivedBytes fileSize=$sz");
          if (sz != t.receivedBytes) t.receivedBytes = sz;
        } else {
          LoggerService().warn("Resume: temp file GONE: ${dest.path}");
          t.receivedBytes = 0;
          t.totalBytes = 0;
        }
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
        if (_stopped(t)) return;
        _setStatus(t, "downloading");
      } on SocketException catch (e) {
        if (_stopped(t)) return;
        if (attempt >= _maxRetries) throw Exception("网络不通（重试${_maxRetries}次后仍失败）: $e");
        _setStatus(t, "retrying");
        await Future.delayed(Duration(seconds: _retryDelays[attempt]));
        if (_stopped(t)) return;
        _setStatus(t, "downloading");
      }
    }
  }

  Future<void> _attempt(DownloadTask t, File dest) async {
    final client = http.Client();
    t._client = client;
    IOSink? sink;
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
      sink = dest.openWrite(
          mode: (resp.statusCode == 206) ? FileMode.append : FileMode.write);

      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        t.receivedBytes = received;
        // Calculate speed every ~1 second
        final now = DateTime.now();
        final elapsed = now.difference(t._lastSpeedTime).inMilliseconds;
        if (elapsed >= 1000) {
          t.speedBytesPerSecond =
              ((received - t._lastBytes) / elapsed * 1000).round();
          t._lastBytes = received;
          t._lastSpeedTime = now;
        }
        if (t.totalBytes > 0) {
          t.progress = received / t.totalBytes;
          _emit();
          NotificationService().showDownloadProgress(
            id: t.gameId, gameName: t.gameName,
            progress: t.progress, receivedBytes: received,
            totalBytes: t.totalBytes);
        }
      }
      // Tell UI we're done downloading before slow disk flush
      t.progress = 1.0;
      _emit();
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
      // Ensure data is flushed to disk before returning
      try { await sink?.flush(); } catch (_) {}
      try { await sink?.close(); } catch (_) {}
      // Small delay for Android filesystem to update metadata
      if (Platform.isAndroid) await Future.delayed(const Duration(milliseconds: 200));
      client.close();
      t._client = null;
      // Sync counter with actual file size (critical for resume)
      try {
        final actualSize = await dest.length();
        if (actualSize > 0) t.receivedBytes = actualSize;
        if (t.totalBytes > 0 && actualSize >= t.totalBytes) t.receivedBytes = t.totalBytes;
      } catch (_) {}
      // Save task state immediately so resume has correct receivedBytes
      if (t.status == "paused") _saveTasks();
    }
  }

  // ── extract (desktop only) ──

  Future<void> _extract(String filePath, String outDir, String gameDir,
      [void Function(double)? onProgress, String? password]) async {
    final String exe;
    try {
      exe = await _getSevenZipPath();
    } catch (e) {
      throw Exception("解压组件未就绪: $e");
    }
    final args = ["x", "-y", "-o$outDir", filePath];
    if (password != null) args.insert(1, "-p$password");
    // Skip integrity test on Android (saves time, verified during extraction)
    if (password == null && !Platform.isAndroid) {
      try { await _runTool(exe, ["t", filePath], onProgress: onProgress, timeout: 300); } catch (_) {}
    }
    debugPrint("[SenaRepo] _extract: exe=$exe args=$args");
    await _runTool(exe, args, onProgress: onProgress,
      timeout: Platform.isAndroid ? 600 : 1800); // Android: 10min timeout
    await _fixLayout(outDir, gameDir);
  }

  /// Ensure clean output: rename archive folder to [gameDir] if different,
  /// or wrap scattered files in [gameDir] folder.
  Future<void> _fixLayout(String outDir, String gameDir) async {
    List<FileSystemEntity> entries;
    try { entries = await Directory(outDir).list().toList(); } catch (_) { return; }
    if (entries.isEmpty) return;

    // One folder = archive had its own wrapper
    if (entries.length == 1 && entries.first is Directory) {
      final folder = entries.first as Directory;
      final folderName = folder.uri.pathSegments.last;
      // Rename to match game name if different
      if (folderName != gameDir) {
        final target = "$outDir/$gameDir";
        try {
          await folder.rename(target);
        } catch (_) {
          // rename failed (target exists or locked) → copy + delete
          try {
            await _copyMerge(folder.path, target);
            await folder.delete(recursive: true);
          } catch (_) {}
        }
      }
      return;
    }

    // Multiple items = archive has no wrapper → create game folder and move in
    if (entries.any((e) => e is Directory && e.uri.pathSegments.last == gameDir)) return;

    final wrap = "$outDir/$gameDir";
    try {
      await Directory(wrap).create();
      for (final e in entries) {
        try { await e.rename("$wrap/${e.uri.pathSegments.last}"); } catch (_) {}
      }
    } catch (_) {}
  }

  /// Recursively copy/merge contents of [from] directory into [to] directory.
  Future<void> _copyMerge(String from, String to) async {
    final target = Directory(to);
    if (!await target.exists()) await target.create(recursive: true);
    await for (final child in Directory(from).list()) {
      final name = child.uri.pathSegments.last;
      if (child is Directory) {
        await _copyMerge(child.path, "$to/$name");
      } else if (child is File) {
        // Overwrite if exists
        try { await child.copy("$to/$name"); } catch (_) {}
      }
    }
  }

  Future<void> _runTool(String exe, List<String> args,
      {void Function(double)? onProgress, int timeout = 1800}) async {
    // Android: bypass noexec by using dynamic linker to load the ELF
    if (Platform.isAndroid) {
      args = [exe, ...args];
      exe = "/system/bin/linker64";
    }
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
    // Extract directly to 会社/, letting archive folder name be the game folder
    return "$dir/$sub";
  }

  bool _stopped(DownloadTask t) => t._cancelled || t.status == "paused";

  void _setStatus(DownloadTask t, String s) { t.status = s; _emit(); }

  void _killExtractor() {
    _extractionProcess?.kill();
    _extractionProcess = null;
  }

  Future<void> _cleanupTemp(DownloadTask t) async {
    try {
      final supportDir = (await getApplicationSupportDirectory()).path;
      await File("$supportDir/.tmp_${t.versionId}_${t.fileName}").delete();
    } catch (_) {}
  }

  void _emit() {
    _controller.add(List.unmodifiable(_tasks));
    _saveTasks();
  }
}
