import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:sena_repo/services/archive_safety.dart";

String record(String path,
        {String folder = "-", String attributes = "A", String extra = ""}) =>
    "Path = $path\nFolder = $folder\nSize = 2\nAttributes = $attributes\n$extra\n";

void main() {
  late Directory root;
  late String canonical;
  setUp(() async {
    root = await Directory.systemTemp.createTemp("sena-archive-test-");
    canonical = await root.resolveSymbolicLinks();
  });
  tearDown(() async {
    expect(await root.resolveSymbolicLinks(), canonical);
    expect(root.path.contains("sena-archive-test-"), isTrue);
    await root.delete(recursive: true);
  });

  Future<Directory> directory(String name) =>
      Directory("${root.path}/$name").create(recursive: true);
  Future<File> file(String name, String value) async {
    final result = File("${root.path}/$name");
    await result.parent.create(recursive: true);
    return result.writeAsString(value);
  }

  test("portable archive paths reject traversal, devices and alternate streams",
      () {
    for (final path in [
      "../escape",
      "/absolute",
      r"C:\evil",
      r"\\host\share",
      "a/../b",
      "a//b",
      "./a",
      "a/./b",
      "a:stream",
      "a\u0000b",
      "a\nb",
      "CON.txt",
      "nul",
      "a. ",
      "a."
    ]) {
      expect(() => safeArchiveRelativePath(path),
          throwsA(isA<ArchiveSafetyException>()),
          reason: path);
    }
    expect(safeArchiveRelativePath(r"游戏\data.bin"), "游戏/data.bin");
    expect(safeArchiveRelativePath("folder/"), "folder");
  });

  test("listing rejects links, special entries and ambiguous paths", () {
    validateArchiveListing(record("游戏/data.bin"));
    for (final listing in [
      record("../outside"),
      record("link", attributes: " lrwxrwxrwx"),
      record("fifo", extra: "Mode = prw-------\n"),
      record("link", extra: "Hard Link = ../outside\n"),
      record("link", extra: "Symbolic Link = ../outside\n"),
      record("link", extra: "Link = ../outside\n"),
      record("link", extra: "Copy Link = other\n"),
      record("junction", attributes: "DL"),
      record("a") + record("a"),
      record("a") + record("a/b"),
      "Path = a\nFolder = -\nSize = 1\nPath = b\n",
      "Path = incomplete\n",
      "",
    ]) {
      expect(() => validateArchiveListing(listing),
          throwsA(isA<ArchiveSafetyException>()));
    }
    expect(
        () => validateArchiveListing(record("A") + record("a"),
            caseInsensitive: true),
        throwsA(isA<ArchiveSafetyException>()));
    validateArchiveListing(record("A") + record("a"), caseInsensitive: false);
  });

  test("source links are rejected before any target copy", () async {
    final source = await directory("source");
    final target = await directory("target");
    final outside = await file("outside/secret", "secret");
    await file("source/valid", "valid");
    await Link("${source.path}/link").create(outside.path);
    await expectLater(copyTreeSafely(source.path, target.path),
        throwsA(isA<ArchiveSafetyException>()));
    expect(await target.list().isEmpty, isTrue);
    expect(await outside.readAsString(), "secret");
  },
      skip: Platform.isWindows
          ? "file symlink creation requires Windows developer privileges"
          : false);

  test("existing target directory links cannot redirect patch writes",
      () async {
    final source = await directory("source");
    final target = await directory("target");
    final outside = await directory("outside");
    final backup = await directory("backup");
    await file("outside/file", "original");
    await file("source/sub/file", "replacement");
    if (Platform.isWindows) {
      final result = await Process.run(
          "cmd", ["/c", "mklink", "/J", "${target.path}\\sub", outside.path]);
      expect(result.exitCode, 0, reason: "${result.stdout} ${result.stderr}");
    } else {
      await Link("${target.path}/sub").create(outside.path);
    }
    await expectLater(
        copyTreeSafely(source.path, target.path, backupDirectory: backup.path),
        throwsA(isA<ArchiveSafetyException>()));
    expect(await File("${outside.path}/file").readAsString(), "original");
    expect(await backup.list().isEmpty, isTrue);
  });

  test("existing and dangling target file links are rejected", () async {
    final source = await directory("source");
    final target = await directory("target");
    final backup = await directory("backup");
    await file("source/item", "replacement");
    final outside = await file("outside/item", "original");
    final link = Link("${target.path}/item");
    await link.create(outside.path);
    await expectLater(
        copyTreeSafely(source.path, target.path, backupDirectory: backup.path),
        throwsA(isA<ArchiveSafetyException>()));
    expect(await outside.readAsString(), "original");
    expect(await link.target(), outside.path);
    await outside.delete();
    await expectLater(
        copyTreeSafely(source.path, target.path, backupDirectory: backup.path),
        throwsA(isA<ArchiveSafetyException>()));
    expect(await outside.exists(), isFalse);
  },
      skip: Platform.isWindows
          ? "file symlink creation requires Windows developer privileges"
          : false);

  test("atomic replacement does not write through existing hard links",
      () async {
    final source = await directory("source");
    final target = await directory("target");
    final backup = await directory("backup");
    final outside = await file("outside", "original");
    await file("source/item", "replacement");
    final result =
        await Process.run("ln", [outside.path, "${target.path}/item"]);
    expect(result.exitCode, 0);
    await copyTreeSafely(source.path, target.path,
        backupDirectory: backup.path);
    expect(await outside.readAsString(), "original");
    expect(await File("${target.path}/item").readAsString(), "replacement");
    expect(await File("${backup.path}/item").readAsString(), "original");
  }, skip: Platform.isWindows ? "POSIX hardlink fixture" : false);

  test("cancellation restores overwritten files and removes new files",
      () async {
    final source = await directory("source");
    final target = await directory("target");
    final backup = await directory("backup");
    await file("source/one", "new one");
    await file("source/two", "new two");
    await file("source/three", "new three");
    await file("target/one", "old one");
    await file("target/two", "old two");
    await file("target/three", "old three");
    var steps = 0;
    await expectLater(
        copyTreeSafely(source.path, target.path,
            backupDirectory: backup.path, isCancelled: () => ++steps > 1),
        throwsA(isA<ArchiveSafetyException>()));
    for (final name in ["one", "two", "three"]) {
      expect(await File("${target.path}/$name").readAsString(), "old $name");
    }
    expect(await target.list().length, 3);
  });

  test("cancellation during the final copy still restores the original",
      () async {
    final source = await directory("source");
    final target = await directory("target");
    final backup = await directory("backup");
    await file("source/one", "new");
    final original = await file("target/one", "old");
    await expectLater(
        copyTreeSafely(source.path, target.path,
            backupDirectory: backup.path,
            isCancelled: () => original.readAsStringSync() == "new"),
        throwsA(isA<ArchiveSafetyException>()));
    expect(await original.readAsString(), "old");
  });

  test("failed rollback keeps the original backup accessible", () async {
    final source = await directory("source");
    final target = await directory("target");
    final backup = await directory("backup");
    await file("source/one", "new");
    final original = await file("target/one", "old");
    var cancelled = false;
    await expectLater(
        copyTreeSafely(source.path, target.path, backupDirectory: backup.path,
            isCancelled: () {
          if (!cancelled && original.readAsStringSync() == "new") {
            cancelled = true;
            original.deleteSync();
            Directory(original.path).createSync();
          }
          return cancelled;
        }),
        throwsA(isA<ArchiveRollbackException>()));
    expect(await File("${backup.path}/one").readAsString(), "old");
  });

  test("install source preserves all siblings without partial layout moves",
      () async {
    final staging = await directory("staging");
    await file("staging/Game/a", "game");
    await file("staging/readme", "readme");
    expect(await archiveInstallSource(staging.path),
        await staging.resolveSymbolicLinks());
    expect(await File("${staging.path}/readme").readAsString(), "readme");
    final single = await directory("single");
    await file("single/Wrapper/a", "game");
    expect(await archiveInstallSource(single.path),
        await Directory("${single.path}/Wrapper").resolveSymbolicLinks());
  });

  test("cancelled directory replacement restores previous install", () async {
    final staging = await directory("staging");
    final target = await directory("target");
    await file("staging/item", "new");
    final original = await file("target/item", "old");
    await expectLater(
        replaceDirectorySafely(staging.path, target.path,
            isCancelled: () =>
                original.existsSync() && original.readAsStringSync() == "new"),
        throwsA(isA<ArchiveSafetyException>()));
    expect(await original.readAsString(), "old");
  });

  test("committed replacement does not treat cleanup as cancellation",
      () async {
    final staging = await directory("staging");
    final target = await directory("target");
    await file("staging/item", "new");
    await file("target/item", "old");
    var committed = false;
    await replaceDirectorySafely(staging.path, target.path,
        isCancelled: () => committed, onCommitted: () => committed = true);
    expect(committed, isTrue);
    expect(await File("${target.path}/item").readAsString(), "new");
  });

  test("normal directory copies retain nested files", () async {
    final source = await directory("source");
    final target = await directory("target");
    await file("source/游戏/a.txt", "hello");
    await directory("source/empty");
    await copyTreeSafely(source.path, target.path);
    expect(await File("${target.path}/游戏/a.txt").readAsString(), "hello");
    expect(await Directory("${target.path}/empty").exists(), isTrue);
  });

  test(
      "real bundled extractor listings block malicious ZIP and TAR before extraction",
      () async {
    final platform = Platform.isWindows
        ? "Windows-x64/7zz.exe"
        : Platform.isLinux
            ? "Linux-x64/7zz"
            : null;
    if (platform == null) return;
    final exe = File("assets/binaries/7zip-zstd/$platform").absolute.path;
    final fixture =
        await Process.run(Platform.isWindows ? "python" : "python3", [
      "-c",
      r'''
import io, pathlib, stat, sys, tarfile, zipfile
root=pathlib.Path(sys.argv[1])
for name,path in [('good','game/readme.txt'),('traversal','../outside'),('drive','C:/outside'),('ads','game/file:stream')]:
 with zipfile.ZipFile(root/(name+'.zip'),'w') as z: z.writestr(path,'hello')
for name,count in [('symlink',0),('late-symlink',300)]:
 with zipfile.ZipFile(root/(name+'.zip'),'w') as z:
  for n in range(count): z.writestr('game/file'+str(n),'ok')
  i=zipfile.ZipInfo('game/link');i.create_system=3;i.external_attr=(stat.S_IFLNK|0o777)<<16;z.writestr(i,'../../outside')
for name,kind in [('hardlink',tarfile.LNKTYPE),('fifo',tarfile.FIFOTYPE)]:
 with tarfile.open(root/(name+'.tar'),'w') as t:
  i=tarfile.TarInfo('game/readme');i.size=2;t.addfile(i,io.BytesIO(b'ok'))
  i=tarfile.TarInfo('game/link');i.type=kind;i.linkname='game/readme' if name=='hardlink' else '';t.addfile(i)
''',
      root.path
    ]);
    expect(fixture.exitCode, 0, reason: "${fixture.stderr}");
    for (final name in [
      "good.zip",
      "traversal.zip",
      "drive.zip",
      "ads.zip",
      "symlink.zip",
      "late-symlink.zip",
      "hardlink.tar",
      "fifo.tar"
    ]) {
      final listing = await Process.run(
          exe, ["l", "-slt", "-ba", "-sccUTF-8", "--", "${root.path}/$name"]);
      expect(listing.exitCode, 0, reason: "$name ${listing.stderr}");
      if (name == "good.zip") {
        validateArchiveListing(listing.stdout as String);
        final extracted = await Process.run(exe, [
          "x",
          "-y",
          "-o${root.path}/extracted",
          "--",
          "${root.path}/$name"
        ]);
        expect(extracted.exitCode, 0);
        expect(
            (await (await SafeFileTree.open("${root.path}/extracted"))
                    .entries())
                .length,
            2);
      } else {
        expect(() => validateArchiveListing(listing.stdout as String),
            throwsA(isA<ArchiveSafetyException>()),
            reason: name);
      }
    }
    for (final encrypted in [false, true]) {
      final archive = "${root.path}/${encrypted ? 'encrypted' : 'normal'}.7z";
      final created = await Process.run(
          exe,
          [
            "a",
            "-t7z",
            "-y",
            if (encrypted) ...["-mhe=on", "-plocal-test-only"],
            archive,
            "game"
          ],
          workingDirectory: "${root.path}/extracted");
      expect(created.exitCode, 0, reason: "${created.stderr}");
      final listing = await Process.run(exe, [
        "l",
        "-slt",
        "-ba",
        "-sccUTF-8",
        if (encrypted) "-plocal-test-only",
        "--",
        archive
      ]);
      expect(listing.exitCode, 0);
      validateArchiveListing(listing.stdout as String);
      if (encrypted) {
        final denied =
            await Process.run(exe, ["l", "-slt", "-ba", "-p-", "--", archive]);
        expect(denied.exitCode, isNot(0));
      }
    }
  }, skip: !(Platform.isLinux || Platform.isWindows));
}
