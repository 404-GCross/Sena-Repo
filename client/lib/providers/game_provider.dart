/// Game library state management.

import "package:flutter/material.dart";

import "../models/game.dart";
import "../services/api_client.dart";
import "../services/logger_service.dart";

class GameProvider extends ChangeNotifier {
  final ApiClient _api = ApiClient();
  ApiClient get api => _api;  // Expose for detail screens
  List<GameSummary> _games = [];
  List<Tag> _tags = [];
  bool _isLoading = false;
  String? _error;
  String _searchQuery = "";
  String? _sortBy;
  String? _filterPlatform;
  String? _filterDeveloper;
  bool? _filterHasCover;

  List<GameSummary> get games {
    var list = _games;
    // Client-side search
    if (_searchQuery.isNotEmpty) {
      list = list.where((g) =>
          g.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          g.tagNames.any((t) => t.toLowerCase().contains(_searchQuery.toLowerCase()))).toList();
    }
    // Client-side platform filter
    if (_filterPlatform != null) {
      list = list.where((g) => g.platformSummary.contains(_filterPlatform!)).toList();
    }
    // Client-side cover filter
    if (_filterHasCover == true) {
      list = list.where((g) => g.coverPath != null && g.coverPath!.isNotEmpty).toList();
    } else if (_filterHasCover == false) {
      list = list.where((g) => g.coverPath == null || g.coverPath!.isEmpty).toList();
    }
    // Client-side sort
    if (_sortBy == "name") {
      list.sort((a, b) => a.name.compareTo(b.name));
    } else if (_sortBy == "name_desc") {
      list.sort((a, b) => b.name.compareTo(a.name));
    } else if (_sortBy == "company") {
      list.sort((a, b) => (a.companyName ?? "").toLowerCase().compareTo((b.companyName ?? "").toLowerCase()));
    } else if (_sortBy == "developer") {
      list.sort((a, b) => (a.developer ?? "").toLowerCase().compareTo((b.developer ?? "").toLowerCase()));
    }
    return list;
  }

  List<Tag> get tags => _tags;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String? get sortBy => _sortBy;
  String? get filterPlatform => _filterPlatform;
  String? get filterDeveloper => _filterDeveloper;
  bool? get filterHasCover => _filterHasCover;

  void connect(String host, int port, {bool useHttps = false}) {
    _api.connect(host, port: port, useHttps: useHttps);
  }

  Future<void> loadGames() async {
    _isLoading = true;
    notifyListeners();
    try {
      // Fetch all games across pages (server limits page_size to 200)
      final all = <GameSummary>[];
      int page = 1;
      while (true) {
        final batch = await _api.getGames(page: page, pageSize: 200);
        if (batch.isEmpty) break;
        all.addAll(batch);
        page++;
      }
      _games = all;
      _tags = await _api.getTags();
      _error = null;
      LoggerService().info("加载游戏库完成: ${_games.length} 款游戏");
    } catch (e) {
      _error = e.toString();
      LoggerService().error("加载游戏库失败", e);
    }
    _isLoading = false;
    notifyListeners();
  }

  /// Refresh game list silently (no loading indicator).
  Future<void> refreshGames() async {
    try {
      final all = <GameSummary>[];
      int page = 1;
      while (true) {
        final batch = await _api.getGames(page: page, pageSize: 200);
        if (batch.isEmpty) break;
        all.addAll(batch);
        page++;
      }
      _games = all;
      _tags = await _api.getTags();
      _error = null;
    } catch (_) {
      // silent
    }
    notifyListeners();
  }

  void setFilters({String? platform, String? developer, bool? hasCover}) {
    _filterPlatform = platform;
    _filterDeveloper = developer;
    _filterHasCover = hasCover;
    notifyListeners();
  }

  void setSort(String? sort) {
    _sortBy = sort;
    notifyListeners();
  }

  void clearFilters() {
    _filterPlatform = null;
    _filterDeveloper = null;
    _filterHasCover = null;
    _sortBy = null;
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
