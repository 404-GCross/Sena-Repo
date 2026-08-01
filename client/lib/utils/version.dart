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
