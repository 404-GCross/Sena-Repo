/// HTTP client for communicating with the Sena Repo server.

import "dart:convert";
import "dart:io";
import "dart:async";

import "package:http/http.dart" as http;
import "package:shared_preferences/shared_preferences.dart";

import "../models/game.dart";
import "api_response_utils.dart";
import "secure_store.dart";

/// Global access token — always accessible, survives Provider rebuilds.
String? _accessToken;

/// Cached user info from the last login.
String? _cachedUsername;
bool? _cachedIsAdmin;
String? _cachedRole;

/// Legacy accessor — maintained for backward compatibility with download_service.
String? get globalToken => _accessToken;

Map<String, String>? get mediaAuthHeaders {
  if (_accessToken == null || _accessToken!.isEmpty) return null;
  return {"Authorization": "Bearer $_accessToken"};
}

/// Hostname of the configured server — only bypasses TLS for this host.
String? trustedServerHost;

class AuthException implements Exception {
  final String message;
  AuthException(this.message);
  @override
  String toString() => message;
}

class ApiClient {
  final http.Client _client = http.Client();
  String? _baseUrl;

  String get baseUrl => _baseUrl ?? "http://localhost:11451";
  bool get isConnected => _baseUrl != null;

  String? get accessToken => _accessToken;
  String? get cachedUsername => _cachedUsername;
  bool? get cachedIsAdmin => _cachedIsAdmin;
  String? get cachedRole => _cachedRole;

  Map<String, String> get headers {
    if (_accessToken != null && _accessToken!.isNotEmpty) {
      return {"Authorization": "Bearer $_accessToken"};
    }
    print("[ApiClient] WARN: headers called with no token set!");
    return {};
  }

  static Future<void> restoreToken() async {
    if (_accessToken != null && _accessToken!.isNotEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    _accessToken = await SecureStore.getString("auth_token");
    _cachedUsername = prefs.getString("username");
    _cachedIsAdmin = prefs.getBool("is_admin");
    _cachedRole = prefs.getString("role");
    if (_accessToken != null && _accessToken!.isNotEmpty) {
      print("[ApiClient] Token restored from secure storage");
    } else {
      print("[ApiClient] No token found on disk");
    }
  }

  static Future<void> _persistTokens({
    String? accessToken,
    String? username,
    bool? isAdmin,
    String? role,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (accessToken != null && accessToken.isNotEmpty) {
      await SecureStore.setString("auth_token", accessToken);
    }
    if (username != null) {
      await prefs.setString("username", username);
      _cachedUsername = username;
    }
    if (isAdmin != null) {
      await prefs.setBool("is_admin", isAdmin);
      _cachedIsAdmin = isAdmin;
    }
    if (role != null) {
      await prefs.setString("role", role);
      _cachedRole = role;
    }
  }

  static Future<void> persistSessionInfo({
    String? accessToken,
    String? username,
    bool? isAdmin,
    String? role,
  }) async {
    if (accessToken != null && accessToken.isNotEmpty) {
      _accessToken = accessToken;
    }
    await _persistTokens(
      accessToken: accessToken,
      username: username,
      isAdmin: isAdmin,
      role: role,
    );
  }

  static Future<void> clearTokens() async {
    _accessToken = null;
    _cachedUsername = null;
    _cachedIsAdmin = null;
    _cachedRole = null;
    final prefs = await SharedPreferences.getInstance();
    await SecureStore.delete("auth_token");
    await prefs.remove("username");
    await prefs.remove("is_admin");
    await prefs.remove("role");
  }

  Future<void> connect(
    String host, {
    int port = 11451,
    bool useHttps = false,
  }) async {
    final scheme = useHttps ? "https" : "http";
    _baseUrl = "$scheme://$host:$port";
    trustedServerHost = host;
  }

  /// Execute an HTTP request.
  bool _isRetryableStatus(int statusCode) =>
      statusCode == 408 || statusCode == 429 || statusCode >= 500;

  bool _isRetryableError(Object error) =>
      error is SocketException ||
      error is TimeoutException ||
      error is http.ClientException;

  Future<http.Response> _execute(
    Future<http.Response> Function() request, {
    bool allowRetry = true,
  }) async {
    const maxAttempts = 2;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final response = await request();
        if (!allowRetry ||
            attempt == maxAttempts - 1 ||
            !_isRetryableStatus(response.statusCode)) {
          return response;
        }
      } catch (error) {
        if (!allowRetry ||
            attempt == maxAttempts - 1 ||
            !_isRetryableError(error)) {
          rethrow;
        }
      }
      await Future.delayed(Duration(milliseconds: 250 * (attempt + 1)));
    }
    throw StateError("HTTP retry loop exited unexpectedly");
  }

  // --- Games ---

