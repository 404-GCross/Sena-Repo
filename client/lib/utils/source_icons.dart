// Bundled brand icons for metadata sources.
//
// VNDB has no square brand mark of its own — its identity is the
// "the visual novel database" wordmark — so it keeps a drawn icon.

const String bangumiSourceIcon = "assets/source_icons/bangumi.png";
const String steamSourceIcon = "assets/source_icons/steam.png";
const String hikarinagiSourceIcon = "assets/source_icons/hikarinagi.png";
const String nextmoeSourceIcon = "assets/source_icons/nextmoe.png";

const Map<String, String> sourceIconAssets = {
  "bangumi": bangumiSourceIcon,
  "steam": steamSourceIcon,
  "hikarinagi": hikarinagiSourceIcon,
  "nextmoe": nextmoeSourceIcon,
};

String? sourceIconAsset(String source) => sourceIconAssets[source];
