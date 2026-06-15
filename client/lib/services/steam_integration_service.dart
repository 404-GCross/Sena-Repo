/// Steam non-Steam game import — add games to Steam library + import covers.
///
/// Uses the user-configured steamapps directory (SharedPreferences "steamapps_dir"
/// or legacy "steam_common_dir") to locate Steam root and userdata.

import "dart:io";

import "package:http/http.dart" as http;
import "package:shared_preferences/shared_preferences.dart";

import "../services/logger_service.dart";
import "vdf_parser.dart";

class SteamIntegrationResult {
  final bool success;
  final String message;
  SteamIntegrationResult(this.success, this.message);
}

class SteamIntegrationService {

  // ── Steam path resolution ──

  /// Get the Steam root directory (parent of steamapps/).
  Future<String?> getSteamRoot() async {
    final steamapps = await getSteamappsDir();
    if (steamapps == null) return null;
    final dir = Directory(steamapps);
    // steamapps is a subdirectory of the Steam installation
    return dir.parent.path;
  }

  /// Get the configured steamapps directory.
  Future<String?> getSteamappsDir() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString("steamapps_dir") ??
        prefs.getString("steam_common_dir");
  }

  /// Save the chosen steamapps directory.
  Future<void> setSteamappsDir(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("steamapps_dir", path);
  }

  /// Find the first Steam user ID by scanning userdata/ for numeric folders.
  Future<String?> findSteamUserId(String steamRoot) async {
    final userdata = Directory("$steamRoot${Platform.pathSeparator}userdata");
    LoggerService().info("steam:[SenaRepo] Looking for userdata at: ${userdata.path}");
    if (!await userdata.exists()) {
      LoggerService().info("steam:[SenaRepo] userdata NOT FOUND at: ${userdata.path}");
      return null;
    }
    LoggerService().info("steam:[SenaRepo] userdata exists, scanning...");
    await for (final entry in userdata.list()) {
      LoggerService().info("steam:[SenaRepo] Found entry: ${entry.path} isDir=${entry is Directory}");
      final name = entry.uri.pathSegments.last;
      if (RegExp(r'^\d+$').hasMatch(name) && entry is Directory) {
        if (await Directory("${entry.path}${Platform.pathSeparator}config").exists()) {
          return name;
        }
      }
    }
    // Fallback: any numeric folder
    await for (final entry in userdata.list()) {
      final name = entry.uri.pathSegments.last;
      if (RegExp(r'^\d+$').hasMatch(name)) return name;
    }
    return null;
  }

  /// Resolve steam root + user id. Returns null if not configured.
  Future<({String root, String userId})?> resolveSteam() async {
    final root = await getSteamRoot();
    if (root == null) return null;
    final userId = await findSteamUserId(root);
    if (userId == null) return null;
    return (root: root, userId: userId);
  }

  // ── shortcuts.vdf manipulation ──

  /// Path to shortcuts.vdf for the given user.
  String _shortcutsPath(String steamRoot, String userId) =>
      "${steamRoot}${Platform.pathSeparator}userdata${Platform.pathSeparator}$userId${Platform.pathSeparator}config${Platform.pathSeparator}shortcuts.vdf";

  /// Read existing shortcuts.
  List<VdfShortcut> _readShortcuts(String steamRoot, String userId) {
    final path = _shortcutsPath(steamRoot, userId);
    final file = File(path);
    if (!file.existsSync()) return [];
    try {
      return parseShortcutsVdf(file.readAsBytesSync().toList());
    } catch (_) {
      return [];
    }
  }

  /// Write shortcuts back to disk.
  void _writeShortcuts(String steamRoot, String userId, List<VdfShortcut> entries) {
    final path = _shortcutsPath(steamRoot, userId);
    final dir = File(path).parent;
    if (!dir.existsSync()) dir.createSync(recursive: true);
    File(path).writeAsBytesSync(writeShortcutsVdf(entries));
  }

  // ── grid image management ──

  /// Path to the grid directory for the given user.
  String _gridDir(String steamRoot, String userId) =>
      "${steamRoot}${Platform.pathSeparator}userdata${Platform.pathSeparator}$userId${Platform.pathSeparator}config${Platform.pathSeparator}grid";

  /// Copy a cover image from [coverUrl] to the Steam grid directory.
  /// The image is saved as <gridAppId>p.jpg (portrait) for use in Steam library.
  Future<bool> _importCover(String coverUrl, int gridAppId,
      String steamRoot, String userId) async {
    if (coverUrl.isEmpty) return false;
    final gridDir = Directory(_gridDir(steamRoot, userId));
    if (!await gridDir.exists()) await gridDir.create(recursive: true);

    // Try portrait first, then landscape
    final s = Platform.pathSeparator;
    final portraitFile = File("${gridDir.path}$s${gridAppId}p.jpg");
    final landscapeFile = File("${gridDir.path}$s$gridAppId.jpg");

    // Download and save
    try {
      final resp = await http.get(Uri.parse(coverUrl)).timeout(
          const Duration(seconds: 30));
      if (resp.statusCode != 200) return false;
      if (resp.bodyBytes.length < 1024) return false; // too small, probably placeholder

      await portraitFile.writeAsBytes(resp.bodyBytes);
      // Also save landscape copy if it doesn't exist yet
      if (!await landscapeFile.exists()) {
        await landscapeFile.writeAsBytes(resp.bodyBytes);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Download and save a hero/landscape image to the Steam grid as landscape art.
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
      // Also save hero as the new library hero if Steam supports it
      final heroFile = File("${gridDir.path}$s${gridAppId}_hero.jpg");
      if (!await heroFile.exists()) {
        await heroFile.writeAsBytes(resp.bodyBytes);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── Main API ──

  /// Add a game as a non-Steam game in the user's Steam library.
  ///
  /// [gameName]  — display name in Steam library.
  /// [exePath]   — path to the game executable (version file).
  /// [coverUrl]  — URL of the cover image to import into Steam grid.
  /// [startDir]  — working directory (defaults to exe's parent).
  /// [iconPath]  — path to icon file (optional, defaults to exe).
  Future<SteamIntegrationResult> addToSteam({
    required String gameName,
    required String exePath,
    String coverUrl = "",
    String heroUrl = "",
    String? startDir,
    String? iconPath,
  }) async {
    // Validate
    final steamapps = await getSteamappsDir();
    if (steamapps == null) {
      return SteamIntegrationResult(false, "未配置 Steam 目录。请先在设置中选 steamapps 文件夹。");
    }
    final steam = await resolveSteam();
    if (steam == null) {
      return SteamIntegrationResult(false, "Steam 目录已选 ($steamapps)，但未找到 userdata 用户文件夹。请确认 Steam 已登录过。");
    }
    if (!await File(exePath).exists()) {
      return SteamIntegrationResult(false, "游戏文件不存在:\n$exePath");
    }

    final start = startDir ?? File(exePath).parent.path;
    final icon = iconPath ?? exePath;

    try {
      // Read existing shortcuts
      final entries = _readShortcuts(steam.root, steam.userId);

      // Check if already added (same exe path)
      final existing = entries.where((e) =>
        e.data["exe"]?.toString() == exePath
      );
      if (existing.isNotEmpty) {
        // Still update cover if provided
        if (coverUrl.isNotEmpty) {
          final gridId = gridAppId(gameName, exePath);
          await _importCover(coverUrl, gridId, steam.root, steam.userId);
        }
        return SteamIntegrationResult(true, "「$gameName」已在 Steam 库中。${coverUrl.isNotEmpty ? "封面已更新。" : ""}");
      }

      // Build shortcut entry — use Steam's CRC32-based appid (same as grid ID)
      final appid = gridAppId(gameName, exePath);
      final data = <String, dynamic>{
        "appname": gameName,
        "exe": exePath,
        "StartDir": start,
        "icon": icon,
        "ShortcutPath": "",
        "LaunchOptions": "",
        "IsHidden": 0,
        "AllowDesktopConfig": 1,
        "AllowOverlay": 1,
        "OpenVR": 0,
        "Devkit": 0,
        "DevkitGameID": "",
        "DevkitOverrideAppID": 0,
        "LastPlayTime": 0,
        "FlatpakAppID": "",
      };

      entries.add(VdfShortcut(appid: appid, data: data));

      // Write shortcuts.vdf
      _writeShortcuts(steam.root, steam.userId, entries);

      // Import cover (portrait) + hero (landscape) to Steam grid
      final gridId = gridAppId(gameName, exePath);
      if (coverUrl.isNotEmpty) {
        await _importCover(coverUrl, gridId, steam.root, steam.userId);
      }
      if (heroUrl.isNotEmpty) {
        await _importHeroToGrid(heroUrl, gridId, steam.root, steam.userId);
      }

      return SteamIntegrationResult(true, "「$gameName」已添加到 Steam 库！\n重启 Steam 后生效。");
    } catch (e) {
      return SteamIntegrationResult(false, "添加失败: $e");
    }
  }

}
