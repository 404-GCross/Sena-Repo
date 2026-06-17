/// Scans local Steam library for installed games.
/// PC-only feature (Windows / Linux).

import "dart:convert";
import "dart:io";

import "package:file_picker/file_picker.dart";
import "package:flutter/services.dart" show rootBundle;
import "package:http/http.dart" as http;
import "package:path_provider/path_provider.dart";

import "api_client.dart";

class SteamGameInfo {
  final String appId;
  final String name;
  final String installDir;

  SteamGameInfo({required this.appId, required this.name, required this.installDir});

  Map<String, dynamic> toJson() => {
        "app_id": appId,
        "name": name,
        "install_dir": installDir,
      };
}

class PatchMatch {
  final String appId;
  final String gameName;
  final String installDir;
  final bool patchAvailable;
  final String? patchFilename;
  final int patchSize;
  final String? patchDir;
  final String? targetDir;
  final String? label;

  PatchMatch({
    required this.appId,
    required this.gameName,
    required this.installDir,
    required this.patchAvailable,
    this.patchFilename,
    this.patchSize = 0,
    this.patchDir,
    this.targetDir,
    this.label,
  });

  factory PatchMatch.fromJson(Map<String, dynamic> json) => PatchMatch(
        appId: json["app_id"] ?? "",
        gameName: json["game_name"] ?? "",
        installDir: json["install_dir"] ?? "",
        patchAvailable: json["patch_available"] ?? false,
        patchFilename: json["patch_filename"],
        patchSize: json["patch_size"] ?? 0,
        patchDir: json["patch_dir"],
        targetDir: json["target_dir"],
        label: json["label"],
      );
}

