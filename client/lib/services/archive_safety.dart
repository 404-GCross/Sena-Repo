import "dart:io";

const maxArchiveListingBytes = 64 * 1024 * 1024;
const maxArchiveEntries = 200000;

class ArchiveSafetyException implements Exception {
  final String message;
  const ArchiveSafetyException(this.message);
  @override
  String toString() => message;
}

class ArchiveRollbackException extends ArchiveSafetyException {
  final String backupDirectory;
  ArchiveRollbackException(this.backupDirectory)
      : super("补丁恢复未完成，原文件备份已保留在 $backupDirectory");
}

String safeArchiveRelativePath(String value) {
  final path = value.replaceAll("\\", "/");
  if (path.isEmpty ||
      path.startsWith("/") ||
      RegExp(r"[\x00-\x1f\x7f:]").hasMatch(path)) {
    throw const ArchiveSafetyException("拒绝不安全的压缩包路径");
  }
  final parts = path.split("/");
  if (parts.last.isEmpty) parts.removeLast();
  if (parts.isEmpty ||
      parts.any((part) =>
          part.isEmpty ||
          part == "." ||
          part == ".." ||
          part.endsWith(".") ||
          part.endsWith(" ") ||
          RegExp(r"^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)",
                  caseSensitive: false)
              .hasMatch(part))) {
    throw const ArchiveSafetyException("拒绝不安全的压缩包路径");
  }
  return parts.join("/");
}

void validateArchiveListing(String listing, {bool? caseInsensitive}) {
  final insensitive = caseInsensitive ?? Platform.isWindows;
  final entries = <String, bool>{};
  var fields = <String, String>{};
  void finish() {
    if (fields.isEmpty) return;
    final rawPath = fields["Path"];
    final size = int.tryParse(fields["Size"] ?? "");
    final folder = fields["Folder"];
    final attributes = fields["Attributes"] ?? "";
    final mode = fields["Mode"] ?? "";
    final hasType = const ["+", "-"].contains(folder) ||
        (folder == null && (attributes.isNotEmpty || mode.isNotEmpty));
    if (rawPath == null || size == null || size < 0 || !hasType) {
      throw const ArchiveSafetyException("无法完整验证压缩包目录，拒绝解压");
    }
    final path = safeArchiveRelativePath(rawPath);
    final key = insensitive ? path.toLowerCase() : path;
    if (entries.containsKey(key) || entries.length >= maxArchiveEntries) {
      throw const ArchiveSafetyException("压缩包包含重复路径或过多条目");
    }
    for (final field in [
      "Symbolic Link",
      "Hard Link",
      "Link",
      "Copy Link",
      "Reparse",
      "Reparse Point",
      "Alternate Stream"
    ]) {
      final value = fields[field];
      if (value != null && value.isNotEmpty && value != "-") {
        throw const ArchiveSafetyException("拒绝包含链接或特殊文件的压缩包");
      }
    }
    for (final value in [mode, attributes]) {
      for (final match
          in RegExp(r"(?:^|\s)(\S)[rwxstST-]{9}(?:\s|$)").allMatches(value)) {
        if (!const ["-", "d", "0"].contains(match.group(1))) {
          throw const ArchiveSafetyException("拒绝包含链接或特殊文件的压缩包");
        }
      }
    }
    if (attributes.contains("L") || attributes.contains("Reparse")) {
      throw const ArchiveSafetyException("拒绝包含重解析点的压缩包");
    }
    entries[key] = folder == "+" ||
        (folder == null &&
            (attributes.split(" ").first.contains("D") ||
                mode.startsWith("d") ||
                RegExp(r"(?:^|\s)d[rwxstST-]{9}(?:\s|$)")
                    .hasMatch(attributes)));
    fields = {};
  }

  for (final line in listing.split(RegExp(r"\r?\n"))) {
    if (line.isEmpty) {
      finish();
      continue;
    }
    final separator = line.indexOf(" = ");
    if (separator < 1) {
      throw const ArchiveSafetyException("压缩包目录格式异常，拒绝解压");
    }
    final key = line.substring(0, separator);
    if (fields.containsKey(key)) {
      throw const ArchiveSafetyException("压缩包目录字段重复，拒绝解压");
    }
    fields[key] = line.substring(separator + 3);
  }
  finish();
  if (entries.isEmpty) {
    throw const ArchiveSafetyException("压缩包为空或目录信息缺失");
  }
  for (final path in entries.keys) {
    final parts = path.split("/");
    for (var i = 1; i < parts.length; i++) {
      if (entries[parts.take(i).join("/")] == false) {
        throw const ArchiveSafetyException("压缩包文件与目录路径冲突");
      }
    }
  }
}

class SafeTreeEntry {
  final String relative;
  final bool directory;
  const SafeTreeEntry(this.relative, this.directory);
}

