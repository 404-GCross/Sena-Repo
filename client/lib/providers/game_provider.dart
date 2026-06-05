/// Game library state management.

import "package:flutter/material.dart";

import "../models/game.dart";
import "../services/api_client.dart";

class GameProvider extends ChangeNotifier {
  final ApiClient _api = ApiClient();
  ApiClient get api => _api;  // Expose for detail screens
  List<GameSummary> _games = [];
  List<Tag> _tags = [];
  bool _isLoading = false;
  String? _error;
  String _searchQuery = "";

  List<GameSummary> get games => _searchQuery.isEmpty
      ? _games
      : _games.where((g) =>
          g.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          g.tagNames.any((t) => t.toLowerCase().contains(_searchQuery.toLowerCase()))).toList();

  List<Tag> get tags => _tags;
  bool get isLoading => _isLoading;
  String? get error => _error;

  void connect(String host, int port) {
    _api.connect(host, port: port);
  }

  Future<void> loadGames() async {
    _isLoading = true;
    notifyListeners();
    try {
      _games = await _api.getGames();
      _tags = await _api.getTags();
      _error = null;
    } catch (e) {
      _error = e.toString();
    }
    _isLoading = false;
    notifyListeners();
  }

  void search(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  Future<void> deleteGame(int id) async {
    await _api.deleteGame(id);
    _games.removeWhere((g) => g.id == id);
    notifyListeners();
  }

  Future<void> refreshRoot(int rootId) async {
    await _api.refreshRoot(rootId);
    await loadGames();
  }

  Future<void> scrapeGame(int gameId) async {
    await _api.scrapeGame(gameId);
    await loadGames();
  }
}