class SteamService {
  /// Let user pick Steam steamapps directory.
  static Future<String?> pickSteamDir() async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: "选择 Steam steamapps 目录",
    );
    return result;
  }

  /// Scan a steamapps directory for installed games via appmanifest_*.acf files.
  static List<SteamGameInfo> scanInstalledGames(String steamappsDir) {
    final games = <SteamGameInfo>[];
    final dir = Directory(steamappsDir);

    if (!dir.existsSync()) return games;

    for (final entry in dir.listSync()) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      if (!name.startsWith("appmanifest_") || !name.endsWith(".acf")) continue;

      try {
        final content = entry.readAsStringSync();
        final info = _parseAcf(content);
        if (info != null) games.add(info);
      } catch (_) {
        // Skip unreadable files
      }
    }

    return games;
  }

  /// Parse Valve ACF (KeyValues) format.
  static SteamGameInfo? _parseAcf(String content) {
    final appId = _extractValue(content, "appid");
    final gameName = _extractValue(content, "name");
    final installDir = _extractValue(content, "installdir");

    if (appId == null || gameName == null || installDir == null) return null;

    return SteamGameInfo(appId: appId, name: gameName, installDir: installDir);
  }

  static String? _extractValue(String content, String key) {
    final regex = RegExp('"$key"\\s+"([^"]+)"');
    final match = regex.firstMatch(content);
    return match?.group(1);
  }

  /// Download and inject a patch into the Steam game directory.
  /// Returns a stream of progress updates: (stage, progress, receivedBytes, totalBytes, speed).
  static Stream<Map<String, dynamic>> injectPatch({
    required String downloadUrl,
    required String installDir,
    required ApiClient api,
    String? patchDir,
    String? targetDir,
  }) async* {
    final httpClient = http.Client();
    File? tmpFile;
    try {
      // Phase 1: download
      final resp = await httpClient.send(http.Request("GET", Uri.parse(downloadUrl)));
      if (resp.statusCode != 200) {
        yield {"error": "HTTP ${resp.statusCode}"};
        return;
      }

      final total = resp.contentLength ?? 0;
      final supportDir = (await getApplicationSupportDirectory()).path;
      tmpFile = File("$supportDir/.patch_${DateTime.now().millisecondsSinceEpoch}");
      final sink = tmpFile.openWrite();

      int received = 0;
      int lastBytes = 0;
      DateTime lastTime = DateTime.now();
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now();
        final elapsed = now.difference(lastTime).inMilliseconds;
        int speed = 0;
        if (elapsed >= 500) {
          speed = ((received - lastBytes) * 1000 ~/ elapsed);
          lastBytes = received;
          lastTime = now;
        }
        yield {
          "stage": "downloading",
          "progress": total > 0 ? received / total : 0.0,
          "received": received,
          "total": total,
          "speed": speed,
        };
      }
      await sink.flush();
      await sink.close();

      // Phase 2: extract to temp, then merge to install dir
      yield {"stage": "extracting", "progress": 0.0, "received": received, "total": total, "speed": 0};
      final exe = await _getSevenZipPath();
      final tmpExtract = "${(await getApplicationSupportDirectory()).path}/.patch_extract_${DateTime.now().millisecondsSinceEpoch}";
      await Directory(tmpExtract).create(recursive: true);

      final proc = await Process.start(exe, ["x", "-y", "-o$tmpExtract", tmpFile.path]);
      final exitCode = await proc.exitCode;
      if (exitCode != 0) {
        await Directory(tmpExtract).delete(recursive: true);
        final stderr = await proc.stderr.transform(utf8.decoder).join();
        yield {"error": stderr.isNotEmpty ? stderr : "Extraction failed (exit $exitCode)"};
        return;
      }

      // Resolve source: patchDir > single subfolder > root
      String sourceDir = tmpExtract;
      if (patchDir != null && patchDir!.isNotEmpty) {
        final pd = "$tmpExtract${Platform.pathSeparator}$patchDir";
        if (await Directory(pd).exists()) sourceDir = pd;
      } else {
        final entries = Directory(tmpExtract).listSync();
        if (entries.length == 1 && entries.first is Directory) {
          sourceDir = entries.first.path;
        }
      }
      // Resolve target: targetDir > installDir root
      String destDir = installDir;
      if (targetDir != null && targetDir!.isNotEmpty) {
        destDir = "$installDir${Platform.pathSeparator}$targetDir";
      }
      await Directory(destDir).create(recursive: true);
      await _copyMerge(sourceDir, destDir);

      // Cleanup
      await Directory(tmpExtract).delete(recursive: true);

      yield {"stage": "done", "progress": 1.0, "received": received, "total": total, "speed": 0};
    } catch (e) {
      yield {"error": "$e"};
    } finally {
      httpClient.close();
      if (tmpFile != null) {
        try { await tmpFile.delete(); } catch (_) {}
      }
    }
  }

  /// Recursively copy/merge [from] into [to], overwriting existing files.
  static Future<void> _copyMerge(String from, String to) async {
    final target = Directory(to);
    if (!await target.exists()) await target.create(recursive: true);
    await for (final child in Directory(from).list()) {
      final name = child.uri.pathSegments.last;
      if (child is Directory) {
        await _copyMerge(child.path, "$to${Platform.pathSeparator}$name");
      } else if (child is File) {
        try { await child.copy("$to${Platform.pathSeparator}$name"); } catch (_) {}
      }
    }
  }

  static String? _sevenZipPath;
  static Future<String> _getSevenZipPath() async {
    if (_sevenZipPath != null) return _sevenZipPath!;
    final dir = await getApplicationSupportDirectory();
    final exeName = Platform.isWindows ? "7z.exe" : "7zz";
    final dest = File("${dir.path}/$exeName");
    if (!await dest.exists()) {
      // try bundled
      try {
        final data = await rootBundle.load("assets/binaries/$exeName");
        await dest.writeAsBytes(data.buffer.asUint8List());
        if (Platform.isAndroid) {
          await Process.run("/system/bin/chmod", ["+x", dest.path]);
        } else if (!Platform.isWindows) {
          await Process.run("chmod", ["+x", dest.path]);
        }
      } catch (_) {
        throw Exception("7z binary not found");
      }
    }
    _sevenZipPath = dest.path;
    return _sevenZipPath!;
  }

  /// Send scanned games to server for patch matching.
  static Future<List<PatchMatch>> checkPatches(
    ApiClient api,
    List<SteamGameInfo> games,
  ) async {
    final body = jsonEncode({
      "games": games.map((g) => g.toJson()).toList(),
    });

    final resp = await http.post(
      Uri.parse("${api.baseUrl}/api/steam/scan"),
      headers: {"Content-Type": "application/json"},
      body: body,
    );

    if (resp.statusCode != 200) {
      throw HttpException("Failed to check patches: ${resp.statusCode}");
    }

    final List<dynamic> data = jsonDecode(resp.body);
    return data.map((j) => PatchMatch.fromJson(j as Map<String, dynamic>)).toList();
  }
}
