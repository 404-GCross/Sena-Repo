/// App version — update this to match pubspec.yaml.
const appVersion = "0.1.4";

String versionLabel(String version) {
  final v = version.trim();
  if (v.toLowerCase() == "test") return "test";
  return "v$v";
}

String get appVersionLabel => versionLabel(appVersion);