  Future<List<GameSummary>> getGames({
    int page = 1,
    int pageSize = 200,
    String? tag,
    String? platform,
    int? rootId,
  }) async {
    final params = <String, String>{
      "page": page.toString(),
      "page_size": pageSize.toString(),
    };
    if (tag != null) params["tag"] = tag;
    if (platform != null) params["platform"] = platform;
    if (rootId != null) params["root_id"] = rootId.toString();

    final uri = Uri.parse(
      "$baseUrl/api/games",
    ).replace(queryParameters: params);
    final resp = await _execute(() => _client.get(uri, headers: headers));
    if (resp.statusCode != 200) throw HttpException("Failed to load games");

    final List<dynamic> data = jsonDecode(resp.body);
    return data
        .map((j) => GameSummary.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  Future<GameDetail> getGame(int id) async {
    final resp = await _execute(
      () => _client.get(Uri.parse("$baseUrl/api/games/$id"), headers: headers),
    );
    if (resp.statusCode == 401) throw AuthException("登录已失效，请重新登录");
    if (resp.statusCode != 200) throw HttpException("Game not found");
    return GameDetail.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<void> deleteGame(int id) async {
    final resp = await _execute(
      () =>
          _client.delete(Uri.parse("$baseUrl/api/games/$id"), headers: headers),
    );
    if (resp.statusCode != 200) throw HttpException("Failed to delete game");
  }

  // --- Tags ---

  Future<List<Tag>> getTags() async {
    final resp = await _execute(
      () => _client.get(Uri.parse("$baseUrl/api/tags"), headers: headers),
    );
    if (resp.statusCode != 200) throw HttpException("Failed to load tags");
    final List<dynamic> data = jsonDecode(resp.body);
    return data.map((j) => Tag.fromJson(j as Map<String, dynamic>)).toList();
  }

  // --- Roots ---

  Future<Map<String, dynamic>> refreshRoot(int id) async {
    final resp = await _execute(
      () => _client.post(
        Uri.parse("$baseUrl/api/roots/$id/refresh"),
        headers: headers,
      ),
    );
    if (resp.statusCode != 200) throw HttpException("Refresh failed");
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> refreshAllRoots() async {
    final resp = await _execute(
      () => _client.post(
        Uri.parse("$baseUrl/api/roots/refresh-all"),
        headers: headers,
      ),
    );
    if (resp.statusCode != 200) throw HttpException("Refresh all failed");
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // --- Setup ---

  Future<bool> checkSetupNeeded() async {
    try {
      final resp = await _execute(
        () => _client
            .get(Uri.parse("$baseUrl/api/setup/status"), headers: headers)
            .timeout(const Duration(seconds: 5)),
        allowRetry: false,
      );
      if (resp.statusCode == 200) {
        final data = tryDecodeJsonMap(resp.body);
        return data != null && data["needs_setup"] == true;
      }
    } catch (_) {}
    return false;
  }

  // --- Auth ---

  Future<Map<String, dynamic>> login(String username, String password) async {
    try {
      final resp = await _client
          .post(
            Uri.parse("$baseUrl/api/auth/login"),
            headers: {"Content-Type": "application/json"},
            body: jsonEncode({"username": username, "password": password}),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = tryDecodeJsonMap(resp.body);
        if (data == null) {
          throw AuthException(
            describeUnexpectedApiResponse(
              resp,
              expected: "登录",
              endpointPath: "/api/auth/login",
            ),
          );
        }

        _accessToken = data["token"]?.toString();
        if (_accessToken == null || _accessToken!.isEmpty) {
          throw AuthException(
            "服务器返回 200，但登录响应缺少 token，域名可能没有把 /api/auth/login 转发到服务端",
          );
        }

        var username = data["username"]?.toString();
        var isAdmin = data["is_admin"] == true;
        var role = data["role"]?.toString() ?? (isAdmin ? "admin" : "user");
        try {
          final meResp = await _client
              .get(
                Uri.parse("$baseUrl/api/auth/profile/me"),
                headers: {"Authorization": "Bearer $_accessToken"},
              )
              .timeout(const Duration(seconds: 5));
          if (meResp.statusCode == 200) {
            final me = tryDecodeJsonMap(meResp.body);
            if (me == null || me["id"] == null) {
              throw AuthException(
                describeUnexpectedApiResponse(
                  meResp,
                  expected: "用户资料",
                  endpointPath: "/api/auth/profile/me",
                ),
              );
            }
            username = me["username"]?.toString() ?? username;
            isAdmin = me["is_admin"] == true;
            role = me["role"]?.toString() ?? role;
            data["username"] = username;
            data["is_admin"] = isAdmin;
            data["role"] = role;
          }
        } on AuthException {
          rethrow;
        } catch (_) {}
        await _persistTokens(
          accessToken: _accessToken,
          username: username,
          isAdmin: isAdmin,
          role: role,
        );
        return data;
      }

      final body = tryDecodeJsonMap(resp.body);
      if (body != null && body["detail"] != null) {
        throw AuthException(body["detail"].toString());
      }
      throw AuthException(
        describeUnexpectedApiResponse(
          resp,
          expected: "登录",
          endpointPath: "/api/auth/login",
        ),
      );
    } on SocketException catch (e) {
      throw AuthException("无法连接服务器: ${e.message}");
    } on TimeoutException {
      throw AuthException("连接服务器超时");
    }
  }

  Future<bool> logout() async {
    try {
      await clearTokens();
      return true;
    } catch (_) {
      await clearTokens();
      return false;
    }
  }

  // --- Scraper ---

  Future<Map<String, dynamic>> scrapeGame(int gameId) async {
    final resp = await _execute(
      () => _client.post(
        Uri.parse("$baseUrl/api/games/$gameId/scrape"),
        headers: headers,
      ),
    );
    if (resp.statusCode != 200) throw HttpException("Scrape failed");
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }
}
