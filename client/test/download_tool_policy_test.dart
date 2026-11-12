import "package:flutter_test/flutter_test.dart";
import "package:sena_repo/services/download_tool_policy.dart";

void main() {
  test("only patched extractors with authentic version banners are accepted",
      () {
    for (final version in ["16.04", "24.09", "25.01", "26.01"]) {
      expect(isSupportedSevenZip("7-Zip $version (x64) : Copyright"), isFalse);
    }
    for (final banner in [
      "\n7-Zip 26.02 ZS v1.5.7 R1 (x64) : Copyright",
      "7-Zip (z) 26.06 (x64) : Copyright",
      "7-Zip 27.00 : Copyright",
    ]) {
      expect(isSupportedSevenZip(banner), isTrue, reason: banner);
    }
    expect(isSupportedSevenZip("runtime 99.99\n7-Zip broken"), isFalse);
    expect(isSupportedSevenZip("7-Zip 9.20"), isFalse);
    expect(isSupportedSevenZip(""), isFalse);
  });

  test("official fallback URLs use the patched release and correct platform",
      () {
    expect(
        sevenZipDownloadUrl(windows: true), endsWith("/26.06/7z2606-x64.exe"));
    expect(sevenZipDownloadUrl(windows: false),
        endsWith("/26.06/7z2606-linux-x64.tar.xz"));
    expect(sevenZipDownloadUrl(windows: false, arm64: true),
        endsWith("/26.06/7z2606-linux-arm64.tar.xz"));
  });

  test(
      "aria2 cannot load local credentials or follow torrent and metalink content",
      () {
    for (final flag in [
      "--no-conf=true",
      "--no-netrc=true",
      "--follow-torrent=false",
      "--follow-metalink=false",
      "--enable-rpc=false",
      "--enable-dht=false",
      "--enable-dht6=false",
      "--bt-enable-lpd=false",
    ]) {
      expect(aria2HttpOnlyArguments, contains(flag));
    }
  });
}
