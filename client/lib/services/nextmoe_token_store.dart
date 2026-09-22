/// NextMoe OAuth token storage and refresh for user-scoped scraping.
///
/// Tokens are kept per server + account so multiple saved profiles never
/// share credentials, and are refreshed straight against the OP (public
/// client, PKCE, no client_secret).

import "dart:convert";

import "api_client.dart";
import "logged_http.dart" as http;
import "logger_service.dart";
import "secure_store.dart";

class NextmoeTokenStore {
  static const _accessKey = "nextmoe_access_token";
  static const _refreshKey = "nextmoe_refresh_token";
  static const _expiresKey = "nextmoe_expires_at";
  static const _refreshSkew = Duration(seconds: 60);
  static const _fallbackLifetimeSeconds = 900;

  static String _scope(ApiClient api) =>
      "${api.baseUrl}|${api.cachedUsername ?? ""}";

  static String _key(String prefix, ApiClient api) =>
      "$prefix::${_scope(api)}";

  /// Persist the tokens returned by the Sena server after login/binding.
  static Future<void> saveFromResponse(
    ApiClient api,
    Map<String, dynamic> data,
  ) async {
    final access = data["nextmoe_access_token"]?.toString() ?? "";
    if (access.isEmpty) return;
    final refresh = data["nextmoe_refresh_token"]?.toString() ?? "";
    final expiresIn = int.tryParse(
          data["nextmoe_expires_in"]?.toString() ?? "",
        ) ??
        _fallbackLifetimeSeconds;
    final expiresAt = DateTime.now()
        .add(Duration(seconds: expiresIn))
        .millisecondsSinceEpoch;
    await SecureStore.setString(_key(_accessKey, api), access);
    if (refresh.isNotEmpty) {
      await SecureStore.setString(_key(_refreshKey, api), refresh);
    }
    await SecureStore.setString(_key(_expiresKey, api), expiresAt.toString());
  }

  static Future<void> clear(ApiClient api) async {
    await SecureStore.delete(_key(_accessKey, api));
    await SecureStore.delete(_key(_refreshKey, api));
    await SecureStore.delete(_key(_expiresKey, api));
  }

  /// Return a usable access token, refreshing it when it is about to expire.
  ///
  /// Returns null when the account never authorized with catalog access or
  /// when the refresh token is no longer valid.
  static Future<String?> getValidAccessToken(ApiClient api) async {
    final access = await SecureStore.getString(_key(_accessKey, api)) ?? "";
    final expiresAt = int.tryParse(
          await SecureStore.getString(_key(_expiresKey, api)) ?? "",
        ) ??
        0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (access.isNotEmpty &&
        expiresAt - _refreshSkew.inMilliseconds > now) {
      return access;
    }
    final refresh = await SecureStore.getString(_key(_refreshKey, api)) ?? "";
    if (refresh.isEmpty) return null;
    return _refresh(api, refresh);
  }

  static Future<String?> _refresh(ApiClient api, String refreshToken) async {
    final providers = await api.getAuthProviders();
    final nextmoe = providers?["nextmoe"];
    if (nextmoe is! Map) return null;
    final issuer = nextmoe["issuer"]?.toString() ?? "";
    final clientId = nextmoe["client_id"]?.toString() ?? "";
    if (issuer.isEmpty || clientId.isEmpty) return null;

    final base = issuer.replaceFirst(RegExp(r"/+$"), "");
    final uri = Uri.parse("$base/oauth/token");
    try {
      final resp = await http
          .post(
            uri,
            headers: const {
              "Accept": "application/json",
              "Content-Type": "application/x-www-form-urlencoded",
            },
            body: {
              "grant_type": "refresh_token",
              "refresh_token": refreshToken,
              "client_id": clientId,
            },
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        LoggerService().warn(
          "nextmoe token refresh rejected: status=${resp.statusCode}",
        );
        await clear(api);
        return null;
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final access = data["access_token"]?.toString() ?? "";
      if (access.isEmpty) {
        await clear(api);
        return null;
      }
      await saveFromResponse(api, {
        "nextmoe_access_token": access,
        "nextmoe_refresh_token": data["refresh_token"] ?? refreshToken,
        "nextmoe_expires_in": data["expires_in"],
      });
      return access;
    } catch (e, stackTrace) {
      LoggerService().warn("nextmoe token refresh failed", e, stackTrace);
      return null;
    }
  }
}
