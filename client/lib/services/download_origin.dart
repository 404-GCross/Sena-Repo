import "server_origin.dart";

Uri? _legacySignedGame(Map<String, dynamic> saved) {
  final uri = Uri.tryParse(saved["downloadUrl"]?.toString() ?? "");
  if (uri == null ||
      serverOrigin(uri.toString()) == null ||
      uri.path !=
          "/api/download/signed/${saved['gameId']}/${saved['versionId']}" ||
      (uri.queryParameters["signature"] ?? "").isEmpty) return null;
  return uri;
}

String? restoredDownloadOrigin(Map<String, dynamic> saved) {
  if (saved["authScopeVersion"] == 1) {
    return serverOrigin(saved["serverBaseUrl"] as String?);
  }
  // Old tasks mistakenly persisted localhost; only a Sena signed URL identifies its server.
  return serverOrigin(_legacySignedGame(saved)?.toString());
}

int? restoredDownloadUserId(Map<String, dynamic> saved) {
  final value = saved["authScopeVersion"] == 1
      ? saved["authUserId"]
      : _legacySignedGame(saved)?.queryParameters["uid"];
  final id = int.tryParse(value?.toString() ?? "");
  return id != null && id > 0 ? id : null;
}
