/// Main home screen with bottom tab navigation.
/// Steam patch tab is hidden on Android (PC-only feature).

import "dart:io" show Platform;

import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../providers/game_provider.dart";
import "../widgets/game_grid.dart";
import "../widgets/game_list.dart";
import "game_detail_screen.dart";
import "steam_patch_screen.dart";
import "profile_screen.dart";

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentTab = 0;
  bool _isGridView = true;
  final _searchController = TextEditingController();

  bool get _showSteamTab => !Platform.isAndroid;

  Widget _buildGameLibrary(GameProvider gameProvider) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: "搜索游戏...",
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        gameProvider.search("");
                      },
                    )
                  : null,
            ),
            onChanged: (v) => gameProvider.search(v),
          ),
        ),
        Expanded(
          child: gameProvider.isLoading
              ? const Center(child: CircularProgressIndicator())
              : gameProvider.games.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.gamepad, size: 64, color: Colors.grey),
                          SizedBox(height: 16),
                          Text("游戏库为空",
                              style: TextStyle(color: Colors.grey, fontSize: 18)),
                          Text("请在服务端添加根目录并刷新",
                              style: TextStyle(color: Colors.grey)),
                        ],
                      ),
                    )
                  : _isGridView
                      ? GameGrid(
                          games: gameProvider.games,
                          coverBaseUrl: gameProvider.api.baseUrl,
                          onTap: (game) => _openDetail(game),
                        )
                      : GameList(
                          games: gameProvider.games,
                          coverBaseUrl: gameProvider.api.baseUrl,
                          onTap: (game) => _openDetail(game),
                        ),
        ),
      ],
    );
  }

  void _openDetail(game) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => GameDetailScreen(gameId: game.id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final gameProvider = context.watch<GameProvider>();

    // Build page list and nav destinations dynamically
    final pages = <Widget>[
      _buildGameLibrary(gameProvider),
      if (_showSteamTab) const SteamPatchScreen(),
      const ProfileScreen(),
    ];
    final profileIdx = _showSteamTab ? 2 : 1;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Sena Repo"),
        actions: _currentTab == 0
            ? [
                IconButton(
                  icon: Icon(_isGridView ? Icons.list : Icons.grid_view),
                  onPressed: () => setState(() => _isGridView = !_isGridView),
                  tooltip: _isGridView ? "列表视图" : "网格视图",
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () async {
                    final api = gameProvider.api;
                    try {
                      await api.refreshAllRoots();
                      await gameProvider.loadGames();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("扫描完成")),
                        );
                      }
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text("扫描失败: $e")),
                        );
                      }
                    }
                  },
                  tooltip: "扫描刷新",
                ),
                IconButton(
                  icon: const Icon(Icons.settings),
                  onPressed: () => _showSettings(context),
                  tooltip: "设置",
                ),
              ]
            : null,
      ),
      body: IndexedStack(index: _currentTab, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentTab,
        onDestinationSelected: (i) => setState(() => _currentTab = i),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.gamepad_outlined),
            selectedIcon: Icon(Icons.gamepad),
            label: "游戏库",
          ),
          if (_showSteamTab)
            const NavigationDestination(
              icon: Icon(Icons.build_outlined),
              selectedIcon: Icon(Icons.build),
              label: "Steam补丁库",
            ),
          NavigationDestination(
            icon: const Icon(Icons.person_outlined),
            selectedIcon: const Icon(Icons.person),
            label: "我的",
          ),
        ],
      ),
    );
  }

  void _showSettings(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("设置"),
        content: const Text("设置页面（待实现）"),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text("关闭")),
        ],
      ),
    );
  }
}
