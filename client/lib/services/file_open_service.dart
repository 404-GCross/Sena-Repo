import "dart:io";

class FileOpenService {
  static Future<bool> openTargetFolder(String path) async {
    final target = await _folderFor(path);
    if (target == null) return false;

    final result = await _openPath(target);
    return result.exitCode == 0;
  }

  static Future<String?> _folderFor(String path) async {
    final type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.directory) return path;
    if (type == FileSystemEntityType.file) return File(path).parent.path;
    return null;
  }

  static Future<ProcessResult> _openPath(String path) {
    if (Platform.isWindows) {
      return Process.run("explorer.exe", [path]);
    }
    if (Platform.isMacOS) {
      return Process.run("open", [path]);
    }
    return Process.run("xdg-open", [path]);
  }
}
