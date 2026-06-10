/// Download service — stream download with progress + zip extraction.
/// Supports .zip via archive package, plus .rar/.7z via bundled 7z binary.

import "dart:async";
import "dart:convert";
import "dart:io";

import "package:archive/archive_io.dart";
import "package:flutter/services.dart" show rootBundle;
import "package:http/http.dart" as http;
import "package:path_provider/path_provider.dart";
import "package:shared_preferences/shared_preferences.dart";

class DownloadTask {
  final int gameId;
  final int versionId;
  final String fileName;
  final String downloadUrl;
  final String gameName;
  final String companyName;
  String status; // pending, downloading, paused, extracting, done, failed, cancelled
  double progress;
  int receivedBytes = 0;
  int totalBytes = 0;
  String? error;
  String? outputPath;
  final DateTime startedAt;
  http.Client? _client; // stored for cancellation

  DownloadTask({
    required this.gameId,
    required this.versionId,
    required this.fileName,
    required this.downloadUrl,
    required this.gameName,
    required this.companyName,
    this.status = "pending",
    this.progress = 0,
    this.error,
    this.outputPath,
  }) : startedAt = DateTime.now();

  Map<String, dynamic> toJson() => {
    "gameId": gameId, "versionId": versionId, "fileName": fileName,
    "downloadUrl": downloadUrl, "gameName": gameName, "companyName": companyName,
    "status": status, "progress": progress, "error": error, "outputPath": outputPath,
    "startedAt": startedAt.toIso8601String(),
  };
}

class DownloadService {
  static final DownloadService _instance = DownloadService._();
  factory DownloadService() => _instance;
  DownloadService._();

  final List<DownloadTask> _tasks = [];
  final _controller = StreamController<List<DownloadTask>>.broadcast();
  Stream<List<DownloadTask>> get tasks => _controller.stream;
  List<DownloadTask> get currentTasks => List.unmodifiable(_tasks);

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

