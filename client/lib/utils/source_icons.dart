/// Bundled brand icons for metadata sources.

/// VNDB has no square brand mark of its own — its identity is the
/// "the visual novel database" wordmark — so it keeps a drawn icon.
const Map<String, String> sourceIconAssets = {
  "bangumi": "assets/source_icons/bangumi.png",
  "steam": "assets/source_icons/steam.png",
  "hikarinagi": "assets/source_icons/hikarinagi.png",
  "nextmoe": "assets/source_icons/nextmoe.png",
};

String? sourceIconAsset(String source) => sourceIconAssets[source];
