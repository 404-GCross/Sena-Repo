/// App version — update this to match pubspec.yaml.
const appVersion = "0.1.4";

String versionLabel(String version) {
  final v = version.trim();
  if (v.isEmpty) return v;

  final lower = v.toLowerCase();
  if (lower == "test" || lower == "dev" || lower.startsWith("dev-")) {
    return v;
  }
  if (lower.startsWith("v")) return v;

  final numericVersion = RegExp(r"^\d+(?:\.\d+){0,2}(?:[-+].*)?$");
  if (numericVersion.hasMatch(v)) return "v$v";

  return v;
}

String get appVersionLabel => versionLabel(appVersion);

/// Build channel of a version string: nightly `dev-xxxx` builds and semver
/// pre-releases (`-beta`, `-rc`, `-alpha`, ...) count as pre-releases,
/// everything else counts as a release.
String versionChannel(String version) {
  final v = version.trim().toLowerCase();
  if (v.isEmpty) return "unknown";
  if (v == "dev" || v == "test" || v.startsWith("dev-")) return "dev";
  if (v.split("+").first.contains("-")) return "dev";
  return "release";
}
