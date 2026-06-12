/// Create desktop shortcuts for games with their cover as icon.
/// Windows: .lnk via PowerShell COM; Linux: .desktop file.

import "dart:io";

import "package:http/http.dart" as http;
import "package:path_provider/path_provider.dart";

class ShortcutService {
  /// Find a likely game executable in [dir]. Returns the best match.
  static String? findExecutable(String dir) {
    if (!Directory(dir).existsSync()) return null;
    try {
      final files = Directory(dir)
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((f) {
        final name = f.uri.pathSegments.last.toLowerCase();
        if (Platform.isWindows) return name.endsWith(".exe");
        // Linux: executable files (no extension, or .sh)
        if (name.endsWith(".exe")) return true;
        if (name.endsWith(".sh")) return true;
        // Check if executable by extension convention
        return !name.contains(".") || name.endsWith(".x86_64") || name.endsWith(".bin");
      }).toList();

      if (files.isEmpty) return null;
      // Prefer files not in subdirectories
      final rootFiles = files.where((f) =>
          File(f.path).parent.path == dir).toList();
      final candidates = rootFiles.isNotEmpty ? rootFiles : files;
      // Sort by size descending — main exe is usually largest
      candidates.sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
      return candidates.first.path;
    } catch (_) {
      return null;
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
  }) async {
    try {
      if (Platform.isWindows) {
        return await _createWindowsShortcut(gameName, exePath, coverPath);
      } else if (Platform.isLinux) {
        return await _createLinuxDesktop(gameName, exePath, coverPath);
      }
    } catch (_) {}
    return false;
  }

  static Future<bool> _createWindowsShortcut(
      String name, String target, String? iconPath) async {
    final desktopDir = _desktopDir();
    if (desktopDir == null) return false;
    final lnkPath = "$desktopDir\\${_safeName(name)}.lnk";

    // Build PowerShell script to create shortcut
    final script = StringBuffer();
    script.writeln(r'$WshShell = New-Object -ComObject WScript.Shell');
    script.writeln(r'$Shortcut = $WshShell.CreateShortcut("' + lnkPath.replaceAll('\\', '\\\\') + r'")');
    script.writeln(r'$Shortcut.TargetPath = "' + target.replaceAll('\\', '\\\\') + r'"');
    script.writeln(r'$Shortcut.WorkingDirectory = "' +
        File(target).parent.path.replaceAll('\\', '\\\\') + r'"');
    if (iconPath != null && File(iconPath).existsSync()) {
      script.writeln(r'$Shortcut.IconLocation = "' +
          iconPath.replaceAll('\\', '\\\\') + r'"');
    }
    script.writeln(r'$Shortcut.Save()');

    final result = await Process.run(
      "powershell", ["-Command", script.toString()],
      runInShell: true,
    );
    return result.exitCode == 0 && File(lnkPath).existsSync();
  }

  static Future<bool> _createLinuxDesktop(
      String name, String exec, String? iconPath) async {
    final desktopDir = _desktopDir();
    if (desktopDir == null) return false;

    final file = File("$desktopDir/${_safeName(name)}.desktop");
    final content = StringBuffer();
    content.writeln("[Desktop Entry]");
    content.writeln("Type=Application");
    content.writeln("Name=$name");
    content.writeln("Exec=$exec");
    content.writeln("Path=${File(exec).parent.path}");
    if (iconPath != null) content.writeln("Icon=$iconPath");
    content.writeln("Terminal=false");
    content.writeln("Categories=Game;");

    await file.writeAsString(content.toString());
    await Process.run("chmod", ["+x", file.path]);
    return true;
  }

  static String? _desktopDir() {
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
