/// Create desktop shortcuts for games with their cover as icon.
/// Windows: .lnk via PowerShell COM; Linux: .desktop file.

import "dart:io";

import "package:http/http.dart" as http;
import "package:path_provider/path_provider.dart";
import "package:shared_preferences/shared_preferences.dart";

class ShortcutService {
  /// Find a likely game executable in [dir], limited to [gameDir] if provided.
  static String? findExecutable(String dir, {String? gameName}) {
    // If a game-specific subdirectory exists, scan only that
    String scanDir = dir;
    if (gameName != null && gameName.isNotEmpty) {
      final gamePath = "$dir/$gameName";
      if (Directory(gamePath).existsSync()) {
        final gameExes = findAllExecutables(gamePath);
        if (gameExes.isNotEmpty) {
          final rootExe = gameExes.firstWhere(
            (f) => File(f).parent.path == gamePath,
            orElse: () => gameExes.first,
          );
          return rootExe;
        }
      }
    }
    // Fall back to scanning the whole output dir
    final all = findAllExecutables(scanDir);
    if (all.isEmpty) return null;
    final rootExe = all.firstWhere(
      (f) => File(f).parent.path == scanDir,
      orElse: () => all.first,
    );
    return rootExe;
  }

  /// Find all executable files in [dir], sorted by size descending.
  /// If [gameName] is provided and a matching subdirectory exists, scan only that.
  static List<String> findAllExecutables(String dir, {String? gameName}) {
    // First try the game-specific subdirectory if it exists
    if (gameName != null && gameName.isNotEmpty) {
      final gamePath = "$dir/$gameName";
      if (Directory(gamePath).existsSync()) {
        final gameExes = _scanExes(gamePath, gamePath);
        if (gameExes.isNotEmpty) return gameExes;
      }
    }
    // Fall back to scanning the whole output directory
    return _scanExes(dir, dir);
  }

  static List<String> _scanExes(String scanDir, String rootDir) {
    if (!Directory(scanDir).existsSync()) return [];
    try {
      final files = Directory(scanDir)
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((f) {
        final name = f.uri.pathSegments.last.toLowerCase();
        if (Platform.isWindows) return name.endsWith(".exe");
        if (name.endsWith(".exe")) return true;
        if (name.endsWith(".sh")) return true;
        return !name.contains(".") || name.endsWith(".x86_64") || name.endsWith(".bin");
      }).toList();

      if (files.isEmpty) return [];
      // Sort: root-level files first, then by size descending
      files.sort((a, b) {
        final aRoot = File(a.path).parent.path == scanDir;
        final bRoot = File(b.path).parent.path == scanDir;
        if (aRoot && !bRoot) return -1;
        if (!aRoot && bRoot) return 1;
        return b.lengthSync().compareTo(a.lengthSync());
      });
      return files.map((f) => f.path).toList();
    } catch (_) {
      return [];
    }
  }

  /// Download cover to a local path. Returns the local file path or null.
  static Future<String?> downloadCover(String coverUrl, String gameName) async {
    if (coverUrl.isEmpty) return null;
    try {
      final dir = await getApplicationSupportDirectory();
      final iconsDir = Directory("${dir.path}/shortcut_icons");
      if (!await iconsDir.exists()) await iconsDir.create(recursive: true);
      final ext = coverUrl.contains(".png") ? ".png" : ".jpg";
      final dest = File("${iconsDir.path}/${_safeName(gameName)}$ext");
      if (await dest.exists()) return dest.path; // Already cached

      final resp = await http.get(Uri.parse(coverUrl));
      if (resp.statusCode == 200) {
        await dest.writeAsBytes(resp.bodyBytes);
        // On Windows, try to convert to .ico using PowerShell
        if (Platform.isWindows) {
          return await _convertToIco(dest.path) ?? dest.path;
        }
        return dest.path;
      }
    } catch (_) {}
    return null;
  }

