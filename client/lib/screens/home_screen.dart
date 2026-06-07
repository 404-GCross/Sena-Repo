/// Main home screen with bottom tab navigation.

import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../providers/game_provider.dart";
import "../widgets/game_grid.dart";
import "../widgets/game_list.dart";
import "game_detail_screen.dart";
import "steam_patch_screen.dart";

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentTab = 0;
  bool _isGridView = true;
  final _searchController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final gameProvider = context.watch<GameProvider>();

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
                  onPressed: gameProvider.loadGames,
                  tooltip: "刷新",
                ),
                IconButton(
                  icon: const Icon(Icons.settings),
                  onPressed: () => _showSettings(context),
                  tooltip: "设置",
                ),
              ]
            : null,
      ),
      body: IndexedStack(
        index: _currentTab,
        children: [
          // ── Tab 0: 游戏库 ──
          Column(
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
                                onTap: (game) {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          GameDetailScreen(gameId: game.id),
                                    ),
                                  );
                                },
                              )
                            : GameList(
                                games: gameProvider.games,
                                coverBaseUrl: gameProvider.api.baseUrl,
                                onTap: (game) {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          GameDetailScreen(gameId: game.id),
                                    ),
                                  );
                                },
                              ),
              ),
            ],
          ),

          // ── Tab 1: Steam 补丁 ──
          const SteamPatchScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentTab,
        onDestinationSelected: (i) => setState(() => _currentTab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.gamepad_outlined),
            selectedIcon: Icon(Icons.gamepad),
            label: "游戏库",
          ),
          NavigationDestination(
            icon: Icon(Icons.build_outlined),
            selectedIcon: Icon(Icons.build),
            label: "Steam 补丁",
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
