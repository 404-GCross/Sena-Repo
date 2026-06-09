/// Main home screen with bottom tab navigation.
/// Steam patch tab is hidden on Android (PC-only feature).

import "dart:io" show File, Platform;

import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../providers/theme_provider.dart";

import "../providers/game_provider.dart";
import "../widgets/game_grid.dart";
import "../widgets/game_list.dart";
import "game_detail_screen.dart";
import "steam_patch_screen.dart";
import "profile_screen.dart";
import "settings_screen.dart";
import "package:http/http.dart" as http;
import "dart:convert";
import "notification_screen.dart";
import "package:http/http.dart" as http;
import "dart:convert";

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentTab = 0;
  bool _isGridView = true;
  int _unreadCount = 0;
  int _scrapeProgress = -1; // -1 = none, 0-100 = %
  final _searchController = TextEditingController();

  bool _isWide(BuildContext ctx) => !Platform.isAndroid || MediaQuery.of(ctx).size.shortestSide > 600;
  bool _isMobile(BuildContext ctx) => Platform.isAndroid && MediaQuery.of(ctx).size.shortestSide <= 600;

  @override
  void initState() {
    super.initState();
    _pollBackground();
  }

  void _pollBackground() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 8));
      if (!mounted) return false;
      try {
        final base = context.read<GameProvider>().api.baseUrl;
        // Poll notifications
        final nResp = await http.get(Uri.parse("$base/api/auth/notifications/unread-count"));
        if (mounted && nResp.statusCode == 200) {
          setState(() => _unreadCount = (jsonDecode(nResp.body) as Map)["count"] ?? 0);
        }
        // Poll scrape jobs
        final jResp = await http.get(Uri.parse("$base/api/scrape/jobs"));
        if (mounted && jResp.statusCode == 200) {
          final jobs = jsonDecode(jResp.body) as List;
          final running = jobs.cast<Map>().where((j) => j["status"] == "running").toList();
          if (running.isNotEmpty) {
            final j = running.first;
            final total = (j["total_games"] as int?) ?? 1;
            final done = (j["completed_games"] as int?) ?? 0;
            setState(() => _scrapeProgress = total > 0 ? (done * 100 ~/ total).clamp(0, 100) : 0);
          } else {
            setState(() => _scrapeProgress = -1);
          }
        }
      } catch (_) {}
      return mounted;
    });
  }

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

  Future<void> _addNewGame(BuildContext ctx, GameProvider provider) async {
    final nameCtrl = TextEditingController();
    final folderCtrl = TextEditingController();
    final result = await showDialog<bool>(
      context: ctx, builder: (c) => AlertDialog(
        title: const Text("新建条目"),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: "游戏名"), autofocus: true),
          const SizedBox(height: 8),
          TextField(controller: folderCtrl, decoration: const InputDecoration(labelText: "路径（可选）")),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text("取消")),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text("创建")),
        ],
      ),
    );
    if (result == true) {
      try {
        await http.put(Uri.parse("${provider.api.baseUrl}/api/games/quick-create"),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({"name": nameCtrl.text.trim()}),
        );
        await provider.loadGames();
        if (ctx.mounted) showDialog(context: ctx, builder: (d) => AlertDialog(content: const Text("已创建"), actions: [FilledButton(onPressed: () => Navigator.pop(d), child: const Text("确定"))]));
      } catch (_) {}
    }
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
    final theme = context.watch<ThemeProvider>();
    final wide = _isWide(context);
    final showSteam = !Platform.isAndroid || wide;

    // Build page list and nav destinations dynamically
    final pages = <Widget>[
      _buildGameLibrary(gameProvider),
      if (showSteam) const SteamPatchScreen(),
      const ProfileScreen(),
    ];

    return Stack(
      children: [
        // Background image
        if (theme.backgroundUrl != null && theme.backgroundUrl!.isNotEmpty)
          Positioned.fill(
            child: theme.backgroundUrl!.startsWith("file://")
                ? Image.file(File(theme.backgroundUrl!.replaceFirst("file://", "")),
                    fit: BoxFit.cover, opacity: const AlwaysStoppedAnimation(0.15))
                : Image.network(theme.backgroundUrl!,
                    fit: BoxFit.cover, opacity: const AlwaysStoppedAnimation(0.15),
                    errorBuilder: (_, __, ___) => const SizedBox.shrink()),
          )
        else if (theme.bgColor != null)
          Positioned.fill(child: ColoredBox(color: theme.bgColor!)),
        Scaffold(
      appBar: AppBar(
        title: const Text("Sena Repo"),
        bottom: _scrapeProgress >= 0
            ? PreferredSize(
                preferredSize: const Size.fromHeight(4),
                child: LinearProgressIndicator(value: _scrapeProgress / 100.0, backgroundColor: Colors.white10),
              )
            : null,
        actions: [
          if (_scrapeProgress >= 0)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(
                child: Text("刮削中 $_scrapeProgress%", style: TextStyle(fontSize: 11, color: Colors.orange[300])),
              ),
            ),
          if (_currentTab == 0) ...[
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
          ],
          IconButton(
            icon: Badge(
              isLabelVisible: _unreadCount > 0,
              label: Text("$_unreadCount"),
              child: const Icon(Icons.notifications_outlined),
            ),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => NotificationScreen(api: gameProvider.api)),
              );
              // Refresh unread count
              try {
                final resp = await http.get(
                  Uri.parse("${gameProvider.api.baseUrl}/api/auth/notifications/unread-count"),
                );
                if (resp.statusCode == 200 && mounted) {
                  final data = jsonDecode(resp.body) as Map<String, dynamic>;
                  setState(() => _unreadCount = data["count"] ?? 0);
                }
              } catch (_) {}
            },
            tooltip: "通知",
          ),
          if (_currentTab == 0)
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen())),
              tooltip: "设置",
            ),
        ],
      ),
      body: !_isWide(context)
          ? Column(children: [
              Expanded(child: IndexedStack(index: _currentTab, children: pages)),
            ])
          : Row(children: [
              NavigationRail(
                selectedIndex: _currentTab,
                onDestinationSelected: (i) => setState(() => _currentTab = i),
                labelType: NavigationRailLabelType.all,
                destinations: [
                  const NavigationRailDestination(
                    icon: Icon(Icons.gamepad_outlined),
                    selectedIcon: Icon(Icons.gamepad),
                    label: Text("游戏库"),
                  ),
                  if (showSteam)
                    const NavigationRailDestination(
                      icon: Icon(Icons.build_outlined),
                      selectedIcon: Icon(Icons.build),
                      label: Text("Steam补丁"),
                    ),
                  const NavigationRailDestination(
                    icon: Icon(Icons.person_outlined),
                    selectedIcon: Icon(Icons.person),
                    label: Text("我的"),
                  ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: IndexedStack(index: _currentTab, children: pages)),
            ]),
      floatingActionButton: _currentTab == 0
          ? FloatingActionButton.extended(
              onPressed: () => _addNewGame(context, gameProvider),
              icon: const Icon(Icons.add), label: const Text("新建条目"),
            )
          : null,
      bottomNavigationBar: !_isWide(context)
          ? NavigationBar(
              selectedIndex: _currentTab,
              onDestinationSelected: (i) => setState(() => _currentTab = i),
              destinations: [
                const NavigationDestination(
                  icon: Icon(Icons.gamepad_outlined), selectedIcon: Icon(Icons.gamepad), label: "游戏库"),
                if (showSteam)
                  const NavigationDestination(
                    icon: Icon(Icons.build_outlined), selectedIcon: Icon(Icons.build), label: "Steam补丁"),
                const NavigationDestination(
                  icon: Icon(Icons.person_outlined), selectedIcon: Icon(Icons.person), label: "我的"),
              ],
            )
          : null,
      ),
    ]);
  }

}
