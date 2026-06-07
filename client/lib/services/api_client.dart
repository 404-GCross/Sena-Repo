/// HTTP client for communicating with the Sena Repo server.

import "dart:convert";
import "dart:io";

import "package:http/http.dart" as http;

import "../models/game.dart";

class ApiClient {
  final http.Client _client = http.Client();
  String? _baseUrl;

  String get baseUrl => _baseUrl ?? "http://localhost:11451";
  bool get isConnected => _baseUrl != null;

  void connect(String host, {int port = 11451}) {
    _baseUrl = "http://$host:$port";
  }

  Future<bool> healthCheck() async {
    try {
      final resp = await _client
          .get(Uri.parse("$baseUrl/api/health"))
          .timeout(const Duration(seconds: 5));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // --- Games ---

  Future<List<GameSummary>> getGames({
    int page = 1,
    int pageSize = 50,
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
    final resp = await _client.get(uri);
    if (resp.statusCode != 200) throw HttpException("Failed to load games");

    final List<dynamic> data = jsonDecode(resp.body);
    return data.map((j) => GameSummary.fromJson(j as Map<String, dynamic>)).toList();
  }

  Future<List<GameSummary>> searchGames(String query) async {
    final uri = Uri.parse("$baseUrl/api/games/search").replace(
      queryParameters: {"q": query},
    );
    final resp = await _client.get(uri);
    if (resp.statusCode != 200) throw HttpException("Search failed");

    final List<dynamic> data = jsonDecode(resp.body);
    return data.map((j) => GameSummary.fromJson(j as Map<String, dynamic>)).toList();
  }

  Future<GameDetail> getGame(int id) async {
    final resp = await _client.get(Uri.parse("$baseUrl/api/games/$id"));
    if (resp.statusCode != 200) throw HttpException("Game not found");
    return GameDetail.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<void> deleteGame(int id) async {
    final resp = await _client.delete(Uri.parse("$baseUrl/api/games/$id"));
    if (resp.statusCode != 200) throw HttpException("Failed to delete game");
  }

  // --- Tags ---

  Future<List<Tag>> getTags() async {
    final resp = await _client.get(Uri.parse("$baseUrl/api/tags"));
    if (resp.statusCode != 200) throw HttpException("Failed to load tags");
    final List<dynamic> data = jsonDecode(resp.body);
    return data.map((j) => Tag.fromJson(j as Map<String, dynamic>)).toList();
  }

  Future<Tag> createTag(String name, {String color = "#3B82F6"}) async {
    final resp = await _client.post(
      Uri.parse("$baseUrl/api/tags"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({"name": name, "color": color}),
    );
    if (resp.statusCode != 201) throw HttpException("Failed to create tag");
    return Tag.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<void> deleteTag(int id) async {
    await _client.delete(Uri.parse("$baseUrl/api/tags/$id"));
  }

  Future<void> addTagToGame(int gameId, String tagName) async {
    await _client.post(
      Uri.parse("$baseUrl/api/games/$gameId/tags/$tagName"),
    );
  }

  Future<void> removeTagFromGame(int gameId, int tagId) async {
    await _client.delete(
      Uri.parse("$baseUrl/api/games/$gameId/tags/$tagId"),
    );
  }

  // --- Roots ---

  Future<Map<String, dynamic>> addRoot(String path) async {
    final resp = await _client.post(
      Uri.parse("$baseUrl/api/roots"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({"path": path}),
    );
    if (resp.statusCode != 201) throw HttpException("Failed to add root");
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> refreshRoot(int id) async {
    final resp = await _client.post(Uri.parse("$baseUrl/api/roots/$id/refresh"));
    if (resp.statusCode != 200) throw HttpException("Refresh failed");
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> refreshAllRoots() async {
    final resp = await _client.post(Uri.parse("$baseUrl/api/roots/refresh-all"));
    if (resp.statusCode != 200) throw HttpException("Refresh all failed");
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // --- Scraper ---

  Future<Map<String, dynamic>> scrapeGame(int gameId) async {
    final resp = await _client.post(
      Uri.parse("$baseUrl/api/games/$gameId/scrape"),
    );
    if (resp.statusCode != 200) throw HttpException("Scrape failed");
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // --- Download URL ---

  String downloadUrl(int gameId, int versionId) {
    return "$baseUrl/api/download/$gameId/$versionId";
  }
}
