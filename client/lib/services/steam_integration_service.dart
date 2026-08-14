/// Steam non-Steam game import — add games to Steam library + import covers.
///
/// Uses Python vdf library (NSL approach) for reliable shortcuts.vdf manipulation.
/// Steam path from user-configured steamapps directory (SharedPreferences).

import "dart:convert";
import "dart:io";

import "logged_http.dart" as http;
import "package:shared_preferences/shared_preferences.dart";

import "../services/logger_service.dart";
import "api_client.dart";
import "vdf_parser.dart"; // only for gridAppId CRC32 calculation

class SteamIntegrationResult {
  final bool success;
  final String message;
  final String? launchKind;
  final String? launchId;
  final int? shortcutAppId;
  final String? steamUrl;
  final bool existingShortcut;

  SteamIntegrationResult(
    this.success,
    this.message, {
    this.launchKind,
    this.launchId,
    this.shortcutAppId,
    this.steamUrl,
    this.existingShortcut = false,
  });
}

class SteamNativeGameInfo {
  final String appId;
  final String name;
  final String installPath;

  SteamNativeGameInfo({
    required this.appId,
    required this.name,
    required this.installPath,
  });
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
    final loginUserId = await _findRecentSteamUserIdFromLoginUsers(steamRoot);
    if (loginUserId != null) return loginUserId;

