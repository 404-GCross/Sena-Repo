/// Scans local Steam library for installed games.
/// PC-only feature (Windows / Linux).

import "dart:convert";
import "dart:io";

import "package:file_picker/file_picker.dart";
import "package:http/http.dart" as http;

import "api_client.dart";
import "download_service.dart";

class SteamGameInfo {
  final String appId;
  String name;
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
      } catch (_) {}
    }
    return games;
  }

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

  /// Resolve Chinese game names for a list of AppIDs via server Steam API.
  static Future<Map<String, String>> resolveGameNames(
    ApiClient api, List<String> appids,
  ) async {
    if (appids.isEmpty) return {};
    try {
      final resp = await http.post(
        Uri.parse("${api.baseUrl}/api/steam/game-names"),
        headers: {"Content-Type": "application/json", ...api.headers},
        body: jsonEncode({"appids": appids}),
      );
      if (resp.statusCode == 200) {
        return Map<String, String>.from(jsonDecode(resp.body) as Map);
      }
    } catch (_) {}
    return {};
  }

  /// Send scanned games to server for patch matching.
  static Future<List<PatchMatch>> checkPatches(
    ApiClient api, List<SteamGameInfo> games,
  ) async {
    final body = jsonEncode({"games": games.map((g) => g.toJson()).toList()});
    final resp = await http.post(
      Uri.parse("${api.baseUrl}/api/steam/scan"),
      headers: {"Content-Type": "application/json", ...api.headers},
      body: body,
    );
    if (resp.statusCode != 200) throw HttpException("Failed to check patches: ${resp.statusCode}");
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
    final lookupKey = (appId.isNotEmpty && appId != "null" && appId != "None") ? appId : (file ?? appId);
    final resp = await http.put(
      Uri.parse("${api.baseUrl}/api/steam/patches/${Uri.encodeComponent(lookupKey)}"),
      headers: {"Content-Type": "application/json", ...api.headers},
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200) throw HttpException("Failed to update patch: ${resp.statusCode}");
  }

  /// Trigger server-side patch directory scan.
  static Future<Map<String, dynamic>> scanPatches(ApiClient api) async {
    final resp = await http.post(Uri.parse("${api.baseUrl}/api/steam/scan-patches"), headers: api.headers);
    if (resp.statusCode == 200) return jsonDecode(resp.body) as Map<String, dynamic>;
    throw HttpException("Failed to scan patches: ${resp.statusCode}");
  }

  /// List all indexed patches from server.
  static Future<Map<String, dynamic>> listPatches(ApiClient api) async {
    final resp = await http.get(Uri.parse("${api.baseUrl}/api/steam/patches"), headers: api.headers);
    if (resp.statusCode == 200) return jsonDecode(resp.body) as Map<String, dynamic>;
    throw HttpException("Failed to list patches: ${resp.statusCode}");
  }

  /// Fetch patch type keywords from server.
  static Future<Map<String, dynamic>> getTypeKeywords(ApiClient api) async {
    final resp = await http.get(Uri.parse("${api.baseUrl}/api/steam/patch-type-keywords"), headers: api.headers);
    if (resp.statusCode != 200) throw HttpException("Failed to load type keywords: ${resp.statusCode}");
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Save patch type keywords to server.
  static Future<void> saveTypeKeywords(ApiClient api, Map<String, dynamic> keywords) async {
    final resp = await http.put(
      Uri.parse("${api.baseUrl}/api/steam/patch-type-keywords"),
      headers: {"Content-Type": "application/json", ...api.headers},
      body: jsonEncode({"keywords": keywords}),
    );
    if (resp.statusCode != 200) throw HttpException("Failed to save type keywords: ${resp.statusCode}");
  }

  // ── Injection (delegates to DownloadService's proven pipeline) ──

  static void cancelInjection(String appId) {
    // Managed by DownloadService internally
  }

  /// Download and inject a patch. Uses DownloadService's proven download+extract pipeline.
  /// [onProgress] receives download progress updates.
  static Future<Map<String, dynamic>> injectPatch({
    required String appId,
    required String downloadUrl,
    required String installDir,
    required String patchFilename,
    String? patchDir,
    String? targetDir,
    void Function(double progress, int received, int total, int speed, String stage)? onProgress,
  }) async {
    final (error, outputDir) = await DownloadService().downloadPatch(
      appId: appId,
      downloadUrl: downloadUrl,
      patchFilename: patchFilename,
      installDir: installDir,
      patchDir: patchDir,
      targetDir: targetDir,
      onProgress: onProgress,
    );
    if (error != null) return {"error": error};
    return {"stage": "done", "output": outputDir ?? installDir};
  }

}
