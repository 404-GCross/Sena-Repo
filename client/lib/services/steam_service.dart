/// Scans local Steam library for installed games.
/// PC-only feature (Windows / Linux).

import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:file_picker/file_picker.dart";
import "package:flutter/services.dart" show rootBundle;
import "package:http/http.dart" as http;
import "package:path_provider/path_provider.dart";

import "api_client.dart";
import "logger_service.dart";

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
  final String? type;

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
    this.type,
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
        type: json["type"],
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

  // ── Active injection tracking (for pause/resume) ──

  static final Map<String, _InjectionState> _injections = {};

  static void cancelInjection(String appId) {
    _injections[appId]?._cancelled = true;
    _injections[appId]?._client?.close();
    _injections.remove(appId);
  }

  static void pauseInjection(String appId) {
    final state = _injections[appId];
    if (state != null) {
      state._client?.close();
      state._client = null;
    }
  }

  /// Download and inject a patch into the Steam game directory.
  /// Supports pause (close stream) and resume (re-download remaining bytes).
  static Stream<Map<String, dynamic>> injectPatch({
    required String appId,
    required String downloadUrl,
    required String installDir,
    required String patchFilename,
    required ApiClient api,
    String? patchDir,
    String? targetDir,
  }) async* {
    final isResume = _injections.containsKey(appId);
    final state = isResume ? _injections[appId]! : _InjectionState();
    _injections[appId] = state;
    state._cancelled = false;

    final httpClient = http.Client();
    state._client = httpClient;

    File? tmpFile = state._tmpFile;
    try {
      if (state._cancelled) return;

      // ── Build temp file path ──
      final workDir = (await getApplicationSupportDirectory()).path;
      final ext = patchFilename.contains(".") ? patchFilename.substring(patchFilename.lastIndexOf(".")) : "";
      tmpFile = File("$workDir/.patch_${appId}$ext");
      state._tmpFile = tmpFile;

      // ── Download: use http.get() — simple, reliable, no stream/pipe issues ──
      yield {"stage": "downloading", "progress": 0.0, "received": 0, "total": 0, "speed": 0};
      final getResp = await httpClient.get(Uri.parse(downloadUrl));
      if (state._cancelled) return;
      if (getResp.statusCode != 200) {
        yield {"error": "HTTP ${getResp.statusCode}"};
        _injections.remove(appId);
        return;
      }

      final bodyBytes = getResp.bodyBytes;
      final total = bodyBytes.length;
      final received = total;
      if (state._cancelled) return;

      await tmpFile.writeAsBytes(bodyBytes, flush: true);
      _log("download done: url=$downloadUrl path=${tmpFile.path} size=$total");

      yield {"stage": "extracting", "progress": 0.0, "received": received, "total": total, "speed": 0};
      final exe = await _getSevenZipPath();
      final tmpExtract = "${workDir}/.patch_ext_${appId}_${DateTime.now().millisecondsSinceEpoch}";
      await Directory(tmpExtract).create(recursive: true);

      final proc = await Process.start(exe, ["x", "-y", "-o$tmpExtract", tmpFile.path]);
      final exitCode = await proc.exitCode;
      if (state._cancelled) { await Directory(tmpExtract).delete(recursive: true); return; }
      if (exitCode != 0) {
        await Directory(tmpExtract).delete(recursive: true);
        final stderr = await proc.stderr.transform(utf8.decoder).join();
        yield {"error": stderr.isNotEmpty ? stderr : "解压失败 (exit $exitCode)"};
        _injections.remove(appId);
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
      String destDir = installDir;
      if (targetDir != null && targetDir!.isNotEmpty) {
        destDir = "$installDir${Platform.pathSeparator}$targetDir";
      }
      await Directory(destDir).create(recursive: true);
      await _copyMerge(sourceDir, destDir);

      await Directory(tmpExtract).delete(recursive: true);
      _injections.remove(appId);

      yield {"stage": "done", "progress": 1.0, "received": received, "total": total, "speed": 0};
    } catch (e) {
      if (!state._cancelled) {
        yield {"error": "$e"};
      }
      _injections.remove(appId);
    } finally {
      httpClient.close();
      state._client = null;
      if (tmpFile != null && (state._cancelled || _injections.containsKey(appId) == false)) {
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

  /// Update patch metadata in server's patches.json.
  static Future<void> updatePatch({
    required ApiClient api,
    required String appId,
    String? patchDir,
    String? targetDir,
    String? label,
    String? type,
    String? file,
  }) async {
    final body = <String, dynamic>{};
    if (patchDir != null) body["patch_dir"] = patchDir;
    if (targetDir != null) body["target_dir"] = targetDir;
    if (label != null) body["label"] = label;
    if (type != null) body["type"] = type;
    if (appId.isNotEmpty && appId != "null" && appId != "None") body["app_id"] = appId;
    if (file != null && file.isNotEmpty) body["file"] = file;
    if (body.isEmpty) return;

    // Use file as lookup key if app_id is unknown; otherwise use app_id
    final lookupKey = (appId.isNotEmpty && appId != "null" && appId != "None") ? appId : (file ?? appId);
    final resp = await http.put(
      Uri.parse("${api.baseUrl}/api/steam/patches/${Uri.encodeComponent(lookupKey)}"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200) {
      throw HttpException("Failed to update patch: ${resp.statusCode}");
    }
  }

  /// Fetch patch type keywords from server.
  static Future<Map<String, dynamic>> getTypeKeywords(ApiClient api) async {
    final resp = await http.get(
      Uri.parse("${api.baseUrl}/api/steam/patch-type-keywords"),
    );
    if (resp.statusCode != 200) {
      throw HttpException("Failed to load type keywords: ${resp.statusCode}");
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Save patch type keywords to server.
  static Future<void> saveTypeKeywords(ApiClient api, Map<String, dynamic> keywords) async {
    final resp = await http.put(
      Uri.parse("${api.baseUrl}/api/steam/patch-type-keywords"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({"keywords": keywords}),
    );
    if (resp.statusCode != 200) {
      throw HttpException("Failed to save type keywords: ${resp.statusCode}");
    }
  }

  /// Trigger server-side patch directory scan.
  static Future<Map<String, dynamic>> scanPatches(ApiClient api) async {
    final resp = await http.post(
      Uri.parse("${api.baseUrl}/api/steam/scan-patches"),
    );
    if (resp.statusCode == 200) {
      return jsonDecode(resp.body) as Map<String, dynamic>;
    }
    throw HttpException("Failed to scan patches: ${resp.statusCode}");
  }

  /// List all indexed patches from server.
  static Future<Map<String, dynamic>> listPatches(ApiClient api) async {
    final resp = await http.get(
      Uri.parse("${api.baseUrl}/api/steam/patches"),
    );
    if (resp.statusCode == 200) {
      return jsonDecode(resp.body) as Map<String, dynamic>;
    }
    throw HttpException("Failed to list patches: ${resp.statusCode}");
  }
}

/// Internal state for pause/resume support in patch injection.
class _InjectionState {
  http.Client? _client;
  File? _tmpFile;
  int _received = 0;
  bool _cancelled = false;
}

void _log(String msg) {
  LoggerService().info(msg);
}
