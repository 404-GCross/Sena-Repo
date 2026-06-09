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
  String status; // pending, downloading, extracting, done, failed
  double progress;
  String? error;
  String? outputPath;
  final DateTime startedAt;

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

  Future<DownloadTask> startDownload({
    required int gameId,
    required int versionId,
    required String fileName,
    required String downloadUrl,
    required String gameName,
    required String companyName,
  }) async {
    final task = DownloadTask(
      gameId: gameId, versionId: versionId, fileName: fileName,
      downloadUrl: downloadUrl, gameName: gameName, companyName: companyName,
    );
    _tasks.insert(0, task);
    _emit();

    try {
      final dir = await downloadDir;

      // Step 1: Download
      task.status = "downloading";
      _emit();

      final tmpFile = File("$dir/.tmp_${task.versionId}_${task.fileName}");
      await _downloadFile(task.downloadUrl, tmpFile, (progress) {
        task.progress = progress;
        _emit();
      });

      // Step 2: Extract
      task.status = "extracting";
      task.progress = 1.0;
      _emit();

      final subDir = companyName.isNotEmpty ? companyName : "_unknown";
      final gameDir = gameName.isNotEmpty ? gameName : task.fileName;
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

    return task;
  }

  Future<void> _downloadFile(
    String url, File dest, void Function(double) onProgress,
  ) async {
    final client = http.Client();
    try {
      final request = http.Request("GET", Uri.parse(url));
      final response = await client.send(request);
      final total = response.contentLength ?? 0;
      var received = 0;
      final sink = dest.openWrite();
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress(received / total);
      }
      await sink.flush();
      await sink.close();
    } finally {
      client.close();
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

  Future<String> _getSevenZipPath() async {
    if (_sevenZipPath != null) return _sevenZipPath!;
    final dir = await getApplicationSupportDirectory();
    final exeName = Platform.isWindows ? "7za.exe" : "7zz";
    final dest = File("${dir.path}/$exeName");

    if (!await dest.exists()) {
      // Extract bundled binary from assets
      try {
        final data = await rootBundle.load("assets/binaries/$exeName");
        await dest.writeAsBytes(data.buffer.asUint8List());
        if (Platform.isLinux) {
          await Process.run("chmod", ["+x", dest.path]);
        }
      } catch (_) {
        throw Exception("解压组件未就绪，请手动安装 7-Zip");
      }
    }

    _sevenZipPath = dest.path;
    return _sevenZipPath!;
  }

  Future<void> _extractWithSystemTool(String filePath, String outDir) async {
    try {
      final sevenZip = await _getSevenZipPath();
      final result = await Process.run(sevenZip, ["x", "-y", "-o$outDir", filePath]);
      if (result.exitCode != 0) {
        throw Exception(result.stderr.toString());
      }
    } catch (e) {
      // Fallback to system tools
      try {
        final result = await Process.run("7z", ["x", "-y", "-o$outDir", filePath]);
        if (result.exitCode == 0) return;
      } catch (_) {}
      try {
        final result = await Process.run("unar", ["-o", outDir, filePath]);
        if (result.exitCode == 0) return;
      } catch (_) {}
      throw Exception("解压失败。请确保 assets/binaries/ 下有 7za.exe(Windows) 或 7zz(Linux)");
    }
  }

  void removeTask(DownloadTask task) {
    _tasks.remove(task);
    _emit();
  }

  void _emit() {
    _controller.add(List.unmodifiable(_tasks));
  }
}
