/// Scans local Steam library for installed games.
/// PC-only feature (Windows / Linux).

import "dart:convert";
import "dart:io";

import "package:file_picker/file_picker.dart";
import "package:http/http.dart" as http;

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

  PatchMatch({
    required this.appId,
    required this.gameName,
    required this.installDir,
    required this.patchAvailable,
    this.patchFilename,
    this.patchSize = 0,
  });

  factory PatchMatch.fromJson(Map<String, dynamic> json) => PatchMatch(
        appId: json["app_id"] ?? "",
        gameName: json["game_name"] ?? "",
        installDir: json["install_dir"] ?? "",
        patchAvailable: json["patch_available"] ?? false,
        patchFilename: json["patch_filename"],
        patchSize: json["patch_size"] ?? 0,
      );
}

class SteamService {
  /// Let user pick Steam steamapps directory.
  static Future<String?> pickSteamDir() async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: "选择 Steam 库 common 目录",
    );
    return result;
  }

  /// Scan a steamapps directory for installed games via appmanifest_*.acf files.
  static List<SteamGameInfo> scanInstalledGames(String commonDir) {
    final games = <SteamGameInfo>[];
    final dir = Directory(commonDir);

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