class SafeFileTree {
  final String root;
  final String original;
  SafeFileTree._(this.root, this.original);

  static Future<SafeFileTree> open(String path) async {
    final original = Directory(path).absolute.path;
    if (await FileSystemEntity.type(original, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const ArchiveSafetyException("目录不存在或目录本身是链接");
    }
    return SafeFileTree._(
        await Directory(original).resolveSymbolicLinks(), original);
  }

  Future<void> checkRoot() async {
    if (await FileSystemEntity.type(original, followLinks: false) !=
            FileSystemEntityType.directory ||
        await Directory(original).resolveSymbolicLinks() != root) {
      throw const ArchiveSafetyException("操作过程中目录发生变化");
    }
  }

  Future<String> checkedPath(String relative) async {
    await checkRoot();
    final parts = safeArchiveRelativePath(relative).split("/");
    var current = root;
    for (var index = 0; index < parts.length; index++) {
      current = "$current${Platform.pathSeparator}${parts[index]}";
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      if (type != FileSystemEntityType.file &&
          type != FileSystemEntityType.directory) {
        throw const ArchiveSafetyException("拒绝跟随目录中的链接或特殊文件");
      }
      if (index < parts.length - 1 && type != FileSystemEntityType.directory) {
        throw const ArchiveSafetyException("文件与目录路径冲突");
      }
      final resolved = await File(current).resolveSymbolicLinks();
      if (resolved != root &&
          !resolved.startsWith("$root${Platform.pathSeparator}")) {
        throw const ArchiveSafetyException("路径超出目标目录");
      }
    }
    return current;
  }

  Future<void> ensureDirectory(String relative) async {
    final parts = safeArchiveRelativePath(relative).split("/");
    for (var i = 1; i <= parts.length; i++) {
      final path = await checkedPath(parts.take(i).join("/"));
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        await Directory(path).create();
      } else if (type != FileSystemEntityType.directory) {
        throw const ArchiveSafetyException("目标目录已被文件占用");
      }
    }
  }

  Future<List<SafeTreeEntry>> entries() async {
    await checkRoot();
    final result = <SafeTreeEntry>[];
    final pending = <String>[root];
    while (pending.isNotEmpty) {
      final directory = pending.removeLast();
      await for (final child in Directory(directory).list(followLinks: false)) {
        final relative = child.path
            .substring(root.length + 1)
            .replaceAll(Platform.pathSeparator, "/");
        final path = await checkedPath(relative);
        final type = await FileSystemEntity.type(path, followLinks: false);
        if (type != FileSystemEntityType.file &&
            type != FileSystemEntityType.directory) {
          throw const ArchiveSafetyException("拒绝包含链接或特殊文件的目录");
        }
        if (result.length >= maxArchiveEntries) {
          throw const ArchiveSafetyException("解压文件数量超过限制");
        }
        result.add(
            SafeTreeEntry(relative, type == FileSystemEntityType.directory));
        if (type == FileSystemEntityType.directory) pending.add(path);
      }
    }
    return result;
  }

  Future<void> writeCopy(String relative, File source) async {
    final parts = safeArchiveRelativePath(relative).split("/");
    if (parts.length > 1)
      await ensureDirectory(parts.take(parts.length - 1).join("/"));
    final target = await checkedPath(relative);
    if (await FileSystemEntity.type(target, followLinks: false) ==
        FileSystemEntityType.directory) {
      throw const ArchiveSafetyException("目标文件已被目录占用");
    }
    // Replace the directory entry, not an existing inode that might be hard-linked.
    final temporary =
        await Directory(File(target).parent.path).createTemp(".sena_write_");
    final tempRoot = await SafeFileTree.open(temporary.path);
    try {
      final staged =
          await source.copy("${tempRoot.root}${Platform.pathSeparator}file");
      await checkedPath(relative);
      if (Platform.isWindows && await File(target).exists())
        await File(target).delete();
      await staged.rename(target);
    } finally {
      await tempRoot.checkRoot();
      await Directory(tempRoot.root).delete(recursive: true);
    }
  }
}

Future<String> archiveInstallSource(String staging) async {
  final tree = await SafeFileTree.open(staging);
  await tree.entries();
  final children = await Directory(tree.root).list(followLinks: false).toList();
  if (children.isEmpty) throw const ArchiveSafetyException("解压没有产生任何文件");
  if (children.length == 1 && children.single is Directory) {
    final name =
        children.single.uri.pathSegments.where((s) => s.isNotEmpty).last;
    return tree.checkedPath(name);
  }
  return tree.root;
}

