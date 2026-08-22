/// Download service — stream download with progress + 7z extraction.
/// Windows: 7z.exe + 7z.dll (x64, full format support incl. RAR)
/// Linux:   7zz (standalone x64)
///
/// Flow: download(tmp) → validate(disk size) → extract

import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:flutter/services.dart" show MethodChannel, rootBundle;
import "package:flutter/widgets.dart"
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import "../services/logger_service.dart";
import "logged_http.dart" as http;
import "package:path_provider/path_provider.dart";
import "package:shared_preferences/shared_preferences.dart";

import "package:permission_handler/permission_handler.dart";
import "api_client.dart" show ApiClient, globalToken;
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

  String
  status; // pending, downloading, retrying, extracting, done, failed, paused, cancelled
  double progress;
  int receivedBytes;
  int totalBytes;
  int speedBytesPerSecond = 0;
  String? error;
  String? outputPath;
  final DateTime startedAt;
  http.Client? _client;
  bool _cancelled = false;
  bool headersReceived = false;
  bool needsPassword = false;
  bool isApk = false;
  String? coverUrl;
  String? bgUrl;
  String? extractPassword;
  final List<http.Client> _clients = <http.Client>[];
  bool _triedPresetPassword = false;
  int _lastBytes = 0;
  DateTime _lastSpeedTime = DateTime.now();
  DateTime _lastNotifyTime = DateTime.now();

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
    "extractPassword": extractPassword,
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

  static const _foregroundChannel = MethodChannel(
    "com.github.senarepo/foreground",
  );

  Future<void> _startForegroundService() async {
    if (!Platform.isAndroid) return;
    try {
      await _foregroundChannel.invokeMethod("start");
    } catch (_) {}
  }

  Future<void> _stopForegroundService() async {
    if (!Platform.isAndroid) return;
    try {
      await _foregroundChannel.invokeMethod("stop");
    } catch (_) {}
  }

  bool _hasActiveDownloads() {
    return _tasks.any(
      (t) =>
          t.status == "downloading" ||
          t.status == "retrying" ||
          t.status == "extracting" ||
          t.status == "pending",
    );
  }

  void _onDownloadStarted() => _startForegroundService();

  void _onDownloadEnded() {
    if (!_hasActiveDownloads()) _stopForegroundService();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Background downloads continue via foreground service — no auto-pause
  }

  Future<void> _restoreTasks() async {
    try {
      await ApiClient.restoreToken();
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getStringList("saved_tasks") ?? [];
      for (final json in data) {
        final m = Map<String, dynamic>.from(
          const JsonDecoder().convert(json) as Map,
        );
        final task =
            DownloadTask(
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
              ..extractPassword = m["extractPassword"]
              ..outputPath = m["outputPath"];
        _tasks.add(task);
        // Re-run active tasks
        if (task.status == "downloading" ||
            task.status == "pending" ||
            task.status == "retrying" ||
            task.status == "extracting") {
          task.status = "pending";
        }
      }
      if (_tasks.isNotEmpty) _emit();
      _scheduleDownloads();
    } catch (_) {}
  }

  Future<void> _saveTasks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = _tasks
          .where((t) => t.status != "done" && t.status != "cancelled")
          .map(
            (t) => const JsonEncoder().convert({
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
            }),
          )
          .toList();
      await prefs.setStringList("saved_tasks", data);
    } catch (_) {}
  }

  final List<DownloadTask> _tasks = [];
  final Set<DownloadTask> _runningTasks = <DownloadTask>{};
  final _controller = StreamController<List<DownloadTask>>.broadcast();
  int? _maxConcurrentDownloads;
  int? _downloadSpeedLimitKbps;
  bool _schedulingDownloads = false;
  DateTime _speedWindowStart = DateTime.now();
  int _speedWindowBytes = 0;

  // ── patch injection tracking (static so SteamService cross-instance access works) ──
  static final Map<String, _PatchInjection> _patchInjections = {};

  void cancelPatchInjection(String appId) {
    final inj = _patchInjections[appId];
    if (inj == null) return;
    inj.cancelled = true;
    inj.paused = false;
    _closeTaskClients(inj.task);
    inj.extractProcess?.kill();
    inj.extractProcess = null;
    // Also kill via instance-level _extractionProcess in case _runTool is mid-flight
    _killExtractor();
    inj.task._cancelled = true;
    inj.task.status = "cancelled";
    inj.task.error = "已取消";
    unawaited(_deleteFileQuietly(inj.tempPath));
    _patchInjections.remove(appId);
    _emit();
  }

  void pausePatchInjection(String appId) {
    final inj = _patchInjections[appId];
    if (inj == null) return;
    inj.paused = true;
    if (inj.task.status == "downloading" ||
        inj.task.status == "retrying" ||
        inj.task.status == "pending") {
      _closeTaskClients(inj.task);
    } else if (inj.task.status == "extracting") {
      inj.extractProcess?.kill();
      inj.extractProcess = null;
      _killExtractor();
    }
    inj.task.status = "paused";
    _emit();
  }

  Stream<List<DownloadTask>> get tasks => _controller.stream;
  List<DownloadTask> get currentTasks => List.unmodifiable(_tasks);

  // ── download directory ──

  String? _downloadDir;
  Future<String> get downloadDir async {
    if (_downloadDir != null) return _downloadDir!;
    final prefs = await SharedPreferences.getInstance();
    _downloadDir =
        prefs.getString("local_download_dir") ??
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

  Future<int> get maxConcurrentDownloads async {
    if (_maxConcurrentDownloads != null) return _maxConcurrentDownloads!;
    final prefs = await SharedPreferences.getInstance();
    _maxConcurrentDownloads = (prefs.getInt("max_concurrent_downloads") ?? 3)
        .clamp(1, 10)
        .toInt();
    return _maxConcurrentDownloads!;
  }

  Future<void> setMaxConcurrentDownloads(int value) async {
    final normalized = value.clamp(1, 10).toInt();
    _maxConcurrentDownloads = normalized;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt("max_concurrent_downloads", normalized);
    _scheduleDownloads();
  }

  Future<int> get downloadSpeedLimitKbps async {
    if (_downloadSpeedLimitKbps != null) return _downloadSpeedLimitKbps!;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt("download_speed_limit_kbps") ?? 0;
    _downloadSpeedLimitKbps = saved < 0 ? 0 : saved;
    return _downloadSpeedLimitKbps!;
  }

  Future<void> setDownloadSpeedLimitKbps(int value) async {
    _downloadSpeedLimitKbps = value < 0 ? 0 : value;
    _speedWindowStart = DateTime.now();
    _speedWindowBytes = 0;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt("download_speed_limit_kbps", _downloadSpeedLimitKbps!);
  }

  Future<void> _scheduleDownloads() async {
    if (_schedulingDownloads) return;
    _schedulingDownloads = true;
    try {
      final maxActive = await maxConcurrentDownloads;
      while (_runningTasks.length < maxActive) {
        DownloadTask? next;
        for (final task in _tasks) {
          if (task.status == "pending" && !_runningTasks.contains(task)) {
            next = task;
            break;
          }
        }
        if (next == null) break;
        _runningTasks.add(next);
        _run(next);
      }
    } finally {
      _schedulingDownloads = false;
    }
  }

  // ── storage permission (Android) ──

  bool needsStoragePermission(String path) {
    if (!Platform.isAndroid) return false;
    final extPaths = ["/storage/emulated/0/", "/sdcard/", "/mnt/sdcard/"];
    return extPaths.any((p) => path.startsWith(p));
  }

  Future<bool> checkStoragePermissionGranted() async {
    if (!Platform.isAndroid) return true;
    return await Permission.manageExternalStorage.isGranted;
  }

  Future<void> openStoragePermissionSettings() async {
    if (!Platform.isAndroid) return;
    await Permission.manageExternalStorage.request();
  }

  // ── Patch download (reuses the same pipeline as game downloads) ──

  /// Download a patch file to temp, extract to installDir, return (error, outputDir) tuple.
  /// [onProgress] receives (progress 0-1, receivedBytes, totalBytes, speed, stage).
  /// Patch injection can be cancelled/paused via [cancelPatchInjection]/[pausePatchInjection].
  Future<(String?, String?)> downloadPatch({
    required String appId,
    required String downloadUrl,
    required String patchFilename,
    required String installDir,
    String? patchDir,
    String? targetDir,
    void Function(
      double progress,
      int received,
      int total,
      int speed,
      String stage,
    )?
    onProgress,
  }) async {
    final dir = await downloadDir;
    final safeAppId = appId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), "_");
    final ext = patchFilename.contains(".")
        ? patchFilename.substring(patchFilename.lastIndexOf("."))
        : "";
    final tmpPath = "${dir}${Platform.pathSeparator}.patch_$safeAppId$ext";
    final tmp = File(tmpPath);
    // Track injection state for cross-instance cancellation
    final task = DownloadTask(
      gameId: appId.hashCode,
      versionId: appId.hashCode,
      fileName: patchFilename,
      downloadUrl: downloadUrl,
      gameName: "Steam Patch",
      companyName: "Steam",
    );
    final inj = _PatchInjection(task: task, tempPath: tmpPath);
    _patchInjections[appId] = inj;
    try {
      // Download via proven stream pipeline
      StreamSubscription<List<DownloadTask>>? sub;
      if (onProgress != null) {
        sub = _controller.stream.listen((_) {
          onProgress(
            task.progress,
            task.receivedBytes,
            task.totalBytes,
            task.speedBytesPerSecond,
            task.status,
          );
        });
      }
      // Restore partial download from paused state so Range resume works
      if (await tmp.exists()) {
        final existingSize = await tmp.length();
        if (existingSize > 0) task.receivedBytes = existingSize;
      }
      try {
        task.status = "downloading";
        await _download(task, tmp);
      } finally {
        await sub?.cancel();
      }
      if (_stopped(task)) {
        if (task.status != "paused") {
          try {
            await tmp.delete();
          } catch (_) {}
        }
        return (task.status == "paused" ? "已暂停" : "已取消", null);
      }
      if (task.status == "failed") return (task.error ?? "下载失败", null);

      // Resolve target directory
      String destDir = installDir;
      if (targetDir != null && targetDir.isNotEmpty) {
        try {
          destDir = _resolveSafeRelativePath(installDir, targetDir);
        } catch (e) {
          return ("补丁目标目录非法: $targetDir", null);
        }
      }
      await Directory(destDir).create(recursive: true);

      final exe = await _getSevenZipPath();
      task.status = "extracting";
      if (onProgress != null) onProgress(-1, 0, 0, 0, "extracting");

      if ((patchDir == null || patchDir.isEmpty) &&
          (targetDir == null || targetDir.isEmpty)) {
        LoggerService().info(
          "patch extract: $exe x -y -p- -o$destDir ${tmp.path}",
        );
        await _runTool(
          exe,
          ["x", "-y", "-p-", "-o$destDir", tmp.path],
          timeout: 1800,
          injectionAppId: appId,
          onProgress: (p) {
            if (onProgress != null) onProgress(p, 0, 0, 0, "extracting");
          },
        );
        if (_stopped(task)) {
          if (task.status != "paused") {
            try {
              await tmp.delete();
            } catch (_) {}
          }
          return (task.status == "paused" ? "已暂停" : "已取消", null);
        }
        LoggerService().info("patch extract done: $destDir");
      } else {
        final tmpExtract =
            "${dir}${Platform.pathSeparator}.patch_ext_${safeAppId}_${DateTime.now().millisecondsSinceEpoch}";
        LoggerService().info(
          "patch extract: $exe x -y -p- -o$tmpExtract ${tmp.path}",
        );
        await Directory(tmpExtract).create(recursive: true);
        await _runTool(
          exe,
          ["x", "-y", "-p-", "-o$tmpExtract", tmp.path],
          timeout: 1800,
          injectionAppId: appId,
          onProgress: (p) {
            if (onProgress != null) onProgress(p, 0, 0, 0, "extracting");
          },
        );
        if (_stopped(task)) {
          try {
            await Directory(tmpExtract).delete(recursive: true);
          } catch (_) {}
          if (task.status != "paused") {
            try {
              await tmp.delete();
            } catch (_) {}
          }
          return (task.status == "paused" ? "已暂停" : "已取消", null);
        }
        LoggerService().info(
          "patch extract done: tmp=$tmpExtract patchDir=$patchDir targetDir=$targetDir destDir=$destDir",
        );
        String sourceDir = tmpExtract;
        if (patchDir != null && patchDir.isNotEmpty) {
          String pd;
          try {
            pd = _resolveSafeRelativePath(tmpExtract, patchDir);
          } catch (e) {
            try {
              await Directory(tmpExtract).delete(recursive: true);
            } catch (_) {}
            return ("补丁源目录非法: $patchDir", null);
          }
          LoggerService().info("patch resolve: looking for $pd");
          if (await Directory(pd).exists()) {
            sourceDir = pd;
          } else {
            try {
              await Directory(tmpExtract).delete(recursive: true);
            } catch (_) {}
            return ("补丁源目录不存在: $patchDir（请检查压缩包内容）", null);
          }
        } else {
          final entries = Directory(tmpExtract).listSync();
          if (entries.length == 1 && entries.first is Directory)
            sourceDir = entries.first.path;
        }
        LoggerService().info("patch merge: $sourceDir -> $destDir");
        await _copyMerge(sourceDir, destDir);
        LoggerService().info("patch merge done");
        await Directory(tmpExtract).delete(recursive: true);
      }
      if (_stopped(task)) {
        if (task.status != "paused") {
          try {
            await tmp.delete();
          } catch (_) {}
        }
        return (task.status == "paused" ? "已暂停" : "已取消", null);
      }
      try {
        await tmp.delete();
      } catch (_) {}
      return (null, destDir);
    } catch (e) {
      if (_stopped(task)) {
        if (task.status != "paused") {
          try {
            await tmp.delete();
          } catch (_) {}
        }
        return (task.status == "paused" ? "已暂停" : "已取消", null);
      }
      try {
        await tmp.delete();
      } catch (_) {}
      return ("$e", null);
    } finally {
      _patchInjections.remove(appId);
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
    String? extractPassword,
  }) {
    final task =
        DownloadTask(
            gameId: gameId,
            versionId: versionId,
            fileName: fileName,
            downloadUrl: downloadUrl,
            gameName: gameName,
            companyName: companyName,
          )
          ..coverUrl = coverUrl
          ..bgUrl = bgUrl
          ..extractPassword = extractPassword;
    task.headersReceived = false;
    _tasks.insert(0, task);
    _emit();
    _scheduleDownloads();
    return task;
  }

  void pauseTask(DownloadTask task) async {
    if (task.status == "downloading" || task.status == "retrying") {
      // Save state BEFORE closing client
      final received = task.receivedBytes;
      final total = task.totalBytes;
      _closeTaskClients(task);
      task.status = "paused";
      // Persist byte counts to a dedicated key for safe resume
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt("resume_${task.gameId}_${task.versionId}", received);
      await prefs.setInt(
        "resume_total_${task.gameId}_${task.versionId}",
        total,
      );
      _saveTasks();
      _runningTasks.remove(task);
      _emit();
      _scheduleDownloads();
    } else if (task.status == "extracting") {
      _killExtractor();
      task.status = "paused";
      _runningTasks.remove(task);
      _emit();
      _scheduleDownloads();
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
      _scheduleDownloads();
    }
  }

  void retryTask(DownloadTask task) {
    if (task.status == "failed") {
      task.status = "pending";
      task.error = null;
      task.needsPassword = false;
      task.headersReceived = false;
      task._triedPresetPassword = false;
      task.progress = task.totalBytes > 0
          ? task.receivedBytes / task.totalBytes
          : 0;
      _emit();
      _scheduleDownloads();
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
    final tmp = File(
      "$supportDir/.tmp_${t.versionId}_${_safeName(t.fileName)}",
    );
    final outDir = _outDir(t, dir);
    final gameDir = t.gameName.isNotEmpty ? t.gameName : _safeName(t.fileName);
    try {
      t._cancelled = false;
      await Directory(outDir).create(recursive: true);
      t.status = "extracting";
      t.progress = 0.0;
      _emit();
      await Future.delayed(const Duration(milliseconds: 100));
      if (t._cancelled || t.status == "cancelled") return;
      await _extract(tmp.path, outDir, gameDir, null, password);
      await _fixLayout(outDir, gameDir);
      await tmp.delete();
      t.status = "done";
      t.outputPath = "${outDir}${Platform.pathSeparator}$gameDir";
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
    if (task.status == "downloading" ||
        task.status == "pending" ||
        task.status == "retrying" ||
        task.status == "extracting" ||
        task.status == "paused") {
      _closeTaskClients(task);
      _killExtractor();
      task._cancelled = true;
      task.status = "cancelled";
      task.error = "已取消";
      NotificationService().cancel(task.gameId);
      _runningTasks.remove(task);
      _emit();
      _cleanupTemp(task);
      _scheduleDownloads();
    } else if (task.status == "failed") {
      task.status = "cancelled";
      NotificationService().cancel(task.gameId);
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
      final r = await Process.run(
        Platform.isAndroid ? "/system/bin/linker64" : path,
        Platform.isAndroid ? [path] : [],
      ).timeout(const Duration(seconds: 3));
      final m = RegExp(r'(\d+)\.(\d+)').firstMatch("${r.stdout}${r.stderr}");
      if (m != null) {
        return int.parse(m.group(1)!) * 100 + int.parse(m.group(2)!);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<String> _getSevenZipPath() async {
    if (_sevenZipPath != null) return _sevenZipPath!;

    final dir = await getApplicationSupportDirectory();
    final exeName = Platform.isWindows ? "7z.exe" : "7zz";
    final dest = File("${dir.path}/$exeName");

    // Replace old binary (<16.00) or old 7za.exe
    if (await dest.exists()) {
      final v = await _get7zaVersion(dest.path);
      if (v == null || v < _min7zaVersion) {
        LoggerService().warn(
          "Bundled 7zz cache invalid; replacing from assets: version=${v ?? "unknown"}",
        );
        try {
          await dest.delete();
        } catch (_) {}
        try {
          await File("${dir.path}/7z.dll").delete();
        } catch (_) {}
      }
      // Also clean up old 7za from previous versions
      try {
        await File("${dir.path}/7za.exe").delete();
      } catch (_) {}
      try {
        await File("${dir.path}/7za.dll").delete();
      } catch (_) {}
    }

    if (!await dest.exists()) {
      // Extract from bundled assets
      bool ok = false;
      try {
        LoggerService().info(
          "Loading 7zz from assets: assets/binaries/$exeName",
        );
        final data = await rootBundle.load("assets/binaries/$exeName");
        LoggerService().info(
          "7zz size from assets: ${data.buffer.lengthInBytes} bytes",
        );
        await dest.writeAsBytes(data.buffer.asUint8List());
        // 7z.dll (Windows only — full format support incl. RAR)
        if (Platform.isWindows) {
          try {
            final dll = await rootBundle.load("assets/binaries/7z.dll");
            await File(
              "${dir.path}/7z.dll",
            ).writeAsBytes(dll.buffer.asUint8List());
          } catch (_) {}
        }
        if (Platform.isLinux || Platform.isAndroid) {
          try {
            await Process.run(
              Platform.isAndroid ? "/system/bin/chmod" : "chmod",
              ["+x", dest.path],
            );
          } catch (_) {}
        }
        final version = await _get7zaVersion(dest.path);
        if (version == null || version < _min7zaVersion) {
          throw Exception("解压组件校验失败");
        }
        if (await dest.exists()) ok = true;
      } catch (e, stackTrace) {
        LoggerService().warn("Bundled 7zz setup failed", e, stackTrace);
        try {
          await dest.delete();
        } catch (_) {}
      }

      if (!ok && Platform.isAndroid) {
        throw Exception("解压组件校验失败，请重新安装应用");
      }

      if (!ok && Platform.isLinux) {
        final systemExe = await _findSystemSevenZip();
        if (systemExe != null) {
          LoggerService().info("Using system 7-Zip: $systemExe");
          _sevenZipPath = systemExe;
          return _sevenZipPath!;
        }
      }

      // Download fallback
      if (!ok &&
          !Platform.isAndroid &&
          onSetupNeeded != null &&
          !_userSkippedSetup) {
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

  Future<String?> _findSystemSevenZip() async {
    for (final name in ["7zz", "7z"]) {
      final version = await _get7zaVersion(name);
      if (version != null && version >= _min7zaVersion) return name;
    }
    return null;
  }

  Future<void> _downloadBinary(File dest, String dir) async {
    if (Platform.isWindows) {
      // Download installer, run silently, copy 7z.exe + 7z.dll
      final tmp = File("$dir/_7z_installer.exe");
      final client = http.Client();
      try {
        final resp = await client.send(
          http.Request(
            "GET",
            Uri.parse("https://www.7-zip.org/a/7z2601-x64.exe"),
          ),
        );
        if (resp.statusCode != 200) throw Exception("HTTP ${resp.statusCode}");
        final sink = tmp.openWrite();
        await for (final c in resp.stream) sink.add(c);
        await sink.flush();
        await sink.close();
        await Process.run(tmp.path, ["/S"]);
        for (final d in [
          "C:/Program Files/7-Zip",
          r"C:\Program Files (x86)\7-Zip",
        ]) {
          final src = File("$d/7z.exe");
          if (await src.exists()) {
            await src.copy(dest.path);
            try {
              await File("$d/7z.dll").copy("${dir}/7z.dll");
            } catch (_) {}
            break;
          }
        }
        await tmp.delete();
      } finally {
        client.close();
      }
    } else {
      // Linux: extract from tar.xz
      final tmp = File("$dir/_7z_dl");
      final client = http.Client();
      try {
        final resp = await client.send(
          http.Request(
            "GET",
            Uri.parse("https://www.7-zip.org/a/7z2409-linux-x64.tar.xz"),
          ),
        );
        if (resp.statusCode != 200) throw Exception("HTTP ${resp.statusCode}");
        final sink = tmp.openWrite();
        await for (final c in resp.stream) sink.add(c);
        await sink.close();
        await Process.run("tar", ["-xf", tmp.path, "-C", dir]);
        await tmp.delete();
      } finally {
        client.close();
      }
    }
  }

  // ── core run loop ──

  Future<void> _run(DownloadTask t) async {
    final dir = await downloadDir;
    // Temp file in app internal storage — external storage may delete it
    final supportDir = (await getApplicationSupportDirectory()).path;
    final tmp = File(
      "$supportDir/.tmp_${t.versionId}_${_safeName(t.fileName)}",
    );
    final outDir = _outDir(t, dir);
    final gameDir = t.gameName.isNotEmpty ? t.gameName : _safeName(t.fileName);
    try {
      t._cancelled = false;
      await Directory(outDir).create(recursive: true);

      // Download + extract with extract-level retry
      const maxExtractRetries = 2;
      for (int retry = 0; retry <= maxExtractRetries; retry++) {
        if (t._cancelled) {
          try {
            LoggerService().warn("DELETING temp file: $tmp");
            await tmp.delete();
          } catch (_) {}
          return;
        }
        if (t.status == "paused") return;

        // Phase 1: download
        t.status = "downloading";
        _onDownloadStarted();
        _emit();
        NotificationService().showDownloadProgress(
          id: t.gameId,
          gameName: t.gameName,
          progress: 0,
          receivedBytes: 0,
          totalBytes: t.totalBytes,
        );
        await _download(t, tmp);
        if (t._cancelled) {
          try {
            LoggerService().warn("DELETING temp file: $tmp");
            await tmp.delete();
          } catch (_) {}
          return;
        }
        if (t.status == "paused") return;

        // Check if APK — move to output dir, skip extraction
        if (t.fileName.toLowerCase().endsWith(".apk")) {
          t.isApk = true;
          final apkFile = File("$outDir/${_safeName(t.fileName)}");
          try {
            await apkFile.parent.create(recursive: true);
          } catch (_) {}
          try {
            await tmp.rename(apkFile.path);
          } catch (e) {
            try {
              await tmp.copy(apkFile.path);
              await tmp.delete();
            } catch (_) {
              throw Exception("无法保存 APK 文件: $e");
            }
          }
          t.status = "done";
          t.outputPath = apkFile.path;
          t.progress = 1.0;
          _emit();
          NotificationService().showCompleted(
            id: t.gameId,
            gameName: t.gameName,
          );
          return;
        }

        // Phase 2: extract
        t.status = "extracting";
        t.progress = 0.0;
        _emit();
        await Future.delayed(const Duration(milliseconds: 100));
        try {
          await _extract(tmp.path, outDir, gameDir, (p) {
            if (p > t.progress) {
              t.progress = p;
              _emit();
            }
          });
          t.progress = 1.0;
          _emit();

          await tmp.delete();
          break; // success
        } catch (e) {
          if (t._cancelled) {
            try {
              LoggerService().warn("DELETING temp file: $tmp");
              await tmp.delete();
            } catch (_) {}
            return;
          }
          if (t.status == "paused") return;
          final errStr = "$e";
          if (_isEncryptedError(errStr)) rethrow;
          if (_isExtractorMissingError(errStr)) rethrow;
          if (_isArchiveIntegrityError(errStr) && retry < maxExtractRetries) {
            try {
              LoggerService().warn("DELETING temp file: $tmp");
              await tmp.delete();
            } catch (_) {}
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
      t.outputPath = "${outDir}${Platform.pathSeparator}$gameDir";
      _emit();
      NotificationService().showCompleted(id: t.gameId, gameName: t.gameName);
    } catch (e) {
      if (t._cancelled) {
        NotificationService().cancel(t.gameId);
        try {
          LoggerService().warn("DELETING temp file: $tmp");
          await tmp.delete();
        } catch (_) {}
        return;
      }
      if (t.status == "paused") return;
      NotificationService().cancel(t.gameId);
      final errStr = "$e";
      // Check if archive is password-protected
      if (_isEncryptedError(errStr)) {
        final presetPassword = t.extractPassword?.trim() ?? "";
        if (presetPassword.isNotEmpty && !t._triedPresetPassword) {
          t._triedPresetPassword = true;
          t.status = "extracting";
          t.error = null;
          t.needsPassword = false;
          _emit();
          await _runWithPassword(t, presetPassword);
          return;
        }
        t.needsPassword = true;
        t.status = "failed";
        t.error = "需要密码";
      } else {
        t.status = "failed";
        t.error = errStr;
      }
      _emit();
    } finally {
      _runningTasks.remove(t);
      _onDownloadEnded();
      _scheduleDownloads();
    }
  }

  bool _isEncryptedError(String err) {
    final lower = err.toLowerCase();
    return lower.contains("password") ||
        lower.contains("encrypted") ||
        lower.contains("wrong password") ||
        lower.contains("can't open encrypted");
  }

  bool _isExtractorMissingError(String err) {
    final lower = err.toLowerCase();
    return lower.contains("permission denied") ||
        lower.contains("cannot run") ||
        lower.contains("no such file") ||
        lower.contains("process exception") ||
        lower.contains("not executable") ||
        lower.contains("bad elf") ||
        lower.contains("解压组件未就绪") ||
        lower.contains("解压组件校验失败");
  }

  bool _isArchiveIntegrityError(String err) {
    final lower = err.toLowerCase();
    return lower.contains("crc failed") ||
        lower.contains("crc error") ||
        lower.contains("crc_error") ||
        lower.contains("data error") ||
        lower.contains("checksum") ||
        lower.contains("压缩包校验失败") ||
        lower.contains("文件可能已损坏") ||
        lower.contains("下载不完整") ||
        lower.contains("archive is corrupted") ||
        lower.contains("unexpected end") ||
        lower.contains("headers error");
  }

  String _extractFailedArchivePath(String err) {
    final patterns = [
      RegExp(r'CRC Failed\s*:\s*([^\r\n]+)', caseSensitive: false),
      RegExp(r'Data Error\s*:\s*([^\r\n]+)', caseSensitive: false),
      RegExp(r'ERROR\s*:\s*([^\r\n]+)', caseSensitive: false),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(err);
      final value = match?.group(1)?.trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return "";
  }

  String _formatToolError(String err) {
    final raw = err.trim();
    if (raw.isEmpty) return "解压工具执行失败";
    if (_isEncryptedError(raw)) return "压缩包需要密码或密码不正确";
    if (_isArchiveIntegrityError(raw)) {
      final failedPath = _extractFailedArchivePath(raw);
      final suffix = failedPath.isEmpty ? "" : "\n失败文件: $failedPath";
      return "压缩包校验失败，文件可能已损坏、下载不完整，或源文件本身有问题。请重新下载补丁；如果仍失败，请检查补丁源文件完整性。$suffix";
    }
    return raw;
  }

  // ── download ──

  static const _maxRetries = 3;
  static const _retryDelays = [1, 3, 7]; // seconds
  static const _downloadConnectTimeout = Duration(seconds: 20);
  static const _downloadIdleTimeout = Duration(seconds: 45);
  static const _downloadUserAgent = "Sena-Repo Flutter Downloader";
  static const _parallelDownloadMinSize = 32 * 1024 * 1024;
  static const _parallelDownloadMinPartSize = 8 * 1024 * 1024;
  static const _parallelDownloadMaxParts = 8;

  Future<void> _download(DownloadTask t, File dest) async {
    for (int attempt = 0; attempt <= _maxRetries; attempt++) {
      if (_stopped(t)) return;

      final hasParallelState = await _hasParallelDownloadState(dest);
      final speedLimitEnabled = await downloadSpeedLimitKbps > 0;
      if (hasParallelState && speedLimitEnabled) {
        await _discardParallelDownloadState(dest);
        t.receivedBytes = 0;
        t.totalBytes = 0;
      } else if (hasParallelState) {
        if (await dest.exists()) {
          try {
            await dest.delete();
          } catch (_) {}
        }
        final parallelBytes = await _parallelDownloadedBytes(dest);
        if (parallelBytes > 0) t.receivedBytes = parallelBytes;
      } else if (t.receivedBytes > 0) {
        LoggerService().info("Resume: checking dest=${dest.path}");
        if (await dest.exists()) {
          final sz = await dest.length();
          LoggerService().info(
            "Resume: receivedBytes=$t.receivedBytes fileSize=$sz",
          );
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
        t.headersReceived = false;
        final usedParallel = await _attemptParallel(t, dest);
        if (!usedParallel) {
          await _attempt(t, dest);
        }
        return; // success
      } on http.ClientException catch (e) {
        if (_stopped(t)) return;
        if (attempt >= _maxRetries)
          throw Exception("网络中断（重试${_maxRetries}次后仍失败）: $e");
        _setStatus(t, "retrying");
        await Future.delayed(Duration(seconds: _retryDelays[attempt]));
        if (_stopped(t)) return;
        _setStatus(t, "downloading");
      } on SocketException catch (e) {
        if (_stopped(t)) return;
        if (attempt >= _maxRetries)
          throw Exception("网络不通（重试${_maxRetries}次后仍失败）: $e");
        _setStatus(t, "retrying");
        await Future.delayed(Duration(seconds: _retryDelays[attempt]));
        if (_stopped(t)) return;
        _setStatus(t, "downloading");
      } on TimeoutException catch (e) {
        if (_stopped(t)) return;
        if (attempt >= _maxRetries) {
          throw Exception("下载超时（重试${_maxRetries}次后仍失败）: ${e.message ?? e}");
        }
        _setStatus(t, "retrying");
        await Future.delayed(Duration(seconds: _retryDelays[attempt]));
        if (_stopped(t)) return;
        _setStatus(t, "downloading");
      }
    }
  }

  Future<void> _throttleDownload(int bytes) async {
    final limitKbps = await downloadSpeedLimitKbps;
    if (limitKbps <= 0) return;

    final limitBytesPerSecond = limitKbps * 1024;
    _speedWindowBytes += bytes;
    final now = DateTime.now();
    final elapsedMs = now.difference(_speedWindowStart).inMilliseconds;

    if (elapsedMs >= 1000) {
      _speedWindowStart = now;
      _speedWindowBytes = 0;
      return;
    }

    final expectedMs = (_speedWindowBytes * 1000 / limitBytesPerSecond).ceil();
    if (expectedMs > elapsedMs) {
      await Future.delayed(Duration(milliseconds: expectedMs - elapsedMs));
    }
  }

  File _parallelDownloadStateFile(File dest) =>
      File("${dest.path}.parallel.json");

  Future<bool> _hasParallelDownloadState(File dest) async {
    final file = _parallelDownloadStateFile(dest);
    final tmp = File("${file.path}.tmp");
    return await file.exists() || await tmp.exists();
  }

  Future<List<_ParallelDownloadPart>> _parallelDownloadParts(
    File dest,
    int totalBytes,
  ) async {
    final state = await _readParallelDownloadState(dest);
    if (state != null && state.totalBytes == totalBytes) return state.parts;
    if (state != null) {
      await _deleteParallelDownloadState(dest);
    }

    final partSize = (totalBytes / _parallelDownloadMaxParts)
        .ceil()
        .clamp(_parallelDownloadMinPartSize, totalBytes)
        .toInt();
    final parts = <_ParallelDownloadPart>[];
    var start = 0;
    var index = 0;
    while (start < totalBytes) {
      final end = (start + partSize - 1).clamp(0, totalBytes - 1).toInt();
      parts.add(
        _ParallelDownloadPart(
          index: index,
          start: start,
          end: end,
          path: "${dest.path}.part_$index",
        ),
      );
      start = end + 1;
      index += 1;
    }
    await _writeParallelDownloadState(
      dest,
      _ParallelDownloadState(totalBytes: totalBytes, parts: parts),
    );
    return parts;
  }

  Future<_ParallelDownloadState?> _readParallelDownloadState(File dest) async {
    final file = _parallelDownloadStateFile(dest);
    if (!await file.exists()) return null;
    try {
      final data = Map<String, dynamic>.from(
        const JsonDecoder().convert(await file.readAsString()) as Map,
      );
      final totalBytes = data["totalBytes"];
      final rawParts = data["parts"];
      if (totalBytes is! int || rawParts is! List) return null;
      final parts = <_ParallelDownloadPart>[];
      for (final rawPart in rawParts) {
        final part = Map<String, dynamic>.from(rawPart as Map);
        parts.add(
          _ParallelDownloadPart(
            index: part["index"] as int,
            start: part["start"] as int,
            end: part["end"] as int,
            path: part["path"] as String,
          ),
        );
      }
      return _ParallelDownloadState(totalBytes: totalBytes, parts: parts);
    } catch (e) {
      LoggerService().warn("parallel download state invalid: ${dest.path}", e);
      return null;
    }
  }

  Future<void> _writeParallelDownloadState(
    File dest,
    _ParallelDownloadState state,
  ) async {
    final file = _parallelDownloadStateFile(dest);
    final tmp = File("${file.path}.tmp");
    await tmp.writeAsString(
      const JsonEncoder().convert({
        "version": 1,
        "totalBytes": state.totalBytes,
        "parts": state.parts
            .map(
              (part) => {
                "index": part.index,
                "start": part.start,
                "end": part.end,
                "path": part.path,
              },
            )
            .toList(),
      }),
    );
    try {
      await file.delete();
    } catch (_) {}
    await tmp.rename(file.path);
  }

  Future<int> _parallelDownloadedBytes(File dest) async {
    final state = await _readParallelDownloadState(dest);
    if (state == null) return 0;
    return _parallelDownloadedBytesForParts(state.parts);
  }

  Future<int> _parallelDownloadedBytesForParts(
    List<_ParallelDownloadPart> parts,
  ) async {
    var downloaded = 0;
    for (final part in parts) {
      final file = File(part.path);
      if (!await file.exists()) continue;
      final size = await file.length();
      if (size > part.length) {
        try {
          await file.delete();
        } catch (_) {}
        continue;
      }
      downloaded += size;
    }
    return downloaded;
  }

  Future<void> _deleteParallelPartFiles(File dest) async {
    try {
      final parent = dest.parent;
      if (!await parent.exists()) return;
      final prefix = "${dest.path}.part_";
      await for (final entry in parent.list()) {
        if (entry is File && entry.path.startsWith(prefix)) {
          try {
            await entry.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<void> _discardParallelDownloadState(File dest) async {
    LoggerService().warn("discard parallel download state: ${dest.path}");
    try {
      if (await dest.exists()) await dest.delete();
    } catch (e) {
      LoggerService().warn("discard stale parallel download file failed: $e");
    }
    await _deleteParallelDownloadState(dest);
  }

  Future<void> _deleteParallelDownloadState(File dest) async {
    final file = _parallelDownloadStateFile(dest);
    try {
      await file.delete();
    } catch (_) {}
    try {
      await File("${file.path}.tmp").delete();
    } catch (_) {}
    await _deleteParallelPartFiles(dest);
  }

  Future<void> _deleteFileQuietly(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }

  Future<void> _attempt(DownloadTask t, File dest) async {
    final client = http.Client();
    _trackTaskClient(t, client);
    IOSink? sink;
    try {
      final headers = <String, String>{};

      if (t.receivedBytes > 0) {
        headers["Range"] = "bytes=${t.receivedBytes}-";
      }

      final resp = await _sendDownloadRequest(client, t.downloadUrl, headers);
      t.headersReceived = true;
      _emit();
      LoggerService().info(
        "download response: status=${resp.statusCode} "
        "contentLength=${resp.contentLength ?? 0} "
        "contentRange=${resp.headers["content-range"] ?? "-"} "
        "acceptRanges=${resp.headers["accept-ranges"] ?? "-"}",
      );

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
      final downloadStartedAt = DateTime.now();
      final speedLimitEnabled = await downloadSpeedLimitKbps > 0;
      var lastUiEmit = DateTime.fromMillisecondsSinceEpoch(0);
      var lastStateSave = DateTime.now();
      var lastTraceLog = DateTime.now();
      var lastTraceBytes = received;
      var traceChunks = 0;
      var traceSmallChunks = 0;
      final uiEmitIntervalMs = Platform.isAndroid ? 500 : 250;
      final stateSaveIntervalMs = Platform.isAndroid ? 5000 : 2000;
      const notificationIntervalMs = 5000;
      const writeBufferThreshold = 1024 * 1024;
      final writeBuffer = BytesBuilder(copy: false);
      void flushWriteBuffer() {
        if (writeBuffer.length == 0) return;
        sink?.add(writeBuffer.takeBytes());
      }

      sink = dest.openWrite(
        mode: (resp.statusCode == 206) ? FileMode.append : FileMode.write,
      );

      var gotFirstChunk = false;
      await for (final List<int> chunk in resp.stream.timeout(
        _downloadIdleTimeout,
        onTimeout: (sink) {
          sink.addError(
            TimeoutException("下载连接长时间没有收到数据", _downloadIdleTimeout),
          );
        },
      )) {
        if (!gotFirstChunk) {
          gotFirstChunk = true;
          LoggerService().info("download first chunk: ${chunk.length} bytes");
        }
        if (speedLimitEnabled) {
          await _throttleDownload(chunk.length);
        }
        writeBuffer.add(chunk);
        if (writeBuffer.length >= writeBufferThreshold) {
          flushWriteBuffer();
        }
        received += chunk.length;
        t.receivedBytes = received;
        traceChunks += 1;
        if (chunk.length < 32 * 1024) traceSmallChunks += 1;
        // Calculate speed every ~1 second
        final now = DateTime.now();
        final elapsed = now.difference(t._lastSpeedTime).inMilliseconds;
        if (elapsed >= 1000) {
          t.speedBytesPerSecond = ((received - t._lastBytes) / elapsed * 1000)
              .round();
          t._lastBytes = received;
          t._lastSpeedTime = now;
        }
        t.progress = t.totalBytes > 0 ? received / t.totalBytes : 0.0;
        if (now.difference(lastUiEmit).inMilliseconds >= uiEmitIntervalMs) {
          lastUiEmit = now;
          _emit(save: false);
        }
        if (now.difference(lastStateSave).inMilliseconds >=
            stateSaveIntervalMs) {
          lastStateSave = now;
          _saveTasks();
        }
        // Android notification updates cross the platform channel; keep them sparse.
        final notifyElapsed = now.difference(t._lastNotifyTime).inMilliseconds;
        if (notifyElapsed >= notificationIntervalMs) {
          t._lastNotifyTime = now;
          NotificationService().showDownloadProgress(
            id: t.gameId,
            gameName: t.gameName,
            progress: t.progress,
            receivedBytes: received,
            totalBytes: t.totalBytes,
          );
        }
        final traceElapsed = now.difference(lastTraceLog).inMilliseconds;
        if (traceElapsed >= 10000) {
          final windowBytes = received - lastTraceBytes;
          final windowSpeed = (windowBytes * 1000 / traceElapsed).round();
          LoggerService().info(
            "download trace: platform=${Platform.operatingSystem} "
            "received=$received total=${t.totalBytes} "
            "windowSpeed=$windowSpeed chunks=$traceChunks "
            "smallChunks=$traceSmallChunks buffered=${writeBuffer.length}",
          );
          lastTraceLog = now;
          lastTraceBytes = received;
          traceChunks = 0;
          traceSmallChunks = 0;
        }
      }
      // Tell UI we're done downloading before slow disk flush
      flushWriteBuffer();
      t.progress = 1.0;
      _emit();
      await sink.flush();
      await sink.close();

      // Validate disk
      final fileSize = await dest.length();
      if (t.totalBytes > 0 && fileSize != t.totalBytes) {
        t.receivedBytes = 0;
        t.totalBytes = 0;
        try {
          await dest.delete();
        } catch (_) {}
        await _deleteParallelDownloadState(dest);
        throw Exception("文件不完整: 预期${t.totalBytes}B 实际${fileSize}B");
      }
      if (fileSize == 0) {
        throw Exception("未收到任何数据");
      }
      // Sync counter
      if (t.receivedBytes != fileSize) t.receivedBytes = fileSize;
      await _deleteParallelDownloadState(dest);
      final elapsedMs = DateTime.now()
          .difference(downloadStartedAt)
          .inMilliseconds
          .clamp(1, 1 << 31);
      final avgSpeed = (fileSize * 1000 / elapsedMs).round();
      LoggerService().info(
        "download completed: bytes=$fileSize elapsedMs=$elapsedMs avgSpeed=$avgSpeed",
      );
    } finally {
      // Ensure data is flushed to disk before returning
      try {
        await sink?.flush();
      } catch (_) {}
      try {
        await sink?.close();
      } catch (_) {}
      // Small delay for Android filesystem to update metadata
      if (Platform.isAndroid)
        await Future.delayed(const Duration(milliseconds: 200));
      client.close();
      _untrackTaskClient(t, client);
      // Sync counter with actual file size (critical for resume)
      try {
        final actualSize = await dest.length();
        if (actualSize > 0) t.receivedBytes = actualSize;
        if (t.totalBytes > 0 && actualSize >= t.totalBytes)
          t.receivedBytes = t.totalBytes;
      } catch (_) {}
      // Save task state immediately so resume has correct receivedBytes
      if (t.status == "paused") _saveTasks();
    }
  }

  Future<bool> _attemptParallel(DownloadTask t, File dest) async {
    final hasParallelState = await _hasParallelDownloadState(dest);
    if (await downloadSpeedLimitKbps > 0) return false;
    if (t.receivedBytes > 0 && !hasParallelState) {
      return false;
    }

    final probe = await _probeParallelDownload(t);
    if (probe == null || probe.totalBytes < _parallelDownloadMinSize) {
      if (hasParallelState) {
        await _discardParallelDownloadState(dest);
        t.receivedBytes = 0;
        t.totalBytes = 0;
        t.progress = 0.0;
      }
      return false;
    }

    if (await dest.exists()) {
      try {
        await dest.delete();
      } catch (_) {}
    }

    final parts = await _parallelDownloadParts(dest, probe.totalBytes);
    var downloaded = await _parallelDownloadedBytesForParts(parts);
    if (downloaded >= probe.totalBytes) {
      await _mergeParallelParts(t, dest, parts, probe.totalBytes);
      return true;
    }

    t.headersReceived = true;
    t.totalBytes = probe.totalBytes;
    t.receivedBytes = downloaded;
    t.progress = downloaded / probe.totalBytes;
    _emit();

    LoggerService().info(
      "parallel download started: parts=${parts.length} "
      "total=${probe.totalBytes} received=$downloaded",
    );

    final startedAt = DateTime.now();
    var lastUiEmit = DateTime.fromMillisecondsSinceEpoch(0);
    var lastStateSave = DateTime.now();
    var lastTraceLog = DateTime.now();
    var lastTraceBytes = downloaded;
    var traceChunks = 0;
    var traceSmallChunks = 0;
    final uiEmitIntervalMs = Platform.isAndroid ? 500 : 250;
    final stateSaveIntervalMs = Platform.isAndroid ? 5000 : 2000;
    const notificationIntervalMs = 5000;

    void recordBytes(int bytes) {
      downloaded += bytes;
      t.receivedBytes = downloaded;
      final now = DateTime.now();
      final elapsed = now.difference(t._lastSpeedTime).inMilliseconds;
      if (elapsed >= 1000) {
        t.speedBytesPerSecond =
            ((downloaded - t._lastBytes) / elapsed * 1000).round();
        t._lastBytes = downloaded;
        t._lastSpeedTime = now;
      }
      t.progress = t.totalBytes > 0 ? downloaded / t.totalBytes : 0.0;
      traceChunks += 1;
      if (bytes < 32 * 1024) traceSmallChunks += 1;

      if (now.difference(lastUiEmit).inMilliseconds >= uiEmitIntervalMs) {
        lastUiEmit = now;
        _emit(save: false);
      }
      if (now.difference(lastStateSave).inMilliseconds >=
          stateSaveIntervalMs) {
        lastStateSave = now;
        _saveTasks();
      }
      final notifyElapsed = now.difference(t._lastNotifyTime).inMilliseconds;
      if (notifyElapsed >= notificationIntervalMs) {
        t._lastNotifyTime = now;
        NotificationService().showDownloadProgress(
          id: t.gameId,
          gameName: t.gameName,
          progress: t.progress,
          receivedBytes: downloaded,
          totalBytes: t.totalBytes,
        );
      }
      final traceElapsed = now.difference(lastTraceLog).inMilliseconds;
      if (traceElapsed >= 10000) {
        final windowBytes = downloaded - lastTraceBytes;
        final windowSpeed = (windowBytes * 1000 / traceElapsed).round();
        LoggerService().info(
          "parallel download trace: platform=${Platform.operatingSystem} "
          "received=$downloaded total=${t.totalBytes} "
          "windowSpeed=$windowSpeed chunks=$traceChunks "
          "smallChunks=$traceSmallChunks",
        );
        lastTraceLog = now;
        lastTraceBytes = downloaded;
        traceChunks = 0;
        traceSmallChunks = 0;
      }
    }

    final pending = <_ParallelDownloadPart>[];
    for (final part in parts) {
      final file = File(part.path);
      final existing = await file.exists() ? await file.length() : 0;
      if (existing >= part.length) continue;
      pending.add(part);
    }

    var nextIndex = 0;
    Future<void> worker() async {
      while (!_stopped(t)) {
        final index = nextIndex;
        if (index >= pending.length) return;
        nextIndex += 1;
        await _downloadParallelPart(t, pending[index], recordBytes);
      }
    }

    try {
      final workers = List.generate(
        pending.length.clamp(0, _parallelDownloadMaxParts).toInt(),
        (_) => worker(),
      );
      await Future.wait(workers);
    } on _ParallelDownloadUnsupported catch (e) {
      LoggerService().warn("parallel download unsupported; fallback to stream", e);
      await _discardParallelDownloadState(dest);
      t.receivedBytes = 0;
      t.totalBytes = 0;
      t.progress = 0.0;
      return false;
    }

    if (_stopped(t)) {
      await _saveTasks();
      return true;
    }

    downloaded = await _parallelDownloadedBytesForParts(parts);
    if (downloaded != probe.totalBytes) {
      throw http.ClientException(
        "parallel download incomplete: expected=${probe.totalBytes} actual=$downloaded",
      );
    }

    await _mergeParallelParts(t, dest, parts, probe.totalBytes);
    final elapsedMs = DateTime.now()
        .difference(startedAt)
        .inMilliseconds
        .clamp(1, 1 << 31);
    final avgSpeed = (probe.totalBytes * 1000 / elapsedMs).round();
    LoggerService().info(
      "parallel download completed: bytes=${probe.totalBytes} "
      "elapsedMs=$elapsedMs avgSpeed=$avgSpeed parts=${parts.length}",
    );
    return true;
  }

  Future<_ParallelDownloadProbe?> _probeParallelDownload(DownloadTask t) async {
    final client = http.Client();
    _trackTaskClient(t, client);
    try {
      final resp = await _sendDownloadRequest(
        client,
        t.downloadUrl,
        {"Range": "bytes=0-0"},
      );
      LoggerService().info(
        "parallel probe response: status=${resp.statusCode} "
        "contentLength=${resp.contentLength ?? 0} "
        "contentRange=${resp.headers["content-range"] ?? "-"} "
        "acceptRanges=${resp.headers["accept-ranges"] ?? "-"}",
      );
      if (resp.statusCode != 206) return null;
      await resp.stream.drain<void>();
      final total = _parseContentRangeTotal(resp.headers["content-range"]);
      if (total == null || total <= 0) return null;
      final acceptRanges = (resp.headers["accept-ranges"] ?? "").toLowerCase();
      if (!acceptRanges.contains("bytes")) return null;
      return _ParallelDownloadProbe(totalBytes: total);
    } finally {
      client.close();
      _untrackTaskClient(t, client);
    }
  }

  int? _parseContentRangeTotal(String? value) {
    if (value == null) return null;
    final match = RegExp(r"^bytes\s+\d+-\d+/(\d+)$").firstMatch(value.trim());
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  Future<void> _downloadParallelPart(
    DownloadTask t,
    _ParallelDownloadPart part,
    void Function(int bytes) onBytes,
  ) async {
    final file = File(part.path);
    var existing = await file.exists() ? await file.length() : 0;
    if (existing > part.length) {
      try {
        await file.delete();
      } catch (_) {}
      existing = 0;
    }
    if (existing == part.length) return;

    final client = http.Client();
    _trackTaskClient(t, client);
    IOSink? sink;
    try {
      final start = part.start + existing;
      final resp = await _sendDownloadRequest(
        client,
        t.downloadUrl,
        {"Range": "bytes=$start-${part.end}"},
      );
      if (resp.statusCode == 416 && existing == part.length) return;
      if (resp.statusCode != 206) {
        if (resp.statusCode == 200) {
          throw _ParallelDownloadUnsupported(
            "range ignored for part=${part.index}",
          );
        }
        throw http.ClientException(
          "parallel part ${part.index} failed: HTTP ${resp.statusCode}",
        );
      }

      final contentRange = resp.headers["content-range"];
      if (!_contentRangeMatchesPart(contentRange, start, part.end)) {
        throw _ParallelDownloadUnsupported(
          "unexpected content range for part=${part.index}: $contentRange",
        );
      }

      sink = file.openWrite(
        mode: existing > 0 ? FileMode.append : FileMode.write,
      );
      await for (final chunk in resp.stream.timeout(
        _downloadIdleTimeout,
        onTimeout: (sink) {
          sink.addError(
            TimeoutException("下载连接长时间没有收到数据", _downloadIdleTimeout),
          );
        },
      )) {
        if (_stopped(t)) return;
        sink.add(chunk);
        onBytes(chunk.length);
      }
      await sink.flush();
      await sink.close();

      final actual = await file.length();
      if (actual != part.length) {
        throw http.ClientException(
          "parallel part ${part.index} incomplete: expected=${part.length} actual=$actual",
        );
      }
    } finally {
      try {
        await sink?.flush();
      } catch (_) {}
      try {
        await sink?.close();
      } catch (_) {}
      client.close();
      _untrackTaskClient(t, client);
    }
  }

  bool _contentRangeMatchesPart(String? value, int start, int end) {
    if (value == null) return false;
    final match = RegExp(
      r"^bytes\s+(\d+)-(\d+)/(\d+)$",
    ).firstMatch(value.trim());
    if (match == null) return false;
    return int.tryParse(match.group(1)!) == start &&
        int.tryParse(match.group(2)!) == end;
  }

  Future<void> _mergeParallelParts(
    DownloadTask t,
    File dest,
    List<_ParallelDownloadPart> parts,
    int totalBytes,
  ) async {
    IOSink? sink;
    try {
      sink = dest.openWrite(mode: FileMode.write);
      for (final part in parts) {
        if (_stopped(t)) return;
        final file = File(part.path);
        if (!await file.exists() || await file.length() != part.length) {
          throw http.ClientException(
            "parallel part ${part.index} missing before merge",
          );
        }
        await sink.addStream(file.openRead());
      }
      await sink.flush();
      await sink.close();
      final size = await dest.length();
      if (size != totalBytes) {
        throw http.ClientException(
          "parallel merge incomplete: expected=$totalBytes actual=$size",
        );
      }
      t.receivedBytes = size;
      t.totalBytes = totalBytes;
      t.progress = 1.0;
      _emit();
      await _deleteParallelDownloadState(dest);
    } finally {
      try {
        await sink?.flush();
      } catch (_) {}
      try {
        await sink?.close();
      } catch (_) {}
    }
  }

  Future<http.StreamedResponse> _sendDownloadRequest(
    http.Client client,
    String url,
    Map<String, String> baseHeaders,
  ) async {
    var current = Uri.parse(url);
    final originalScheme = current.scheme;
    final originalHost = current.host;
    final originalPort = current.hasPort ? current.port : null;

    for (var redirectCount = 0; redirectCount < 8; redirectCount++) {
      final req = http.Request("GET", current)..followRedirects = false;
      req.headers.addAll(baseHeaders);
      req.headers.putIfAbsent("User-Agent", () => _downloadUserAgent);
      req.headers.putIfAbsent("Accept", () => "*/*");

      final sameOrigin =
          current.scheme == originalScheme &&
          current.host == originalHost &&
          (current.hasPort ? current.port : null) == originalPort;
      if (sameOrigin && globalToken != null && globalToken!.isNotEmpty) {
        req.headers["Authorization"] = "Bearer $globalToken";
      }

      LoggerService().info(
        "download request[$redirectCount]: ${_downloadLogTarget(current)} "
        "range=${req.headers["Range"] ?? "-"} "
        "auth=${req.headers.containsKey("Authorization")}",
      );
      final resp = await client
          .send(req)
          .timeout(
            _downloadConnectTimeout,
            onTimeout: () => throw TimeoutException(
              "连接下载地址超时: ${_downloadLogTarget(current)}",
              _downloadConnectTimeout,
            ),
          );

      if (resp.statusCode >= 300 && resp.statusCode < 400) {
        final location = resp.headers["location"];
        await resp.stream.drain<void>();
        if (location == null || location.trim().isEmpty) {
          throw Exception("下载重定向缺少 Location: HTTP ${resp.statusCode}");
        }
        final next = current.resolve(location.trim());
        LoggerService().info(
          "download redirect[$redirectCount]: HTTP ${resp.statusCode} "
          "${_downloadLogTarget(current)} -> ${_downloadLogTarget(next)}",
        );
        current = next;
        continue;
      }

      LoggerService().info(
        "download final[$redirectCount]: HTTP ${resp.statusCode} ${_downloadLogTarget(current)}",
      );
      return resp;
    }

    throw Exception("下载重定向次数过多");
  }

  String _downloadLogTarget(Uri uri) {
    final port = uri.hasPort ? ":${uri.port}" : "";
    final name = uri.pathSegments.isEmpty ? "" : uri.pathSegments.last;
    final safeName = name.length > 96 ? "${name.substring(0, 96)}..." : name;
    final queryKeys = uri.queryParametersAll.keys.toList()..sort();
    final query = queryKeys.isEmpty
        ? ""
        : " queryKeys=${queryKeys.join(",")}";
    final suffix = safeName.isEmpty ? "" : "/.../$safeName";
    return "${uri.scheme}://${uri.host}$port$suffix$query";
  }

  // ── extract (desktop only) ──

  Future<void> _extract(
    String filePath,
    String outDir,
    String gameDir, [
    void Function(double)? onProgress,
    String? password,
  ]) async {
    final String exe;
    try {
      exe = await _getSevenZipPath();
    } catch (e) {
      throw Exception("解压组件未就绪: $e");
    }
    // Extract to a temp subdirectory so _fixLayout only sees the new content
    // and isn't confused by pre-existing sibling game folders in outDir.
    final extractTempDir =
        "$outDir${Platform.pathSeparator}.sena_tmp_${gameDir.hashCode.abs()}";
    // Clean up any leftover from a previous crashed extraction
    try {
      await Directory(extractTempDir).delete(recursive: true);
    } catch (_) {}
    try {
      final args = ["x", "-y", "-p-", "-o$extractTempDir", filePath];
      if (password != null) {
        args.remove("-p-");
        args.insert(1, "-p$password");
      }
      // Skip integrity test on Android (saves time, verified during extraction)
      if (password == null && !Platform.isAndroid) {
        try {
          await _runTool(
            exe,
            ["t", "-y", "-p-", filePath],
            onProgress: onProgress,
            timeout: 300,
          );
        } catch (_) {}
      }
      LoggerService().info(
        "extract command: exe=$exe args=${_redactToolArgs(args)}",
      );
      await _runTool(
        exe,
        args,
        onProgress: onProgress,
        timeout: Platform.isAndroid ? 600 : 1800,
      ); // Android: 10min timeout
      await _fixLayout(extractTempDir, gameDir);
      // Move result from temp to final location
      final finalDir = "$outDir${Platform.pathSeparator}$gameDir";
      final source = "$extractTempDir${Platform.pathSeparator}$gameDir";
      if (await Directory(source).exists()) {
        // _fixLayout produced a subfolder named gameDir → move it out
        // Remove stale empty dir from prior attempt
        try {
          if (await Directory(finalDir).exists())
            await Directory(finalDir).delete(recursive: true);
        } catch (_) {}
        try {
          await Directory(source).rename(finalDir);
        } catch (_) {
          // rename failed (may be cross-volume) → copy+delete fallback
          await _copyMerge(source, finalDir);
          await Directory(source).delete(recursive: true);
        }
      } else {
        // _fixLayout case 2 (already named correctly) or no subfolder produced
        // Move the whole temp dir to final location
        try {
          if (await Directory(finalDir).exists())
            await Directory(finalDir).delete(recursive: true);
        } catch (_) {}
        try {
          await Directory(extractTempDir).rename(finalDir);
        } catch (_) {
          await _copyMerge(extractTempDir, finalDir);
          await Directory(extractTempDir).delete(recursive: true);
        }
      }
    } finally {
      // Clean up temp directory
      try {
        await Directory(extractTempDir).delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Ensure clean output: rename archive folder to [gameDir] if different,
  /// or wrap scattered files in [gameDir] folder.
  Future<void> _fixLayout(String outDir, String gameDir) async {
    List<FileSystemEntity> entries;
    try {
      entries = await Directory(outDir).list().toList();
    } catch (_) {
      return;
    }
    if (entries.isEmpty) return;

    // One folder = archive had its own wrapper
    if (entries.length == 1 && entries.first is Directory) {
      final folder = entries.first as Directory;
      final folderName = folder.uri.pathSegments.last;
      // Rename to match game name if different
      if (folderName != gameDir) {
        final target = "${outDir}${Platform.pathSeparator}$gameDir";
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
    if (entries.any(
      (e) => e is Directory && e.uri.pathSegments.last == gameDir,
    ))
      return;

    final wrap = "${outDir}${Platform.pathSeparator}$gameDir";
    try {
      await Directory(wrap).create();
      for (final e in entries) {
        try {
          await e.rename(
            "${wrap}${Platform.pathSeparator}${e.uri.pathSegments.last}",
          );
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Recursively copy/merge ALL contents of [from] into [to], preserving directory structure.
  Future<void> _copyMerge(String from, String to) async {
    await for (final child in Directory(from).list(recursive: true)) {
      final rel = child.path
          .substring(from.length)
          .replaceFirst(RegExp(r'^[/\\]'), '');
      final dest = "$to${Platform.pathSeparator}$rel";
      if (child is Directory) {
        await Directory(dest).create(recursive: true);
      } else if (child is File) {
        try {
          await Directory(File(dest).parent.path).create(recursive: true);
          await child.copy(dest);
          LoggerService().info("patch copy: $rel -> $dest");
        } catch (e) {
          LoggerService().warn("patch copy FAIL: $rel -> $dest error=$e");
          throw Exception("无法覆盖 $rel: $e");
        }
      }
    }
  }

  String _resolveSafeRelativePath(String base, String relative) {
    final normalizedRelative = relative.replaceAll("\\", "/").trim();
    if (normalizedRelative.isEmpty) return Directory(base).absolute.path;
    if (normalizedRelative.contains("\u0000")) throw ArgumentError("NUL byte");
    if (RegExp(r'^[A-Za-z]:').hasMatch(normalizedRelative) ||
        normalizedRelative.startsWith("/") ||
        normalizedRelative.startsWith("//")) {
      throw ArgumentError("absolute path");
    }

    final parts = normalizedRelative
        .split("/")
        .where((p) => p.isNotEmpty && p != ".")
        .toList();
    if (parts.any((p) => p == "..")) throw ArgumentError("parent path");

    var current = Directory(base).absolute.path;
    for (final part in parts) {
      current = "$current${Platform.pathSeparator}$part";
    }

    final baseResolved = Directory(
      base,
    ).absolute.uri.normalizePath().toFilePath();
    final targetResolved = Directory(
      current,
    ).absolute.uri.normalizePath().toFilePath();
    final baseWithSep = baseResolved.endsWith(Platform.pathSeparator)
        ? baseResolved
        : "$baseResolved${Platform.pathSeparator}";
    if (targetResolved != baseResolved &&
        !targetResolved.startsWith(baseWithSep)) {
      throw ArgumentError("path escapes base");
    }
    return targetResolved;
  }

  List<String> _redactToolArgs(List<String> args) {
    return args
        .map((arg) => arg.startsWith("-p") && arg != "-p-" ? "-p***" : arg)
        .toList();
  }

  Future<void> _runTool(
    String exe,
    List<String> args, {
    void Function(double)? onProgress,
    int timeout = 1800,
    String? injectionAppId,
  }) async {
    // Android: bypass noexec by using dynamic linker to load the ELF
    if (Platform.isAndroid) {
      args = [exe, ...args];
      exe = "/system/bin/linker64";
    }
    final proc = await Process.start(exe, args);
    _extractionProcess = proc;
    try {
      await proc.stdin.close();
    } catch (_) {}
    // Also track in patch injection state for cross-instance cancellation
    if (injectionAppId != null) {
      _patchInjections[injectionAppId]?.extractProcess = proc;
    }

    // 7z usually writes progress to stderr, but some builds use stdout.
    final stderrChunks = <int>[];
    final stdoutChunks = <int>[];
    void handleOutput(List<int> d, List<int> chunks) {
      if (chunks.length < 8192) chunks.addAll(d.take(8192 - chunks.length));
      if (onProgress != null) {
        final s = String.fromCharCodes(d);
        final m = RegExp(r'\s+(\d+)%').firstMatch(s);
        if (m != null) {
          onProgress(int.parse(m.group(1)!) / 100.0);
        }
      }
    }

    final stderrSub = proc.stderr.listen((d) {
      handleOutput(d, stderrChunks);
    });
    final stdoutSub = proc.stdout.listen((d) {
      handleOutput(d, stdoutChunks);
    });

    // Wait with timeout
    int exitCode = -1;
    try {
      exitCode = await proc.exitCode.timeout(Duration(seconds: timeout));
    } on TimeoutException {
      proc.kill();
      await stdoutSub.cancel();
      await stderrSub.cancel();
      _extractionProcess = null;
      if (injectionAppId != null)
        _patchInjections[injectionAppId]?.extractProcess = null;
      throw Exception("超时（${timeout}s）");
    } catch (e) {
      proc.kill();
      await stdoutSub.cancel();
      await stderrSub.cancel();
      _extractionProcess = null;
      if (injectionAppId != null)
        _patchInjections[injectionAppId]?.extractProcess = null;
      throw Exception("$e");
    }

    await stdoutSub.cancel();
    await stderrSub.cancel();
    _extractionProcess = null;
    if (injectionAppId != null)
      _patchInjections[injectionAppId]?.extractProcess = null;

    if (exitCode != 0) {
      final err = [
        String.fromCharCodes(stderrChunks).trim(),
        String.fromCharCodes(stdoutChunks).trim(),
      ].where((s) => s.isNotEmpty).join("\n");
      final rawErr = err.isNotEmpty ? err : "exit code $exitCode";
      LoggerService().warn("extract tool failed: ${_formatToolError(rawErr)}");
      throw Exception(_formatToolError(rawErr));
    }
  }

  // ── helpers ──

  /// Strip path traversal sequences from a filename, keeping only the basename.
  String _safeName(String name) => name.split(RegExp(r"[/\\]")).last;

  String _outDir(DownloadTask t, String dir) {
    final sub = t.companyName.isNotEmpty ? t.companyName : "_unknown";
    // Extract directly to 会社/, letting archive folder name be the game folder
    return "${dir}${Platform.pathSeparator}$sub";
  }

  bool _stopped(DownloadTask t) => t._cancelled || t.status == "paused";

  void _trackTaskClient(DownloadTask t, http.Client client) {
    t._clients.add(client);
    t._client = client;
  }

  void _untrackTaskClient(DownloadTask t, http.Client client) {
    t._clients.remove(client);
    if (identical(t._client, client)) {
      t._client = t._clients.isEmpty ? null : t._clients.last;
    }
  }

  void _closeTaskClients(DownloadTask t) {
    for (final client in List<http.Client>.from(t._clients)) {
      try {
        client.close();
      } catch (_) {}
    }
    t._clients.clear();
    try {
      t._client?.close();
    } catch (_) {}
    t._client = null;
  }

  void _setStatus(DownloadTask t, String s) {
    t.status = s;
    _emit();
  }

  void _killExtractor() {
    _extractionProcess?.kill();
    _extractionProcess = null;
  }

  Future<void> _cleanupTemp(DownloadTask t) async {
    try {
      final supportDir = (await getApplicationSupportDirectory()).path;
      final tmp = File(
        "$supportDir/.tmp_${t.versionId}_${_safeName(t.fileName)}",
      );
      try {
        await tmp.delete();
      } catch (_) {}
      await _deleteParallelDownloadState(tmp);
    } catch (_) {}
  }

  /// Try to refresh the access token before starting a download,
  /// using the refresh_token from ApiClient and extracting the server
  /// base URL from the download URL itself.

  void _emit({bool save = true}) {
    _controller.add(List.unmodifiable(_tasks));
    if (save) _saveTasks();
    if (!_hasActiveDownloads()) _stopForegroundService();
  }
}

class _ParallelDownloadState {
  final int totalBytes;
  final List<_ParallelDownloadPart> parts;

  _ParallelDownloadState({required this.totalBytes, required this.parts});
}

class _ParallelDownloadPart {
  final int index;
  final int start;
  final int end;
  final String path;

  _ParallelDownloadPart({
    required this.index,
    required this.start,
    required this.end,
    required this.path,
  });

  int get length => end - start + 1;
}

class _ParallelDownloadProbe {
  final int totalBytes;

  _ParallelDownloadProbe({required this.totalBytes});
}

class _ParallelDownloadUnsupported implements Exception {
  final String message;

  _ParallelDownloadUnsupported(this.message);

  @override
  String toString() => message;
}

// ── Patch injection state (used by downloadPatch + SteamService) ──
class _PatchInjection {
  final DownloadTask task;
  final String tempPath;
  Process? extractProcess;
  bool cancelled = false;
  bool paused = false;

  _PatchInjection({required this.task, required this.tempPath});
}