    // Run download in background, return task immediately
    _runDownload(task);
    return task;
  }

  Future<void> _runDownload(DownloadTask task) async {
    try {
      final dir = await downloadDir;

      task.status = "downloading";
      _emit();

      final tmpFile = File("$dir/.tmp_${task.versionId}_${task.fileName}");
      await _downloadFile(task, tmpFile, (progress) {
        task.progress = progress;
        _emit();
      });

      task.status = "extracting";
      task.progress = 1.0;
      _emit();

      final subDir = task.companyName.isNotEmpty ? task.companyName : "_unknown";
      final gameDir = task.gameName.isNotEmpty ? task.gameName : task.fileName;
      final outDir = "$dir/$subDir/$gameDir";
      await Directory(outDir).create(recursive: true);

      await _extractArchive(tmpFile.path, outDir);
      await tmpFile.delete();

      task.status = "done";
      task.outputPath = outDir;
      _emit();
    } catch (e) {
      task.status = "failed";
      task.error = "$e";
      _emit();
    }
  }

  Future<void> _downloadFile(
    DownloadTask task, File dest, void Function(double) onProgress,
  ) async {
    final client = http.Client();
    task._client = client;
    try {
      final request = http.Request("GET", Uri.parse(task.downloadUrl));
      // Resume from where we left off
      if (task.receivedBytes > 0 && await dest.exists()) {
        request.headers["Range"] = "bytes=${task.receivedBytes}-";
      }
      final response = await client.send(request);

      final isPartial = response.statusCode == 206;
      if (response.statusCode != 200 && response.statusCode != 206) {
        final body = await response.stream.bytesToString();
        throw Exception("下载失败 HTTP ${response.statusCode}: $body");
      }

      final cl = response.contentLength ?? 0;
      final total = task.receivedBytes + cl.toInt();
      task.totalBytes = total > 0 ? total : task.totalBytes;
      var received = task.receivedBytes;
      final sink = dest.openWrite(mode: isPartial ? FileMode.append : FileMode.write);
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        task.receivedBytes = received;
        if (task.totalBytes > 0) {
          task.progress = received / task.totalBytes;
          onProgress(task.progress);
        }
      }
      await sink.flush();
      await sink.close();
    } finally {
      client.close();
      task._client = null;
    }
  }

  Future<void> _extractArchive(String filePath, String outDir) async {
    final ext = filePath.toLowerCase();
    if (ext.endsWith(".zip")) {
      await _extractZip(filePath, outDir);
    } else if (ext.endsWith(".7z") || ext.endsWith(".rar")) {
      await _extractWithSystemTool(filePath, outDir);
    } else {
      // Unknown format — just copy
      final f = File(filePath);
      await f.copy("$outDir/${f.uri.pathSegments.last}");
    }
  }

  Future<void> _extractZip(String zipPath, String outDir) async {
    final inputStream = InputFileStream(zipPath);
    final archive = ZipDecoder().decodeBuffer(inputStream);
    for (final file in archive) {
      final filePath = "$outDir/${file.name}";
      if (file.isFile) {
        final outFile = File(filePath);
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(file.content as List<int>);
      } else {
        await Directory(filePath).create(recursive: true);
      }
    }
    await inputStream.close();
  }

  String? _sevenZipPath;
  bool _userSkippedSetup = false;
  Future<bool> Function()? _onSetupNeeded; // Callback to show setup dialog

  /// Register a callback for showing the setup dialog. Returns true if setup proceeded.
  void onSetupNeeded(Future<bool> Function() callback) {
    _onSetupNeeded = callback;
  }

  Future<String> _getSevenZipPath() async {
    if (_sevenZipPath != null) return _sevenZipPath!;
    final dir = await getApplicationSupportDirectory();
    final exeName = Platform.isWindows ? "7za.exe" : "7zz";
    final dest = File("${dir.path}/$exeName");

    if (!await dest.exists()) {
      // Try bundled asset first
      try {
        final data = await rootBundle.load("assets/binaries/$exeName");
        await dest.writeAsBytes(data.buffer.asUint8List());
        if (Platform.isLinux) {
          await Process.run("chmod", ["+x", dest.path]);
        }
      } catch (_) {
        // Show setup dialog to user
        if (!_userSkippedSetup && _onSetupNeeded != null) {
          final proceed = await _onSetupNeeded!();
          if (!proceed) {
            _userSkippedSetup = true;
            throw Exception("用户取消了 7-Zip 安装。请手动安装 7-Zip 后再试。");
          }
          // Download 7za with progress
          try {
            final url = Platform.isWindows
                ? "https://www.7-zip.org/a/7z2601-extra.7z"
                : "https://www.7-zip.org/a/7z2409-linux-x64.tar.xz";
            final tmp = File("${dir.path}/_7z_dl");
            final client = http.Client();
            try {
              final resp = await client.send(http.Request("GET", Uri.parse(url)));
              if (resp.statusCode != 200) throw Exception("HTTP ${resp.statusCode}");
              final total = resp.contentLength ?? 0;
              var received = 0;
              final sink = tmp.openWrite();
              await for (final chunk in resp.stream) {
                sink.add(chunk);
                received += chunk.length;
              }
              await sink.flush(); await sink.close();
              if (Platform.isWindows) {
                final archive = ZipDecoder().decodeBuffer(InputFileStream(tmp.path));
                for (final f in archive) {
                  if (f.isFile && (f.name == "7za.exe" || f.name.endsWith("/7za.exe"))) {
                    await dest.writeAsBytes(f.content as List<int>);
                    break;
                  }
                }
              } else {
                await Process.run("tar", ["-xf", tmp.path, "-C", dir.path]);
              }
              await tmp.delete();
            } finally { client.close(); }
          } catch (_) {
            throw Exception("7-Zip 下载失败。请手动安装 7-Zip 后再试。");
          }
        } else {
          throw Exception("解压组件未就绪。请安装 7-Zip 或手动放置 7za.exe 到 $dir");
        }
      }
    }

    if (!await dest.exists()) {
      throw Exception("解压组件未就绪。请安装 7-Zip 或手动放置 7za.exe 到 $dir");
    }

    _sevenZipPath = dest.path;
    return _sevenZipPath!;
  }

  Future<void> _extractWithSystemTool(String filePath, String outDir) async {
    try {
      final sevenZip = await _getSevenZipPath();
      final result = await Process.run(sevenZip, ["x", "-y", "-o$outDir", filePath]);
      if (result.exitCode != 0) {
        throw Exception("7za error: ${result.stderr}".trim());
      }
      return;
    } catch (e) {
      // Fallback to system tools
      try {
        final result = await Process.run("7z", ["x", "-y", "-o$outDir", filePath]);
        if (result.exitCode == 0) return;
        if (result.stderr.toString().isNotEmpty) throw Exception("7z: ${result.stderr}");
      } catch (e2) {
        try {
          final result = await Process.run("unar", ["-o", outDir, filePath]);
          if (result.exitCode == 0) return;
        } catch (_) {}
      }
      throw Exception("解压失败: $e");
    }
  }

  void pauseTask(DownloadTask task) {
    if (task.status == "downloading") {
      task._client?.close();
      task._client = null;
      task.status = "paused";
      _emit();
    }
  }

  void resumeTask(DownloadTask task) {
    if (task.status == "paused") {
      task.status = "pending";
      _emit();
      _runDownload(task);
    }
  }

  void cancelTask(DownloadTask task) {
    if (task.status == "downloading" || task.status == "pending") {
      task._client?.close();
      task._client = null;
      task.status = "cancelled";
      task.error = "已取消";
      _emit();
      // Clean up temp file
      _cleanupTemp(task);
    }
  }

  void removeTask(DownloadTask task) {
    cancelTask(task);
    _tasks.remove(task);
    _emit();
  }

  Future<void> _cleanupTemp(DownloadTask task) async {
    try {
      final dir = await downloadDir;
      final tmp = File("$dir/.tmp_${task.versionId}_${task.fileName}");
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
  }

  void _emit() {
    _controller.add(List.unmodifiable(_tasks));
  }
}
