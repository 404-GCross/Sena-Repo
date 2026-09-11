// Bundled brand icons for metadata sources.
//
// VNDB has no site icon of its own, so this uses the square avatar the
// project uses on Patreon / SubscribeStar.

const String vndbSourceIcon = "assets/source_icons/vndb.png";
const String bangumiSourceIcon = "assets/source_icons/bangumi.png";
const String steamSourceIcon = "assets/source_icons/steam.png";
const String hikarinagiSourceIcon = "assets/source_icons/hikarinagi.png";
const String nextmoeSourceIcon = "assets/source_icons/nextmoe.png";

const Map<String, String> sourceIconAssets = {
  "vndb_kana": vndbSourceIcon,
  "bangumi": bangumiSourceIcon,
  "steam": steamSourceIcon,
  "hikarinagi": hikarinagiSourceIcon,
  "nextmoe": nextmoeSourceIcon,
};

String? sourceIconAsset(String source) => sourceIconAssets[source];
