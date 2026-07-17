import "dart:io";

class FileOpenService {
  static Future<bool> openTargetFolder(String path) async {
    final target = await _folderFor(path);
    if (target == null) return false;

    await _openPath(target);
    return true;
  }

  static Future<String?> _folderFor(String path) async {
    final type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.directory) return path;
    if (type == FileSystemEntityType.file) return File(path).parent.path;
    return null;
  }

  static Future<void> _openPath(String path) async {
    if (Platform.isWindows) {
      await Process.start(
        "explorer.exe",
        [path],
        mode: ProcessStartMode.detached,
      );
      return;
    }
    if (Platform.isMacOS) {
      await Process.start("open", [path], mode: ProcessStartMode.detached);
      return;
    }
    await Process.start("xdg-open", [path], mode: ProcessStartMode.detached);
  }
}
