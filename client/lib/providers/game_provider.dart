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
  List<PlatformCategory> _platforms = _fallbackPlatforms();
  bool _isLoading = false;
  String? _error;
  String _searchQuery = "";
  String? _sortBy;
  String? _filterPlatform;
  String? _filterDeveloper;
  bool? _filterHasCover;

  List<GameSummary> get games {
    var list = List<GameSummary>.from(_games);
    // Client-side search
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      list = list.where((g) =>
          g.name.toLowerCase().contains(query) ||
          (g.alias ?? "").toLowerCase().contains(query) ||
          g.tagNames.any((t) => t.toLowerCase().contains(query))).toList();
    }
    // Client-side platform filter (exact category match)
    if (_filterPlatform != null) {
      final target = _filterPlatform!;
      list = list
          .where((g) => g.platformSummary.split(", ").contains(target))
          .toList();
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
    } else if (_sortBy == "alias") {
      list.sort((a, b) => _aliasSortKey(a).compareTo(_aliasSortKey(b)));
    } else if (_sortBy == "alias_desc") {
      list.sort((a, b) => _aliasSortKey(b).compareTo(_aliasSortKey(a)));
    } else if (_sortBy == "company") {
      list.sort((a, b) => (a.companyName ?? "").toLowerCase().compareTo((b.companyName ?? "").toLowerCase()));
    } else if (_sortBy == "developer") {
      list.sort((a, b) => (a.developer ?? "").toLowerCase().compareTo((b.developer ?? "").toLowerCase()));
    } else if (_sortBy == "developer_desc") {
      list.sort((a, b) => (b.developer ?? "").toLowerCase().compareTo((a.developer ?? "").toLowerCase()));
    }
    return list;
  }

  /// Unfiltered list, for batch operations that must see hidden entries too.
  List<GameSummary> get allGames => _games;

  /// Fallback categories for older servers without the platforms API.
  static List<PlatformCategory> _fallbackPlatforms() {
    const names = ["PC", "KRKR", "ONS", "Ty", "直装", "未分类"];
    return [
      for (var index = 0; index < names.length; index++)
        PlatformCategory(
          id: -1 - index,
          name: names[index],
          sortOrder: index,
          isSystem: names[index] == "未分类",
        ),
    ];
  }

  Future<void> loadPlatforms() async {
    try {
      _platforms = await _api.getPlatformCategories();
    } catch (e) {
      LoggerService().warn("加载平台分类失败，沿用当前列表", e);
    }
    notifyListeners();
  }

  String _aliasSortKey(GameSummary game) {
    final alias = (game.alias ?? "").trim();
    if (alias.isEmpty) return game.name.toLowerCase();
    return alias.split("、").first.trim().toLowerCase();
  }

  List<Tag> get tags => _tags;
  List<PlatformCategory> get platforms => _platforms;
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
      await loadPlatforms();
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
    } catch (e) {
      LoggerService().error("后台刷新游戏库失败", e);
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

}
