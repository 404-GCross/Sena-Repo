import "package:flutter_secure_storage/flutter_secure_storage.dart";
import "package:flutter_test/flutter_test.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:sena_repo/services/api_client.dart";
import "package:sena_repo/services/download_origin.dart";
import "package:sena_repo/services/download_service.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await ApiClient.clearTokens();
  });
  tearDown(ApiClient.clearTokens);

  DownloadTask task(
          {String? origin = "https://a.test",
          String? token = "task-token-a",
          int? userId = 1}) =>
      DownloadTask(
          gameId: 1,
          versionId: 2,
          fileName: "game.zip",
          downloadUrl: "https://cdn.test/game.zip",
          serverBaseUrl: origin,
          authToken: token,
          authUserId: userId,
          gameName: "test game",
          companyName: "test");

  test("download task sends its token only to its owning server", () async {
    await ApiClient.persistSessionInfo(
        accessToken: "active-b", serverBaseUrl: "https://b.test", userId: 2);
    final download = task();
    expect(download.headersForUrl("https://a.test/api/download/1/2/link"),
        {"Authorization": "Bearer task-token-a"});
    for (final url in [
      "https://b.test/game.zip",
      "https://cdn.test/game.zip",
      "http://a.test/file",
      "https://a.test:8443/file"
    ]) {
      expect(download.headersForUrl(url), isEmpty);
    }
  });

  test("reauthorization reuses only the same server and account", () async {
    final download = task();
    await ApiClient.persistSessionInfo(
        accessToken: "other-account-a",
        serverBaseUrl: "https://a.test",
        userId: 2);
    expect(download.headersForUrl("https://a.test/file")["Authorization"],
        "Bearer task-token-a");
    await ApiClient.persistSessionInfo(
        accessToken: "renewed-a", serverBaseUrl: "https://a.test", userId: 1);
    expect(download.headersForUrl("https://a.test/file")["Authorization"],
        "Bearer renewed-a");
  });

  test("unknown origin and unknown restored account fail closed", () async {
    await ApiClient.persistSessionInfo(
        accessToken: "active-a", serverBaseUrl: "https://a.test", userId: 1);
    expect(task(origin: null).headersForUrl("https://a.test/file"), isEmpty);
    expect(task(token: null, userId: null).headersForUrl("https://a.test/file"),
        isEmpty);
  });

  test("legacy localhost bug is repaired only from a matching signed Sena URL",
      () {
    final old = <String, dynamic>{
      "gameId": 1,
      "versionId": 2,
      "serverBaseUrl": "http://localhost:11451",
      "downloadUrl":
          "https://a.test/api/download/signed/1/2?uid=7&signature=test-signature",
    };
    expect(restoredDownloadOrigin(old), "https://a.test");
    expect(restoredDownloadUserId(old), 7);
    old["downloadUrl"] = "https://cdn.test/game.zip";
    expect(restoredDownloadOrigin(old), isNull);
    expect(restoredDownloadUserId(old), isNull);
    old["downloadUrl"] =
        "https://a.test/api/download/signed/3/4?uid=7&signature=test";
    expect(restoredDownloadOrigin(old), isNull);
  });

  test("new task persistence retains origin and user but not bearer token", () {
    final data = task().toJson();
    expect(data["authScopeVersion"], 1);
    expect(restoredDownloadOrigin(data), "https://a.test");
    expect(restoredDownloadUserId(data), 1);
    expect(data.containsKey("authToken"), isFalse);
    expect(data.values, isNot(contains("task-token-a")));
  });
}
