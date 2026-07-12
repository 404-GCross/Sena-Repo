/// HTTP client for communicating with the Sena Repo server.

import "dart:convert";
import "dart:io";

import "package:http/http.dart" as http;
import "package:shared_preferences/shared_preferences.dart";

import "../models/game.dart";

/// Global access token — always accessible, survives Provider rebuilds.
String? _accessToken;

/// Cached user info from the last login.
String? _cachedUsername;
bool? _cachedIsAdmin;

/// Legacy accessor — maintained for backward compatibility with download_service.
String? get globalToken => _accessToken;

/// Hostname of the configured server — only bypasses TLS for this host.
String? trustedServerHost;

class AuthException implements Exception {
  final String message;
  AuthException(this.message);
  @override
  String toString() => "AuthException: $message";
}

class ApiClient {
  final http.Client _client = http.Client();
  String? _baseUrl;

  String get baseUrl => _baseUrl ?? "http://localhost:11451";
  bool get isConnected => _baseUrl != null;

  String? get accessToken => _accessToken;
  String? get cachedUsername => _cachedUsername;
  bool? get cachedIsAdmin => _cachedIsAdmin;

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
    _accessToken = prefs.getString("auth_token");
    _cachedUsername = prefs.getString("username");
    _cachedIsAdmin = prefs.getBool("is_admin");
    if (_accessToken != null && _accessToken!.isNotEmpty) {
      print("[ApiClient] Token restored from disk: ${_accessToken!.length >= 8 ? _accessToken!.substring(0, 8) : _accessToken}...");
    } else {
      print("[ApiClient] No token found on disk");
    }
  }

  static Future<void> _persistTokens({
    String? accessToken,
    String? username,
    bool? isAdmin,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (accessToken != null && accessToken.isNotEmpty) {
      await prefs.setString("auth_token", accessToken);
    }
    if (username != null) {
      await prefs.setString("username", username);
      _cachedUsername = username;
    }
    if (isAdmin != null) {
      await prefs.setBool("is_admin", isAdmin);
      _cachedIsAdmin = isAdmin;
    }
  }

  static Future<void> clearTokens() async {
    _accessToken = null;
    _cachedUsername = null;
    _cachedIsAdmin = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove("auth_token");
    await prefs.remove("username");
    await prefs.remove("is_admin");
  }

  Future<void> connect(String host, {int port = 11451, bool useHttps = false}) async {
    final scheme = useHttps ? "https" : "http";
    _baseUrl = "$scheme://$host:$port";
    trustedServerHost = host;
  }

  /// Execute an HTTP request.
  Future<http.Response> _execute(Future<http.Response> Function() request, {bool allowRetry = true}) async {
    return await request();
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

    final uri = Uri.parse("$baseUrl/api/games").replace(queryParameters: params);
    final resp = await _execute(() => _client.get(uri, headers: headers));
    if (resp.statusCode != 200) throw HttpException("Failed to load games");

    final List<dynamic> data = jsonDecode(resp.body);
    return data.map((j) => GameSummary.fromJson(j as Map<String, dynamic>)).toList();
  }

  Future<GameDetail> getGame(int id) async {
    final resp = await _execute(() => _client.get(Uri.parse("$baseUrl/api/games/$id"), headers: headers));
    if (resp.statusCode == 401) throw AuthException("登录已失效，请重新登录");
    if (resp.statusCode != 200) throw HttpException("Game not found");
    return GameDetail.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<void> deleteGame(int id) async {
    final resp = await _execute(() => _client.delete(Uri.parse("$baseUrl/api/games/$id"), headers: headers));
    if (resp.statusCode != 200) throw HttpException("Failed to delete game");
  }

  // --- Tags ---

  Future<List<Tag>> getTags() async {
    final resp = await _execute(() => _client.get(Uri.parse("$baseUrl/api/tags"), headers: headers));
    if (resp.statusCode != 200) throw HttpException("Failed to load tags");
    final List<dynamic> data = jsonDecode(resp.body);
    return data.map((j) => Tag.fromJson(j as Map<String, dynamic>)).toList();
  }

  // --- Roots ---

  Future<Map<String, dynamic>> refreshRoot(int id) async {
    final resp = await _execute(() => _client.post(Uri.parse("$baseUrl/api/roots/$id/refresh"), headers: headers));
    if (resp.statusCode != 200) throw HttpException("Refresh failed");
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> refreshAllRoots() async {
    final resp = await _execute(() => _client.post(Uri.parse("$baseUrl/api/roots/refresh-all"), headers: headers));
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
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        return data["needs_setup"] == true;
      }
    } catch (_) {}
    return false;
  }

  // --- Auth ---

  Future<Map<String, dynamic>?> login(String username, String password) async {
    try {
      final resp = await _client.post(
        Uri.parse("$baseUrl/api/auth/login"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"username": username, "password": password}),
      );
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        _accessToken = data["token"]?.toString();
        if (_accessToken != null && _accessToken!.isNotEmpty) {
          await _persistTokens(
            accessToken: _accessToken,
            username: data["username"]?.toString(),
            isAdmin: data["is_admin"] == true,
          );
        }
        return data;
      }
    } catch (_) {}
    return null;
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
    final resp = await _execute(() => _client.post(
      Uri.parse("$baseUrl/api/games/$gameId/scrape"),
      headers: headers,
    ));
    if (resp.statusCode != 200) throw HttpException("Scrape failed");
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }
}