Future<void> replaceDirectorySafely(
  String staging,
  String finalDirectory, {
  bool Function()? isCancelled,
  void Function()? onCommitted,
}) async {
  void checkCancellation() {
    if (isCancelled?.call() ?? false)
      throw const ArchiveSafetyException("文件写入已取消");
  }

  final source = await SafeFileTree.open(staging);
  await source.entries();
  final parent = await SafeFileTree.open(Directory(finalDirectory).parent.path);
  final name = Directory(finalDirectory)
      .absolute
      .uri
      .pathSegments
      .where((s) => s.isNotEmpty)
      .last;
  final destination = await parent.checkedPath(name);
  final type = await FileSystemEntity.type(destination, followLinks: false);
  if (type != FileSystemEntityType.notFound &&
      type != FileSystemEntityType.directory)
    throw const ArchiveSafetyException("安装目录已被文件占用");
  checkCancellation();
  final backup = await Directory(parent.root).createTemp(".sena_old_");
  final backupTree = await SafeFileTree.open(backup.path);
  final previous = await backupTree.checkedPath("previous");
  var movedOld = false;
  var installed = false;
  var retainBackup = false;
  try {
    await source.checkRoot();
    await parent.checkedPath(name);
    checkCancellation();
    if (type == FileSystemEntityType.directory) {
      await Directory(destination).rename(previous);
      movedOld = true;
    }
    checkCancellation();
    // Staging is created inside this install parent, so a cross-volume fallback is unsafe and unnecessary.
    await Directory(source.root).rename(destination);
    installed = true;
    checkCancellation();
    onCommitted?.call();
  } catch (_) {
    try {
      await parent.checkedPath(name);
      if (installed) await Directory(destination).delete(recursive: true);
      if (movedOld) {
        await backupTree.checkedPath("previous");
        await Directory(previous).rename(destination);
      }
    } catch (_) {
      retainBackup = true;
      throw ArchiveRollbackException(backupTree.root);
    }
    rethrow;
  } finally {
    if (!retainBackup) {
      try {
        await backupTree.checkRoot();
        await backup.delete(recursive: true);
      } catch (_) {
        // A completed replacement must not be reported as cancelled or failed by cleanup.
      }
    }
  }
}

Future<void> copyTreeSafely(
  String from,
  String to, {
  String? backupDirectory,
  bool Function()? isCancelled,
  void Function()? onCommitted,
}) async {
  final source = await SafeFileTree.open(from);
  final entries = await source.entries();
  final target = await SafeFileTree.open(to);
  final backup =
      backupDirectory == null ? null : await SafeFileTree.open(backupDirectory);
  for (final entry in entries) {
    final path = await target.checkedPath(entry.relative);
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type !=
            (entry.directory
                ? FileSystemEntityType.directory
                : FileSystemEntityType.file)) {
      throw const ArchiveSafetyException("补丁路径与现有文件类型冲突");
    }
    if (!entry.directory &&
        type == FileSystemEntityType.file &&
        backup == null) {
      throw const ArchiveSafetyException("拒绝覆盖未备份的文件");
    }
  }
  final added = <String>[];
  final saved = <String>[];
  final addedDirectories = <String>[];
  try {
    for (final entry in entries) {
      if (isCancelled?.call() ?? false)
        throw const ArchiveSafetyException("文件写入已取消");
      if (entry.directory) {
        if (await FileSystemEntity.type(
                await target.checkedPath(entry.relative),
                followLinks: false) ==
            FileSystemEntityType.notFound) {
          addedDirectories.add(entry.relative);
        }
        await target.ensureDirectory(entry.relative);
        continue;
      }
      final sourcePath = await source.checkedPath(entry.relative);
      final targetPath = await target.checkedPath(entry.relative);
      if (await File(targetPath).exists()) {
        await backup!.writeCopy(entry.relative, File(targetPath));
        saved.add(entry.relative);
      } else {
        added.add(entry.relative);
      }
      await target.writeCopy(entry.relative, File(sourcePath));
      if (isCancelled?.call() ?? false)
        throw const ArchiveSafetyException("文件写入已取消");
    }
    if (isCancelled?.call() ?? false)
      throw const ArchiveSafetyException("文件写入已取消");
    onCommitted?.call();
  } catch (error) {
    var restored = true;
    for (final relative in added.reversed) {
      try {
        final path = await target.checkedPath(relative);
        if (await File(path).exists()) await File(path).delete();
      } catch (_) {
        restored = false;
      }
    }
    for (final relative in saved.reversed) {
      try {
        await target.writeCopy(
            relative, File(await backup!.checkedPath(relative)));
      } catch (_) {
        restored = false;
      }
    }
    for (final relative in addedDirectories.reversed) {
      try {
        final path = await target.checkedPath(relative);
        if (await Directory(path).exists() &&
            await Directory(path).list(followLinks: false).isEmpty) {
          await Directory(path).delete();
        }
      } catch (_) {
        restored = false;
      }
    }
    if (!restored && backup != null)
      throw ArchiveRollbackException(backup.root);
    rethrow;
  }
}
