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





  // --- Roots ---


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

  // --- Setup ---

  Future<bool> checkSetupNeeded() async {
    try {
      final resp = await _client
          .get(Uri.parse("$baseUrl/api/setup/status"))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        return data["needs_setup"] == true;
      }
    } catch (_) {}
    return false;
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

}
