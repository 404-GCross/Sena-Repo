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
      // Don't overwrite paused/cancelled status — the user requested a stop
      if (task.status == "paused" || task.status == "cancelled") {
        return;
      }
      task.status = "failed";
      task.error = "$e";
      _emit();
    }
  }

  /// Download file with automatic retry + resume on network errors.
  /// Max 3 retries with exponential backoff (1s, 3s, 7s).
  Future<void> _downloadFile(
    DownloadTask task, File dest, void Function(double) onProgress,
  ) async {
    const maxRetries = 3;
    const backoffMs = [1000, 3000, 7000];

    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      // Stop if user paused or cancelled during backoff / before retry
      if (task.status == "paused" || task.status == "cancelled") return;

      // Validate temp file size matches our counter (crash recovery)
      if (task.receivedBytes > 0 && await dest.exists()) {
        final actualSize = await dest.length();
        if (actualSize != task.receivedBytes) {
          task.receivedBytes = actualSize;
        }
      } else if (task.receivedBytes > 0 && !await dest.exists()) {
        // Temp file was deleted — start fresh
        task.receivedBytes = 0;
        task.totalBytes = 0;
      }

      final client = http.Client();
      task._client = client;

      try {
        final request = http.Request("GET", Uri.parse(task.downloadUrl));

        // Resume from where we left off
        if (task.receivedBytes > 0 && await dest.exists()) {
          request.headers["Range"] = "bytes=${task.receivedBytes}-";
        }

        final response = await client.send(request);

        // Handle Range Not Satisfiable — file may already be complete
        if (response.statusCode == 416) {
          if (task.totalBytes > 0 && task.receivedBytes >= task.totalBytes) {
            return; // Already fully downloaded
          }
          // Server doesn't support resume, or file changed — restart
          task.receivedBytes = 0;
          task.totalBytes = 0;
          continue; // Retry without Range header
        }

        final isPartial = response.statusCode == 206;
        if (response.statusCode != 200 && response.statusCode != 206) {
          final body = await response.stream.bytesToString();
          throw Exception("下载失败 HTTP ${response.statusCode}: $body");
        }

        // If server responded 200 to a Range request, it doesn't support resume
        // — reset counter and start fresh
        if (task.receivedBytes > 0 && !isPartial) {
          task.receivedBytes = 0;
          task.totalBytes = 0;
        }

        final int cl = response.contentLength ?? 0;
        final int total = task.receivedBytes + cl;
        task.totalBytes = total > 0 ? total : task.totalBytes;
        int received = task.receivedBytes;
        final sink = dest.openWrite(
            mode: (isPartial || task.receivedBytes > 0)
                ? FileMode.append
                : FileMode.write);

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

        // Validate download completeness
        if (task.totalBytes > 0 && received < task.totalBytes) {
          throw Exception(
              "下载不完整：预期 ${task.totalBytes} bytes，"
              "实收 $received bytes "
              "(${((1 - received / task.totalBytes) * 100).toStringAsFixed(1)}% 丢失)");
        }
        if (received == 0 && task.totalBytes == 0) {
          throw Exception("下载失败：未收到任何数据，请检查服务器连接");
        }

        return; // ✅ Success
      } on http.ClientException catch (e) {
        if (task.status == "paused" || task.status == "cancelled") return;
        if (attempt < maxRetries) {
          task.status = "retrying";
          _emit();
          await Future.delayed(Duration(milliseconds: backoffMs[attempt]));
          if (task.status == "paused" || task.status == "cancelled") return;
          task.status = "downloading";
          _emit();
          continue;
        }
        throw Exception("网络中断，已重试 $maxRetries 次仍失败: $e");
      } on SocketException catch (e) {
        if (task.status == "paused" || task.status == "cancelled") return;
        if (attempt < maxRetries) {
          task.status = "retrying";
          _emit();
          await Future.delayed(Duration(milliseconds: backoffMs[attempt]));
          if (task.status == "paused" || task.status == "cancelled") return;
          task.status = "downloading";
          _emit();
          continue;
        }
        throw Exception("网络连接失败，已重试 $maxRetries 次仍失败: $e");
      } finally {
        client.close();
        task._client = null;
      }
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

  /// Parse 7za/7zz version string. Returns null if parsing fails.
  /// Version string example: "7-Zip (A) 26.01 Copyright (c) 1999-2026 Igor Pavlov"
  Future<int?> _get7zaVersion(String sevenZipPath) async {
    try {
      final result = await Process.run(sevenZipPath, [],
          stdoutEncoding: latin1, stderrEncoding: latin1);
      final output = '${result.stdout}${result.stderr}';
      final match = RegExp(r'7-Zip\b[^\d]*(\d+)\.(\d+)').firstMatch(output);
      if (match != null) {
        final major = int.parse(match.group(1)!);
        final minor = int.parse(match.group(2)!);
        return major * 100 + minor;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Minimum 7za version that supports RAR5 (15.06+ added RAR5).
  static const int _min7zaVersion = 1600;

  Future<String> _getSevenZipPath() async {
    if (_sevenZipPath != null) return _sevenZipPath!;
    final dir = await getApplicationSupportDirectory();
    final exeName = Platform.isWindows ? "7za.exe" : "7zz";
    final dest = File("${dir.path}/$exeName");

    // Check version of existing binary — replace if too old (< 16.00 = no RAR5)
    if (await dest.exists()) {
      final version = await _get7zaVersion(dest.path);
      if (version != null && version < _min7zaVersion) {
        // Delete all old 7za-related files so they get replaced
        for (final name in ["7za.exe", "7za.dll", "7zxa.dll", "7zz"]) {
          try {
            await File("${dir.path}/$name").delete();
          } catch (_) {}
        }
      }
    }

    if (!await dest.exists()) {
      // Try bundled asset first — extract exe + DLLs (overwrite always)
      bool bundledOk = false;
      try {
        for (final name in ["7za.exe", "7za.dll", "7zxa.dll"]) {
          try {
            final data = await rootBundle.load("assets/binaries/$name");
            final f = File("${dir.path}/$name");
            await f.writeAsBytes(data.buffer.asUint8List());
          } catch (_) {}
        }
        if (Platform.isLinux) {
          await Process.run("chmod", ["+x", dest.path]);
        }
        if (await dest.exists()) {
          bundledOk = true;
        }
      } catch (_) {}

      if (!bundledOk) {
        // Show setup dialog to user
        if (!_userSkippedSetup && _onSetupNeeded != null) {
          final proceed = await _onSetupNeeded!();
          if (!proceed) {
            _userSkippedSetup = true;
            throw Exception("用户取消了 7-Zip 安装。请手动安装 7-Zip 后再试。");
          }
          // Download 7za from official site
          try {
            if (Platform.isWindows) {
              // Windows: 7z2601-extra.7z contains 7za.exe + DLLs.
              // We can't extract .7z without 7za already present (chicken-and-egg),
              // so download and run the official installer instead.
              final installerUrl =
                  "https://www.7-zip.org/a/7z2601-x64.exe";
              final tmp = File("${dir.path}/_7z_installer.exe");
              final client = http.Client();
              try {
                final resp = await client.send(
                    http.Request("GET", Uri.parse(installerUrl)));
                if (resp.statusCode != 200) {
                  throw Exception("HTTP ${resp.statusCode}");
                }
                final sink = tmp.openWrite();
                await for (final chunk in resp.stream) {
                  sink.add(chunk);
                }
                await sink.flush();
                await sink.close();
                // Run installer silently, then copy 7za.exe from install dir
                final result = await Process.run(tmp.path, ["/S"]);
                if (result.exitCode == 0) {
                  // Try to find 7za.exe from common install locations
                  for (final progDir in [
                    "C:/Program Files/7-Zip",
                    r"C:\Program Files (x86)\7-Zip",
                  ]) {
                    final src = File("$progDir/7za.exe");
                    if (await src.exists()) {
                      await src.copy(dest.path);
                      // Also copy DLLs
                      for (final dll in ["7za.dll", "7zxa.dll"]) {
                        try {
                          await File("$progDir/$dll")
                              .copy("${dir.path}/$dll");
                        } catch (_) {}
                      }
                      break;
                    }
                  }
                }
                await tmp.delete();
              } finally {
                client.close();
              }
            } else {
              // Linux: download tar.xz and extract with tar
              final url = "https://www.7-zip.org/a/7z2409-linux-x64.tar.xz";
              final tmp = File("${dir.path}/_7z_dl");
              final client = http.Client();
              try {
                final resp = await client.send(
                    http.Request("GET", Uri.parse(url)));
                if (resp.statusCode != 200) {
                  throw Exception("HTTP ${resp.statusCode}");
                }
                final sink = tmp.openWrite();
                await for (final chunk in resp.stream) {
                  sink.add(chunk);
                }
                await sink.flush();
                await sink.close();
                await Process.run(
                    "tar", ["-xf", tmp.path, "-C", dir.path]);
                await tmp.delete();
              } finally {
                client.close();
              }
            }
          } catch (_) {
            throw Exception("7-Zip 下载失败。请手动安装 7-Zip 后再试。");
          }
        } else {
          throw Exception(
              "解压组件未就绪。请安装 7-Zip 或手动放置 $exeName 到 $dir");
        }
      }
    }

    if (!await dest.exists()) {
      throw Exception(
          "解压组件未就绪。请安装 7-Zip 或手动放置 $exeName 到 $dir");
    }

    _sevenZipPath = dest.path;
    return _sevenZipPath!;
  }

  Future<void> _extractWithSystemTool(String filePath, String outDir) async {
    try {
      final sevenZip = await _getSevenZipPath();
      final sevenZipDir = File(sevenZip).parent.path;
      final result = await Process.run(sevenZip, ["x", "-y", "-o$outDir", filePath],
          workingDirectory: sevenZipDir);
      if (result.exitCode != 0) {
        final err = (result.stderr.toString() + result.stdout.toString()).trim();
        throw Exception(err.isEmpty ? "7za exit code: ${result.exitCode}" : "7za: $err");
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
    if (task.status == "downloading" || task.status == "retrying") {
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
    if (task.status == "downloading" || task.status == "pending" || task.status == "retrying") {
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
