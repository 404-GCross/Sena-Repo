/// OAuth token storage and refresh for user-scoped scraping.
///
/// Tokens are kept per provider + server + account so multiple saved profiles
/// never share credentials, and are refreshed straight against the OP (public
/// client, PKCE, no client_secret).

import "dart:convert";

import "api_client.dart";
import "logged_http.dart" as http;
import "logger_service.dart";
import "secure_store.dart";

class OAuthTokenStore {
  static const _refreshSkew = Duration(seconds: 60);
  static const _fallbackLifetimeSeconds = 900;

  static String _scope(ApiClient api) {
    final userId = api.cachedUserId;
    if (userId != null && userId > 0) {
      return "${api.baseUrl}|id:$userId";
    }
    return "${api.baseUrl}|${api.cachedUsername ?? ""}";
  }

  static String _legacyScope(ApiClient api) =>
      "${api.baseUrl}|${api.cachedUsername ?? ""}";

  static String _key(String provider, String field, ApiClient api) =>
      "${provider}_$field::${_scope(api)}";

  static String _legacyKey(String provider, String field, ApiClient api) =>
      "${provider}_$field::${_legacyScope(api)}";

  static Future<String?> _read(
    ApiClient api,
    String provider,
    String field,
  ) async {
    final value =
        await SecureStore.getString(_key(provider, field, api)) ?? "";
    if (value.isNotEmpty) return value;
    return SecureStore.getString(_legacyKey(provider, field, api));
  }

  /// Persist the tokens returned by the Sena server after login/binding.
  static Future<void> saveFromResponse(
    ApiClient api,
    Map<String, dynamic> data, {
    String provider = "nextmoe",
  }) async {
    final access = data["${provider}_access_token"]?.toString() ?? "";
    if (access.isEmpty) return;
    final refresh = data["${provider}_refresh_token"]?.toString() ?? "";
    final expiresIn = int.tryParse(
          data["${provider}_expires_in"]?.toString() ?? "",
        ) ??
        _fallbackLifetimeSeconds;
    final expiresAt = DateTime.now()
        .add(Duration(seconds: expiresIn))
        .millisecondsSinceEpoch;
    await SecureStore.setString(_key(provider, "access_token", api), access);
    if (refresh.isNotEmpty) {
      await SecureStore.setString(
        _key(provider, "refresh_token", api),
        refresh,
      );
    }
    await SecureStore.setString(
      _key(provider, "expires_at", api),
      expiresAt.toString(),
    );
  }

  static Future<void> clear(
    ApiClient api, {
    String provider = "nextmoe",
  }) async {
    for (final field in const ["access_token", "refresh_token", "expires_at"]) {
      await SecureStore.delete(_key(provider, field, api));
      await SecureStore.delete(_legacyKey(provider, field, api));
    }
  }

  /// Return a usable access token, refreshing it when it is about to expire.
  ///
  /// Returns null when the account never authorized with the required scope or
  /// when the refresh token is no longer valid.
  static Future<String?> getValidAccessToken(
    ApiClient api, {
    String provider = "nextmoe",
  }) async {
    final access = await _read(api, provider, "access_token") ?? "";
    final expiresAt =
        int.tryParse(await _read(api, provider, "expires_at") ?? "") ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (access.isNotEmpty && expiresAt - _refreshSkew.inMilliseconds > now) {
      return access;
    }
    final refresh = await _read(api, provider, "refresh_token") ?? "";
    if (refresh.isEmpty) return null;
    return _refresh(api, provider, refresh);
  }

  static Future<String?> _refresh(
    ApiClient api,
    String provider,
    String refreshToken,
  ) async {
    final providers = await api.getAuthProviders();
    final info = providers?[provider];
    if (info is! Map) return null;
    final issuer = info["issuer"]?.toString() ?? "";
    final clientId = info["client_id"]?.toString() ?? "";
    if (issuer.isEmpty || clientId.isEmpty) return null;

    final base = issuer.replaceFirst(RegExp(r"/+$"), "");
    final tokenUrl = info["token_url"]?.toString() ?? "";
    final uri = Uri.parse(
      tokenUrl.isNotEmpty
          ? tokenUrl
          : provider == "hikarinagi"
              ? "$base/token"
              : "$base/oauth/token",
    );
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
          "$provider token refresh rejected: status=${resp.statusCode}",
        );
        await clear(api, provider: provider);
        return null;
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final access = data["access_token"]?.toString() ?? "";
      if (access.isEmpty) {
        await clear(api, provider: provider);
        return null;
      }
      await saveFromResponse(api, {
        "${provider}_access_token": access,
        "${provider}_refresh_token": data["refresh_token"] ?? refreshToken,
        "${provider}_expires_in": data["expires_in"],
      }, provider: provider);
      return access;
    } catch (e, stackTrace) {
      LoggerService().warn("$provider token refresh failed", e, stackTrace);
      return null;
    }
  }
}