    final userdata = Directory("$steamRoot${Platform.pathSeparator}userdata");
    if (!await userdata.exists()) return null;
    final candidates = <({String id, DateTime modified})>[];
    await for (final entry in userdata.list()) {
      final name = _entityName(entry);
      if (RegExp(r'^\d+$').hasMatch(name) && entry is Directory) {
        final config = Directory("${entry.path}${Platform.pathSeparator}config");
        if (await config.exists()) {
          DateTime modified;
          try {
            final shortcuts = File("${config.path}${Platform.pathSeparator}shortcuts.vdf");
            modified = await shortcuts.exists()
                ? await shortcuts.lastModified()
                : await config.lastModified();
          } catch (_) {
            modified = DateTime.fromMillisecondsSinceEpoch(0);
          }
          candidates.add((id: name, modified: modified));
        }
      }
    }
    if (candidates.isNotEmpty) {
      candidates.sort((a, b) => b.modified.compareTo(a.modified));
      return candidates.first.id;
    }
    await for (final entry in userdata.list()) {
      final name = _entityName(entry);
      if (RegExp(r'^\d+$').hasMatch(name)) return name;
    }
    return null;
  }

  String _entityName(FileSystemEntity entry) {
    return entry.path
        .split(Platform.pathSeparator)
        .where((part) => part.isNotEmpty)
        .last;
  }

  Future<String?> _findRecentSteamUserIdFromLoginUsers(String steamRoot) async {
    final file = File(
      "$steamRoot${Platform.pathSeparator}config${Platform.pathSeparator}loginusers.vdf",
    );
    if (!await file.exists()) return null;
    try {
      final content = await file.readAsString();
      final userBlock = RegExp(
        r'"(\d{8,})"\s*\{([\s\S]*?)(?=\n\s*"\d{8,}"\s*\{|\n\s*\}\s*\}\s*$)',
        multiLine: true,
      );
      String? fallback;
      for (final match in userBlock.allMatches(content)) {
        final steamId = match.group(1);
        final body = match.group(2) ?? "";
        if (steamId == null) continue;
        final userId = _steamIdToUserdataId(steamId);
        final config = Directory(
          "$steamRoot${Platform.pathSeparator}userdata${Platform.pathSeparator}$userId${Platform.pathSeparator}config",
        );
        if (!await config.exists()) continue;
        fallback ??= userId;
        if (RegExp(r'"MostRecent"\s+"1"').hasMatch(body)) return userId;
      }
      return fallback;
    } catch (_) {
      return null;
    }
  }

  String _steamIdToUserdataId(String value) {
    final id = BigInt.tryParse(value);
    if (id == null) return value;
    final steamId64Offset = BigInt.parse("76561197960265728");
    if (id > steamId64Offset) return (id - steamId64Offset).toString();
    return value;
  }

  Future<({String root, String userId})?> resolveSteam() async {
    final root = await getSteamRoot();
    if (root == null) return null;
    final storedUserId = await getSteamUserId();
    var userId = storedUserId;
    if (userId != null && !await _steamUserConfigExists(root, userId)) {
      userId = null;
    }
    userId ??= await findSteamUserId(root);
    if (userId == null) return null;
    if (storedUserId != userId) await setSteamUserId(userId);
    return (root: root, userId: userId);
  }

  Future<bool> _steamUserConfigExists(String steamRoot, String userId) async {
    final config = Directory(
      "$steamRoot${Platform.pathSeparator}userdata${Platform.pathSeparator}$userId${Platform.pathSeparator}config",
    );
    return config.exists();
  }

  // ── grid image management ──

  String _gridDir(String steamRoot, String userId) =>
      "${steamRoot}${Platform.pathSeparator}userdata${Platform.pathSeparator}$userId${Platform.pathSeparator}config${Platform.pathSeparator}grid";

  Future<bool> _importCover(String coverUrl, String gridAppId,
      String steamRoot, String userId) async {
    if (coverUrl.isEmpty) return false;
    final gridDir = Directory(_gridDir(steamRoot, userId));
    if (!await gridDir.exists()) await gridDir.create(recursive: true);
    final s = Platform.pathSeparator;
    final portraitFile = File("${gridDir.path}$s${gridAppId}p.jpg");
    final landscapeFile = File("${gridDir.path}$s$gridAppId.jpg");
    try {
      final resp = await http.get(
        Uri.parse(coverUrl),
        headers: coverUrl.contains("/api/files/") ? mediaAuthHeaders : null,
      ).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) return false;
      if (resp.bodyBytes.length < 1024) return false;
      await portraitFile.writeAsBytes(resp.bodyBytes);
      if (!await landscapeFile.exists()) await landscapeFile.writeAsBytes(resp.bodyBytes);
      return true;
    } catch (_) { return false; }
  }

  Future<bool> _importHeroToGrid(String heroUrl, String gridAppId,
      String steamRoot, String userId) async {
    if (heroUrl.isEmpty) return false;
    final gridDir = Directory(_gridDir(steamRoot, userId));
    if (!await gridDir.exists()) await gridDir.create(recursive: true);
    final s = Platform.pathSeparator;
    final landscapeFile = File("${gridDir.path}$s$gridAppId.jpg");
    try {
      final resp = await http.get(
        Uri.parse(heroUrl),
        headers: heroUrl.contains("/api/files/") ? mediaAuthHeaders : null,
      ).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) return false;
      if (resp.bodyBytes.length < 1024) return false;
      await landscapeFile.writeAsBytes(resp.bodyBytes);
      final heroFile = File("${gridDir.path}$s${gridAppId}_hero.jpg");
      if (!await heroFile.exists()) await heroFile.writeAsBytes(resp.bodyBytes);
      return true;
    } catch (_) { return false; }
  }

  // ── Python discovery ──

  /// Resolve a working Python intepreter.
  ///
  /// Windows: exe-relative "python/" first (bundled with app), then PATH.
  /// Other: system "python3" / "python".
  Future<String?> _resolvePython() async {
    if (Platform.isWindows) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;

      // 1. Bundled alongside exe (release install)
      var bundled = "$exeDir${Platform.pathSeparator}python${Platform.pathSeparator}python.exe";
      if (await File(bundled).exists()) return bundled;

      // 2. Project root (flutter run debug: CWD is client/)
      bundled = "python${Platform.pathSeparator}python.exe";
      if (await File(bundled).exists()) return bundled;
    }

    // 3. System PATH
    final candidates = Platform.isWindows
        ? ["py", "python", "python3"]
        : ["python3", "python"];
    for (final name in candidates) {
      try {
        final result = await Process.run(name, ["--version"]);
        if (result.exitCode == 0) return name;
      } catch (_) {}
    }

    return null;
  }

  // ── Script resolution ──

  /// Resolve path to add_steam_game.py.
  /// Release: bundled alongside exe.
  /// Debug (flutter run): CWD is client/, script is at ../server/.
  String _resolveScriptPath() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final bundled = "$exeDir${Platform.pathSeparator}add_steam_game.py";
    if (File(bundled).existsSync()) return bundled;
    // Fallback for flutter run (CWD = client/)
    return "../server/add_steam_game.py";
  }

  Future<bool> _isSteamRunning() async {
    try {
      final result = Platform.isWindows
          ? await Process.run("tasklist", ["/FI", "IMAGENAME eq steam.exe"])
          : await Process.run("pgrep", ["-x", "steam"]);
      if (Platform.isWindows) {
        return result.exitCode == 0 &&
            result.stdout.toString().toLowerCase().contains("steam.exe");
      }
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<SteamNativeGameInfo?> findNativeGameForPath(String targetPath) async {
    final steamapps = await getSteamappsDir();
    if (steamapps == null) return null;
    final normalizedTarget = _normalizeComparablePath(targetPath);
    final libraryDirs = await _steamappsLibraryDirs(steamapps);
    for (final steamappsDir in libraryDirs) {
      final dir = Directory(steamappsDir);
      if (!await dir.exists()) continue;
      await for (final entry in dir.list()) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.last;
        if (!name.startsWith("appmanifest_") || !name.endsWith(".acf")) {
          continue;
        }
        try {
          final content = await entry.readAsString();
          final appId = _extractAcfValue(content, "appid");
          final gameName = _extractAcfValue(content, "name");
          final installDir = _extractAcfValue(content, "installdir");
          if (appId == null || gameName == null || installDir == null) {
            continue;
          }
          final installPath = _joinPath(steamappsDir, ["common", installDir]);
          final normalizedInstall = _normalizeComparablePath(installPath);
          if (_isSameOrChildPath(normalizedTarget, normalizedInstall)) {
            return SteamNativeGameInfo(
              appId: appId,
              name: gameName,
              installPath: installPath,
            );
          }
        } catch (_) {}
      }
    }
    return null;
  }

  Future<List<String>> _steamappsLibraryDirs(String configuredSteamapps) async {
    final dirs = <String>{configuredSteamapps};
    final libraryFolders = File(_joinPath(configuredSteamapps, ["libraryfolders.vdf"]));
    if (!await libraryFolders.exists()) return dirs.toList();
    try {
      final content = await libraryFolders.readAsString();
      final pathMatches = RegExp(r'"path"\s+"([^"]+)"').allMatches(content);
      for (final match in pathMatches) {
        final raw = match.group(1);
        if (raw == null || raw.isEmpty) continue;
        final libraryRoot = raw.replaceAll("\\\\", "\\").replaceAll("\\/", "/");
        dirs.add(_joinPath(libraryRoot, ["steamapps"]));
      }
    } catch (_) {}
    return dirs.toList();
  }

  String? _extractAcfValue(String content, String key) {
    final match = RegExp('"$key"\\s+"([^"]+)"').firstMatch(content);
    return match?.group(1);
  }

  String _joinPath(String root, List<String> parts) {
    var path = root;
    for (final part in parts) {
      path = path.endsWith(Platform.pathSeparator)
          ? "$path$part"
          : "$path${Platform.pathSeparator}$part";
    }
    return path;
  }

  String _normalizeComparablePath(String path) {
    var normalized = path.replaceAll("\\", "/");
    while (normalized.endsWith("/") && normalized.length > 1) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  bool _isSameOrChildPath(String child, String parent) {
    return child == parent || child.startsWith("$parent/");
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
    if (!await File(exePath).exists()) {
      return SteamIntegrationResult(false, "游戏文件不存在:\n$exePath");
    }

    final nativeGame = await findNativeGameForPath(exePath);
    if (nativeGame != null) {
      return SteamIntegrationResult(
        true,
        "'${nativeGame.name}' 已是 Steam 原生游戏，无需创建非 Steam 快捷方式。",
        launchKind: "native",
        launchId: nativeGame.appId,
        steamUrl: "steam://rungameid/${nativeGame.appId}",
      );
    }

    final steam = await resolveSteam();
    if (steam == null) {
      return SteamIntegrationResult(false,
        "找不到 Steam 用户 ID。请在 $steamapps\\..\\userdata\\ 下找到你的纯数字用户文件夹名。");
    }

    final py = await _resolvePython();
    if (py == null) {
      return SteamIntegrationResult(false,
        Platform.isWindows
            ? "未找到 Python 运行环境。请检查程序目录下 python/ 是否存在。"
            : "未找到 Python。请运行: apt install python3 或 brew install python3");
    }

    final start = startDir ?? File(exePath).parent.path;
    final icon = iconPath ?? exePath;

    if (await _isSteamRunning()) {
      return SteamIntegrationResult(
        false,
        "Steam 正在运行。请完全退出 Steam 后再导入，否则 shortcuts.vdf 可能会被 Steam 覆盖。",
      );
    }

    try {
      final scriptPath = _resolveScriptPath();
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
      final gridId = output["grid_id"]?.toString() ?? gridAppId(gameName, exePath).toString();
      final shortcutAppId = _readNullableInt(output["shortcut_app_id"]);
      final launchId = output["launch_id"]?.toString();
      final steamUrl = output["steam_url"]?.toString();
      final artworkIds = <String>{gridId};
      if (launchId != null && launchId.isNotEmpty) artworkIds.add(launchId);

      var coverOk = false;
      var heroOk = false;
      if (coverUrl.isNotEmpty) {
        for (final artworkId in artworkIds) {
          coverOk =
              await _importCover(coverUrl, artworkId, steam.root, steam.userId) ||
              coverOk;
        }
      }
      if (heroUrl.isNotEmpty) {
        for (final artworkId in artworkIds) {
          heroOk =
              await _importHeroToGrid(heroUrl, artworkId, steam.root, steam.userId) ||
              heroOk;
        }
      }

      String fullMsg = msg;
      if (!coverOk && coverUrl.isNotEmpty) fullMsg += "（封面导入失败）";
      if (!heroOk && heroUrl.isNotEmpty) fullMsg += "（背景导入失败）";

      return SteamIntegrationResult(
        output["success"] == true,
        fullMsg,
        launchKind: "shortcut",
        launchId: launchId,
        shortcutAppId: shortcutAppId,
        steamUrl: steamUrl,
        existingShortcut: output["existing"] == true,
      );
    } catch (e) {
      return SteamIntegrationResult(false, "add_steam_game.py error: $e");
    }
  }

  int? _readNullableInt(dynamic value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }
}
