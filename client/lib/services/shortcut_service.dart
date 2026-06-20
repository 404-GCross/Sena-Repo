/// Create desktop shortcuts for games with their cover as icon.
/// Windows: .lnk via PowerShell COM; Linux: .desktop file.

import "dart:io";

import "package:http/http.dart" as http;
import "package:path_provider/path_provider.dart";
import "package:shared_preferences/shared_preferences.dart";

class ShortcutService {
  /// Find a likely game executable in [dir]. Prefers root-level exe.
  static String? findExecutable(String dir) {
    final all = findAllExecutables(dir);
    if (all.isEmpty) return null;
    // Pick first root-level exe; fall back to first overall
    final rootExe = all.firstWhere(
      (f) => File(f).parent.path == dir,
      orElse: () => all.first,
    );
    return rootExe;
  }

  /// Find all executable files in [dir], sorted by size descending.
  static List<String> findAllExecutables(String dir) {
    if (!Directory(dir).existsSync()) return [];
    try {
      final files = Directory(dir)
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
        final aRoot = File(a.path).parent.path == dir;
        final bRoot = File(b.path).parent.path == dir;
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

  static Future<bool> _createWindowsShortcut(
      String name, String target, String? iconPath, [String? workingDir]) async {
    final desktopDir = _desktopDir();
    if (desktopDir == null) return false;
    final lnkPath = "$desktopDir\\${_safeName(name)}.lnk";

    // Build PowerShell script to create shortcut
    final script = StringBuffer();
    script.writeln(r'$WshShell = New-Object -ComObject WScript.Shell');
    script.writeln(r'$Shortcut = $WshShell.CreateShortcut("' + lnkPath.replaceAll('\\', '\\\\') + r'")');
    script.writeln(r'$Shortcut.TargetPath = "' + target.replaceAll('\\', '\\\\') + r'"');
    script.writeln(r'$Shortcut.WorkingDirectory = "' +
        (workingDir ?? File(target).parent.path).replaceAll('\\', '\\\\') + r'"');
    if (iconPath != null && File(iconPath).existsSync()) {
      script.writeln(r'$Shortcut.IconLocation = "' +
          iconPath.replaceAll('\\', '\\\\') + r'"');
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
