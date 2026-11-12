const minimumSevenZipVersion = 2602;

int? sevenZipVersion(String banner) {
  final match = RegExp(
    r"^7-Zip(?:\s+\([^\r\n)]*\))?\s+(\d{2})\.(\d{2})(?:\s|$)",
    multiLine: true,
  ).firstMatch(banner);
  if (match == null) return null;
  return int.parse(match.group(1)!) * 100 + int.parse(match.group(2)!);
}

bool isSupportedSevenZip(String banner) =>
    (sevenZipVersion(banner) ?? 0) >= minimumSevenZipVersion;

String sevenZipDownloadUrl({required bool windows, bool arm64 = false}) {
  final platform =
      windows ? "x64.exe" : "linux-${arm64 ? 'arm64' : 'x64'}.tar.xz";
  return "https://github.com/ip7z/7zip/releases/download/26.06/7z2606-$platform";
}

const aria2HttpOnlyArguments = <String>[
  "--no-conf=true",
  "--no-netrc=true",
  "--follow-torrent=false",
  "--follow-metalink=false",
  "--enable-rpc=false",
  "--enable-dht=false",
  "--enable-dht6=false",
  "--bt-enable-lpd=false",
];
