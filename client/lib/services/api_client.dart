/// HTTP client for communicating with the Sena Repo server.

import "dart:convert";
import "dart:io";

import "package:http/http.dart" as http;
import "package:shared_preferences/shared_preferences.dart";

import "../models/game.dart";

/// Global token store — always accessible, survives Provider rebuilds.
String? globalToken;

/// Hostname of the configured server — only bypasses TLS for this host.
String? trustedServerHost;

class ApiClient {
  final http.Client _client = http.Client();
  String? _baseUrl;

  String get baseUrl => _baseUrl ?? "http://localhost:11451";
  bool get isConnected => _baseUrl != null;

  Map<String, String> get headers {
    final t = globalToken;
    if (t != null && t.isNotEmpty) {
      return {"Authorization": "Bearer $t"};
    }
    print("[ApiClient] WARN: headers called with no token set!");
    return {};
  }

  /// Called at app start to restore token from disk.
  static Future<void> restoreToken() async {
    if (globalToken != null && globalToken!.isNotEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    globalToken = prefs.getString("auth_token");
    if (globalToken != null) {
      print("[ApiClient] Token restored from disk: ${globalToken!.substring(0, 8)}...");
    } else {
      print("[ApiClient] No token found on disk");
    }
  }

  static Future<void> setGlobalToken(String? token) async {
    globalToken = token;
    if (token != null && token.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("auth_token", token);
    }
  }

  Future<void> setToken(String? token) => setGlobalToken(token);

  void connect(String host, {int port = 11451, bool useHttps = false}) {
    final scheme = useHttps ? "https" : "http";
    _baseUrl = "$scheme://$host:$port";
    trustedServerHost = host;
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
    final resp = await _client.get(uri, headers: headers);
    if (resp.statusCode != 200) throw HttpException("Failed to load games");

    final decoded = jsonDecode(resp.body);
    if (decoded is! List) return [];
    return (decoded as List).map((j) => GameSummary.fromJson(j as Map<String, dynamic>)).toList();
  }


  Future<GameDetail> getGame(int id) async {
    final resp = await _client.get(Uri.parse("$baseUrl/api/games/$id"), headers: headers);
    if (resp.statusCode != 200) throw HttpException("Game not found");
    return GameDetail.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<void> deleteGame(int id) async {
    final resp = await _client.delete(Uri.parse("$baseUrl/api/games/$id"), headers: headers);
    if (resp.statusCode != 200) throw HttpException("Failed to delete game");
  }

  // --- Tags ---

  Future<List<Tag>> getTags() async {
    final resp = await _client.get(Uri.parse("$baseUrl/api/tags"), headers: headers);
    if (resp.statusCode != 200) throw HttpException("Failed to load tags");
    final List<dynamic> data = jsonDecode(resp.body);
    return data.map((j) => Tag.fromJson(j as Map<String, dynamic>)).toList();
  }





  // --- Roots ---


  Future<Map<String, dynamic>> refreshRoot(int id) async {
    final resp = await _client.post(Uri.parse("$baseUrl/api/roots/$id/refresh"), headers: headers);
    if (resp.statusCode != 200) throw HttpException("Refresh failed");
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> refreshAllRoots() async {
    final resp = await _client.post(Uri.parse("$baseUrl/api/roots/refresh-all"), headers: headers);
    if (resp.statusCode != 200) throw HttpException("Refresh all failed");
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // --- Setup ---

  Future<bool> checkSetupNeeded() async {
    try {
      final resp = await _client
          .get(Uri.parse("$baseUrl/api/setup/status"), headers: headers)
          .timeout(const Duration(seconds: 5));
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
        setGlobalToken(data["token"]?.toString());
        return data;
      }
    } catch (_) {}
    return null;
  }

  // --- Scraper ---

  Future<Map<String, dynamic>> scrapeGame(int gameId) async {
    final resp = await _client.post(
      Uri.parse("$baseUrl/api/games/$gameId/scrape"),
      headers: headers,
    );
    if (resp.statusCode != 200) throw HttpException("Scrape failed");
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // --- Download URL ---

}
