/// Steam non-Steam game import — add games to Steam library + import covers.
///
/// Uses Python vdf library (NSL approach) for reliable shortcuts.vdf manipulation.
/// Steam path from user-configured steamapps directory (SharedPreferences).

import "dart:convert";
import "dart:io";

import "package:http/http.dart" as http;
import "package:shared_preferences/shared_preferences.dart";

import "../services/logger_service.dart";
import "vdf_parser.dart"; // only for gridAppId CRC32 calculation

class SteamIntegrationResult {
  final bool success;
  final String message;
  SteamIntegrationResult(this.success, this.message);
}

class SteamIntegrationService {

  // ── Steam path resolution ──

  Future<String?> getSteamRoot() async {
    final steamapps = await getSteamappsDir();
    if (steamapps == null) return null;
    return Directory(steamapps).parent.path;
  }

  Future<String?> getSteamappsDir() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString("steamapps_dir") ??
        prefs.getString("steam_common_dir");
  }

  Future<void> setSteamappsDir(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("steamapps_dir", path);
  }

  Future<String?> getSteamUserId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString("steam_user_id");
  }

  Future<void> setSteamUserId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("steam_user_id", id);
  }

  Future<String?> findSteamUserId(String steamRoot) async {
    final userdata = Directory("$steamRoot${Platform.pathSeparator}userdata");
    if (!await userdata.exists()) return null;
    await for (final entry in userdata.list()) {
      final name = entry.uri.pathSegments.last;
      if (RegExp(r'^\d+$').hasMatch(name) && entry is Directory) {
        if (await Directory("${entry.path}${Platform.pathSeparator}config").exists()) return name;
      }
    }
    await for (final entry in userdata.list()) {
      final name = entry.uri.pathSegments.last;
      if (RegExp(r'^\d+$').hasMatch(name)) return name;
    }
    return null;
  }

  Future<({String root, String userId})?> resolveSteam() async {
    final root = await getSteamRoot();
    if (root == null) return null;
    var userId = await getSteamUserId();
    userId ??= await findSteamUserId(root);
    if (userId == null) return null;
    if (await getSteamUserId() == null) await setSteamUserId(userId);
    return (root: root, userId: userId);
  }

  // ── grid image management ──

  String _gridDir(String steamRoot, String userId) =>
      "${steamRoot}${Platform.pathSeparator}userdata${Platform.pathSeparator}$userId${Platform.pathSeparator}config${Platform.pathSeparator}grid";

  Future<bool> _importCover(String coverUrl, int gridAppId,
      String steamRoot, String userId) async {
    if (coverUrl.isEmpty) return false;
    final gridDir = Directory(_gridDir(steamRoot, userId));
    if (!await gridDir.exists()) await gridDir.create(recursive: true);
    final s = Platform.pathSeparator;
    final portraitFile = File("${gridDir.path}$s${gridAppId}p.jpg");
    final landscapeFile = File("${gridDir.path}$s$gridAppId.jpg");
    try {
      final resp = await http.get(Uri.parse(coverUrl)).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) return false;
      if (resp.bodyBytes.length < 1024) return false;
      await portraitFile.writeAsBytes(resp.bodyBytes);
      if (!await landscapeFile.exists()) await landscapeFile.writeAsBytes(resp.bodyBytes);
      return true;
    } catch (_) { return false; }
  }

  Future<bool> _importHeroToGrid(String heroUrl, int gridAppId,
      String steamRoot, String userId) async {
    if (heroUrl.isEmpty) return false;
    final gridDir = Directory(_gridDir(steamRoot, userId));
    if (!await gridDir.exists()) await gridDir.create(recursive: true);
    final s = Platform.pathSeparator;
    final landscapeFile = File("${gridDir.path}$s$gridAppId.jpg");
    try {
      final resp = await http.get(Uri.parse(heroUrl)).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) return false;
      if (resp.bodyBytes.length < 1024) return false;
      await landscapeFile.writeAsBytes(resp.bodyBytes);
      final heroFile = File("${gridDir.path}$s${gridAppId}_hero.jpg");
      if (!await heroFile.exists()) await heroFile.writeAsBytes(resp.bodyBytes);
      return true;
    } catch (_) { return false; }
  }

  // ── Main API ──

  Future<SteamIntegrationResult> addToSteam({
    required String gameName,
    required String exePath,
    String coverUrl = "",
    String heroUrl = "",
    String? startDir,
    String? iconPath,
  }) async {
    final steamapps = await getSteamappsDir();
    if (steamapps == null) {
      return SteamIntegrationResult(false, "未配置 Steam 目录。请先在设置中选 steamapps 文件夹。");
    }
    final steam = await resolveSteam();
    if (steam == null) {
      return SteamIntegrationResult(false,
        "找不到 Steam 用户 ID。请在 $steamapps\\..\\userdata\\ 下找到你的纯数字用户文件夹名。");
    }
    if (!await File(exePath).exists()) {
      return SteamIntegrationResult(false, "游戏文件不存在:\n$exePath");
    }

    final start = startDir ?? File(exePath).parent.path;
    final icon = iconPath ?? exePath;

    try {
      final scriptPath = "../server/add_steam_game.py";
      final py = Platform.isWindows ? "python" : "python3";
      final result = await Process.run(py, [
        scriptPath,
        "--steamroot", steam.root,
        "--userid", steam.userId,
        "--appname", gameName,
        "--exe", exePath,
        "--startdir", start,
        "--icon", icon,
      ]);
      if (result.exitCode != 0) {
        final err = result.stderr.toString().trim();
        return SteamIntegrationResult(false, err.isNotEmpty ? err : "add_steam_game.py failed");
      }
      final output = jsonDecode(result.stdout.toString().trim()) as Map<String, dynamic>;
      final msg = output["message"]?.toString() ?? "done";

      final gridId = gridAppId(gameName, exePath);
      if (coverUrl.isNotEmpty) await _importCover(coverUrl, gridId, steam.root, steam.userId);
      if (heroUrl.isNotEmpty) await _importHeroToGrid(heroUrl, gridId, steam.root, steam.userId);

      return SteamIntegrationResult(output["success"] == true, msg);
    } catch (e) {
      return SteamIntegrationResult(false, "add_steam_game.py error: $e");
    }
  }
}
