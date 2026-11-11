import "dart:async";
import "dart:convert";

import "package:flutter_secure_storage/flutter_secure_storage.dart";
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:sena_repo/services/api_client.dart";
import "package:sena_repo/services/profile_service.dart";
import "package:sena_repo/services/secure_store.dart";
import "package:sena_repo/services/server_origin.dart";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await ApiClient.clearTokens();
  });

  tearDown(ApiClient.clearTokens);

  Future<void> installA({String token = "test-token-a", int userId = 1}) =>
      ApiClient.persistSessionInfo(
          accessToken: token,
          serverBaseUrl: "https://a.test",
          userId: userId,
          username: "test-user",
          role: "user",
          isAdmin: false);

  test(
      "origins include scheme and effective port and reject embedded credentials",
      () {
    expect(serverOrigin("https://A.test:443/path"), "https://a.test");
    expect(serverOrigin("https://a.test:8443"), "https://a.test:8443");
    expect(serverOrigin("http://a.test:80"), "http://a.test");
    expect(serverOrigin("https://user:password@a.test"), isNull);
    expect(serverOrigin("file:///tmp/a"), isNull);
    expect(serverOrigin(null), isNull);
  });

  test("each API client authenticates only its explicit matching origin",
      () async {
    await installA();
    final a = ApiClient();
    await a.connect("A.test", port: 443, useHttps: true);
    expect(a.headers, {"Authorization": "Bearer test-token-a"});
    for (final endpoint in [
      ("b.test", 443, true),
      ("a.test", 8443, true),
      ("a.test", 80, false)
    ]) {
      final other = ApiClient();
      await other.connect(endpoint.$1,
          port: endpoint.$2, useHttps: endpoint.$3);
      expect(other.headers, isEmpty);
      expect(other.accessToken, isNull);
      expect(other.cachedUserId, isNull);
    }
    expect(ApiClient().headers, isEmpty);
    expect(a.accessToken, "test-token-a");
  });

  test("public probes on a newly selected server never send the old token",
      () async {
    await installA();
    final requests = <http.Request>[];
    await http.runWithClient(() async {
      final b = ApiClient();
      await b.connect("b.test", port: 443, useHttps: true);
      expect(await b.checkSetupNeeded(), isFalse);
      await b.getAuthProviders();
      await b.oauthStart(
          provider: "hikarinagi", purpose: "bind", withAuth: true);
    },
        () => MockClient((request) async {
              requests.add(request);
              expect(request.headers.containsKey("authorization"), isFalse);
              return http.Response('{"needs_setup":false}', 200);
            }));
    expect(requests.length, 3);
    expect(tokenForServer("https://a.test"), "test-token-a");
  });

  test("media headers use the exact target instead of path substring matching",
      () async {
    await installA();
    expect(mediaHeadersFor("https://a.test/api/files/covers/x.png"), isNotNull);
    expect(mediaHeadersFor("https://cdn.test/api/files/covers/x.png"), isNull);
    expect(mediaHeadersFor("http://a.test/api/files/covers/x.png"), isNull);
    expect(
        mediaHeadersFor("https://a.test:8443/api/files/covers/x.png"), isNull);
  });

  test(
      "legacy migration uses matching saved profiles rather than mutable settings",
      () async {
    await SecureStore.delete("auth_session");
    await SecureStore.setString("auth_token", "legacy-a");
    await ProfileService().saveProfiles([
      UserProfile(
          name: "a",
          host: "a.test",
          port: 443,
          useHttps: true,
          authToken: "legacy-a",
          userId: 1),
    ]);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("server_host", "b.test");
    await ApiClient.restoreToken();
    expect(tokenForServer("https://a.test"), "legacy-a");
    expect(tokenForServer("https://b.test"), isNull);
    final saved =
        jsonDecode((await SecureStore.getString("auth_session"))!) as Map;
    expect(saved["origin"], "https://a.test");
  });

  test("unknown and ambiguous legacy ownership fail closed", () async {
    for (final profiles in <List<UserProfile>>[
      [],
      [
        UserProfile(name: "a", host: "a.test", authToken: "legacy"),
        UserProfile(name: "b", host: "b.test", authToken: "legacy")
      ],
    ]) {
      await ApiClient.clearTokens();
      await SecureStore.delete("auth_session");
      await SecureStore.setString("auth_token", "legacy");
      await ProfileService().saveProfiles(profiles);
      await ApiClient.restoreToken();
      expect(tokenForServer("http://a.test:11451"), isNull);
      expect(tokenForServer("http://b.test:11451"), isNull);
    }
  });

  test("authoritative record restores token and owner as one pair", () async {
    await installA();
    final record = (await SecureStore.getString("auth_session"))!;
    await ApiClient.clearTokens();
    await SecureStore.setString("auth_session", record);
    await SecureStore.setString("auth_token", "unrelated-legacy");
    await ApiClient.restoreToken();
    expect(tokenForServer("https://a.test"), "test-token-a");
    expect(tokenForServer("https://b.test"), isNull);
  });

  test("cleared authoritative record cannot resurrect a legacy token",
      () async {
    await SecureStore.setString("auth_token", "legacy");
    await ProfileService().saveProfiles(
        [UserProfile(name: "a", host: "a.test", authToken: "legacy")]);
    await ApiClient.restoreToken();
    expect(tokenForServer("http://a.test:11451"), isNull);
  });

  test(
      "applying a profile replaces in-memory credentials with the correct owner",
      () async {
    await installA();
    await ProfileService().applyProfile(UserProfile(
        name: "b",
        host: "b.test",
        port: 443,
        useHttps: true,
        authToken: "test-token-b",
        userId: 2));
    expect(tokenForServer("https://a.test"), isNull);
    expect(tokenForServer("https://b.test", userId: 2), "test-token-b");
    expect(tokenForServer("https://b.test", userId: 1), isNull);
  });

  test("saving setup on server B cannot copy the active A credentials",
      () async {
    await installA();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("server_host", "b.test");
    await prefs.setInt("server_port", 443);
    await prefs.setBool("use_https", true);
    await ProfileService().saveCurrentAsProfile("b");
    final profiles = await ProfileService().loadProfiles();
    expect(profiles.single.authToken, isEmpty);
    expect(profiles.single.userId, 0);
    expect(profiles.single.isAdmin, isFalse);
  });

  test(
      "late login enrichment uses its original origin and cannot replace a newer session",
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    await http.runWithClient(() async {
      final a = ApiClient();
      await a.connect("a.test", port: 443, useHttps: true);
      final login = a.login("test-user", "test-password");
      final rejected = expectLater(login, throwsA(isA<AuthException>()));
      await entered.future;
      await ApiClient.persistSessionInfo(
          accessToken: "test-token-b",
          serverBaseUrl: "https://b.test",
          userId: 2);
      await a.connect("b.test", port: 443, useHttps: true);
      release.complete();
      await rejected;
      expect(tokenForServer("https://b.test"), "test-token-b");
      expect(tokenForServer("https://a.test"), isNull);
    },
        () => MockClient((request) async {
              expect(request.url.host, "a.test");
              if (request.url.path.endsWith("/login")) {
                entered.complete();
                await release.future;
                return http.Response('{"token":"test-token-a","id":1}', 200);
              }
              expect(request.headers["authorization"], "Bearer test-token-a");
              return http.Response(
                  '{"id":1,"username":"test-user","role":"user"}', 200);
            }));
  });

  test(
      "OAuth session origin is captured by client and not accepted from response claims",
      () async {
    await http.runWithClient(() async {
      final api = ApiClient();
      await api.connect("a.test", port: 443, useHttps: true);
      await api.oauthStart(provider: "hikarinagi", purpose: "login");
      final data = await api.oauthComplete(
          provider: "hikarinagi",
          requestId: "test",
          code: "test",
          state: "test");
      await api.applyOAuthSession(data);
      expect(tokenForServer("https://a.test"), "oauth-test-token");
      expect(tokenForServer("https://evil.test"), isNull);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith("/complete")) {
                return http.Response(
                    '{"token":"oauth-test-token","id":1,"_session_origin":"https://evil.test"}',
                    200);
              }
              if (request.url.path.endsWith("/start"))
                return http.Response('{"request_id":"test"}', 200);
              return http.Response('{"id":1,"role":"user"}', 200);
            }));
  });

  test("cancelled OAuth and stale profile updates cannot promote a session",
      () async {
    await installA();
    final generation = ApiClient.sessionGeneration;
    ApiClient.invalidatePendingSession();
    await expectLater(
        ApiClient.persistSessionInfo(
            accessToken: "late",
            serverBaseUrl: "https://b.test",
            expectedGeneration: generation),
        throwsA(isA<AuthException>()));
    expect(tokenForServer("https://a.test"), "test-token-a");
    await ApiClient.persistSessionInfo(
        userId: 999, serverBaseUrl: "https://b.test");
    expect(userIdForServer("https://a.test"), 1);
  });

  test(
      "password token rotation preserves verified identity on the same account",
      () async {
    await ApiClient.persistSessionInfo(
        accessToken: "old-admin",
        serverBaseUrl: "https://a.test",
        userId: 1,
        username: "test-admin",
        role: "admin",
        isAdmin: true,
        logScope: "test-scope");
    final generation = ApiClient.sessionGeneration;
    await ApiClient.persistSessionInfo(
        accessToken: "new-admin",
        serverBaseUrl: "https://a.test",
        userId: 1,
        expectedGeneration: generation);
    final api = ApiClient();
    await api.connect("a.test", port: 443, useHttps: true);
    expect(api.accessToken, "new-admin");
    expect(api.cachedRole, "admin");
    expect(api.cachedIsAdmin, isTrue);
  });

  test("startup does not overwrite a rotated token with a stale saved profile",
      () async {
    final profile = UserProfile(
        name: "a",
        host: "a.test",
        port: 443,
        useHttps: true,
        authToken: "stale-a",
        userId: 1);
    await installA(token: "fresh-a");
    final record = (await SecureStore.getString("auth_session"))!;
    await ProfileService().saveProfiles([profile]);
    await ApiClient.clearTokens();
    await SecureStore.setString("auth_session", record);
    await ProfileService().applyProfile(profile);
    expect(tokenForServer("https://a.test"), "fresh-a");
    expect(profile.authToken, "fresh-a");
  });

  test(
      "cancelling during profile storage awaits cannot promote the old selection",
      () async {
    await installA();
    final profile = UserProfile(
        name: "b",
        host: "b.test",
        port: 443,
        useHttps: true,
        authToken: "test-token-b",
        userId: 2);
    final generation = ApiClient.sessionGeneration;
    final applying =
        ProfileService().applyProfile(profile, expectedGeneration: generation);
    final rejected = expectLater(applying, throwsA(isA<AuthException>()));
    ApiClient.invalidatePendingSession();
    await rejected;
    expect(tokenForServer("https://a.test"), "test-token-a");
    expect(tokenForServer("https://b.test"), isNull);
  });

  test("a pending old OAuth completion cannot adopt the next flow generation",
      () async {
    var starts = 0;
    final entered = Completer<void>();
    final release = Completer<void>();
    await http.runWithClient(() async {
      final api = ApiClient();
      await api.connect("a.test", port: 443, useHttps: true);
      await api.oauthStart(provider: "hikarinagi", purpose: "login");
      final old = api.oauthComplete(
          provider: "hikarinagi",
          requestId: "flow-1",
          code: "test",
          state: "test");
      final rejected = expectLater(old, throwsA(isA<AuthException>()));
      await entered.future;
      await api.oauthStart(provider: "hikarinagi", purpose: "login");
      release.complete();
      await rejected;
      expect(tokenForServer("https://a.test"), isNull);
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith("/start")) {
                starts++;
                return http.Response(
                    jsonEncode({"request_id": "flow-$starts"}), 200);
              }
              entered.complete();
              await release.future;
              return http.Response('{"token":"old-flow-token","id":1}', 200);
            }));
  });

  test(
      "logout through a different-origin client leaves the active session intact",
      () async {
    await installA();
    final b = ApiClient();
    await b.connect("b.test", port: 443, useHttps: true);
    expect(await b.logout(), isTrue);
    expect(tokenForServer("https://a.test"), "test-token-a");
  });
}