  /// Create a desktop shortcut.
  static Future<bool> createShortcut({
    required String gameName,
    required String exePath,
    required String? coverPath,
    String? workingDir,
  }) async {
    if (Platform.isWindows) {
      return await _createWindowsShortcut(gameName, exePath, coverPath, workingDir);
    }
    return false;
  }

  /// Escape a string for safe use inside a PowerShell double-quoted string.
  /// Backtick is the PowerShell escape char; backslash is literal and left as-is.
  static String _psEscape(String s) {
    return s
        .replaceAll('`', '``')
        .replaceAll('\$', '`\$')
        .replaceAll('"', '""');
  }

  static Future<bool> _createWindowsShortcut(
      String name, String target, String? iconPath, [String? workingDir]) async {
    final desktopDir = _desktopDir();
    if (desktopDir == null) return false;
    final lnkPath = "$desktopDir\\${_safeName(name)}.lnk";

    // Build PowerShell script to create shortcut (values escaped to prevent injection)
    final es = _psEscape; // shorthand
    final script = StringBuffer();
    script.writeln(r'$WshShell = New-Object -ComObject WScript.Shell');
    script.writeln(r'$Shortcut = $WshShell.CreateShortcut("' + es(lnkPath) + r'")');
    script.writeln(r'$Shortcut.TargetPath = "' + es(target) + r'"');
    script.writeln(r'$Shortcut.WorkingDirectory = "' +
        es(workingDir ?? File(target).parent.path) + r'"');
    if (iconPath != null && File(iconPath).existsSync()) {
      script.writeln(r'$Shortcut.IconLocation = "' + es(iconPath) + r'"');
    }
    script.writeln(r'$Shortcut.Save()');

    final result = await Process.run(
      "powershell", ["-NoProfile", "-Command", script.toString()],
    );
    if (result.exitCode != 0) {
      final err = (result.stderr as String?)?.trim() ?? "";
      if (err.isNotEmpty) throw Exception(err);
    }
    return File(lnkPath).existsSync();
  }

  static String? _customDir;
  static String? get customDesktopDir => _customDir;

  static Future<void> setCustomDesktopDir(String? dir) async {
    _customDir = dir;
    final prefs = await SharedPreferences.getInstance();
    if (dir != null) {
      await prefs.setString("shortcut_desktop_dir", dir);
    } else {
      await prefs.remove("shortcut_desktop_dir");
    }
  }

  static Future<void> loadCustomDesktopDir() async {
    final prefs = await SharedPreferences.getInstance();
    _customDir = prefs.getString("shortcut_desktop_dir");
  }

  static String? _desktopDir() {
    if (_customDir != null && _customDir!.isNotEmpty) return _customDir;
    final home = Platform.environment["HOME"] ??
        Platform.environment["USERPROFILE"];
    if (home == null) return null;
    return "$home/Desktop";
  }

  static String _safeName(String name) {
    return name.replaceAll(RegExp(r'[<>:"/\\|?*]'), "_").trim();
  }

  /// Try to convert an image to .ico on Windows using PowerShell.
  static Future<String?> _convertToIco(String imagePath) async {
    try {
      final icoPath = imagePath.replaceAll(RegExp(r'\.[^.]+$'), ".ico");
      if (File(icoPath).existsSync()) return icoPath;

      // Use PowerShell to convert (requires .NET)
      final script = '''
Add-Type -AssemblyName System.Drawing
\$img = [System.Drawing.Image]::FromFile("${imagePath.replaceAll('\\', '\\\\')}")
\$ico = [System.Drawing.Icon]::FromHandle((New-Object System.Drawing.Bitmap(\$img, 256, 256)).GetHicon())
\$fs = [System.IO.File]::OpenWrite("${icoPath.replaceAll('\\', '\\\\')}")
\$ico.Save(\$fs)
\$fs.Close()
\$img.Dispose()
''';
      final result = await Process.run(
        "powershell", ["-Command", script],
        runInShell: true,
      );
      if (result.exitCode == 0 && File(icoPath).existsSync()) return icoPath;
    } catch (_) {}
    return null;
  }
}
