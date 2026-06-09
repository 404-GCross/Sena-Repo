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
        // ── Search bar ──
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: SizedBox(
            height: 44,
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: "搜索游戏...",
                hintStyle: TextStyle(color: Colors.grey[500], fontSize: 14),
                prefixIcon: Icon(Icons.search, color: Colors.grey[500], size: 22),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 20),
                        onPressed: () {
                          _searchController.clear();
                          gameProvider.search("");
                        },
                      )
                    : null,
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.06),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5)),
                ),
              ),
              style: const TextStyle(fontSize: 14),
              onChanged: (v) => gameProvider.search(v),
            ),
          ),
        ),
        // ── Game count ──
        if (!gameProvider.isLoading)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
            child: Row(children: [
              Text("共 ${gameProvider.games.length} 款游戏",
                  style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              const Spacer(),
              if (_searchController.text.isNotEmpty)
                Text("筛选自 ${gameProvider.games.length} 条",
                    style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            ]),
          ),
        Expanded(
          child: gameProvider.isLoading
              ? const Center(child: CircularProgressIndicator())
              : gameProvider.games.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.gamepad, size: 72, color: Colors.grey[700]),
                          const SizedBox(height: 16),
                          Text("游戏库为空",
                              style: TextStyle(color: Colors.grey[500], fontSize: 18)),
                          const SizedBox(height: 4),
                          Text("请在服务端添加根目录并刷新",
                              style: TextStyle(color: Colors.grey[600], fontSize: 13)),
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

  Widget _sideBtn(IconData icon, String tooltip, VoidCallback onTap) {
    return IconButton(icon: Icon(icon, size: 22), onPressed: onTap, tooltip: tooltip);
  }

  Widget _navTab(IconData icon, IconData outlined, String label, int index) {
    final selected = _currentTab == index;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: () => setState(() => _currentTab = index),
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 56, height: 48,
          decoration: BoxDecoration(
            color: selected ? Theme.of(context).colorScheme.primaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(selected ? icon : outlined, size: 22,
                color: selected ? Theme.of(context).colorScheme.primary : null),
            Text(label, style: TextStyle(fontSize: 9, color: selected ? Theme.of(context).colorScheme.primary : null)),
          ]),
        ),
      ),
    );
  }

  void _openDetail(game) {
    Navigator.push(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 250),
        pageBuilder: (_, animation, __) => GameDetailScreen(gameId: game.id),
        transitionsBuilder: (_, animation, __, child) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.03, 0),
              end: Offset.zero,
            ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
            child: child,
          ),
        ),
      ),
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
            child: Opacity(
              opacity: 0.2,
              child: theme.backgroundUrl!.startsWith("file://")
                  ? Image.file(File(theme.backgroundUrl!.replaceFirst("file://", "")),
                      fit: BoxFit.cover)
                  : Image.network(theme.backgroundUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink()),
            ),
          )
        else if (theme.bgColor != null)
          Positioned.fill(child: ColoredBox(color: theme.bgColor!)),
        Scaffold(
      body: Row(children: [
        // ── Left Sidebar ──
        SizedBox(
          width: 72,
          child: Column(children: [
            const SizedBox(height: 12),
            // Notification (always first, doesn't shift)
            IconButton(
              icon: Badge(
                isLabelVisible: _unreadCount > 0,
                label: Text("$_unreadCount", style: const TextStyle(fontSize: 10)),
                child: const Icon(Icons.notifications_outlined, size: 22),
              ),
              onPressed: () async {
                await Navigator.push(context,
                    MaterialPageRoute(builder: (_) => NotificationScreen(api: gameProvider.api)));
                try {
                  final r = await http.get(Uri.parse("${gameProvider.api.baseUrl}/api/auth/notifications/unread-count"));
                  if (r.statusCode == 200 && mounted) {
                    setState(() => _unreadCount = (jsonDecode(r.body) as Map)["count"] ?? 0);
                  }
                } catch (_) {}
              },
              tooltip: "通知",
            ),
            // Action buttons (only on game library tab)
            AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _currentTab == 0 ? 1.0 : 0.0,
              child: IgnorePointer(
                ignoring: _currentTab != 0,
                child: Column(children: [
                  _sideBtn(Icons.refresh, "刷新", gameProvider.loadGames),
                  _sideBtn(_isGridView ? Icons.list : Icons.grid_view,
                      _isGridView ? "列表" : "网格",
                      () => setState(() => _isGridView = !_isGridView)),
                ]),
              ),
            ),
            const Spacer(),
            // Nav tabs centered
            _navTab(Icons.gamepad, Icons.gamepad_outlined, "游戏库", 0),
            if (showSteam) _navTab(Icons.build, Icons.build_outlined, "Steam", 1),
            _navTab(Icons.person, Icons.person_outlined, "我的", showSteam ? 2 : 1),
            const Spacer(),
          ]),
        ),
        const VerticalDivider(width: 1),
        // ── Content ──
        Expanded(
          child: Column(children: [
            if (_scrapeProgress >= 0)
              SizedBox(
                height: 4,
                child: LinearProgressIndicator(value: _scrapeProgress / 100.0, backgroundColor: Colors.white10),
              ),
            Expanded(child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, animation) => SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0.04, 0),
                  end: Offset.zero,
                ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
                child: FadeTransition(opacity: animation, child: child),
              ),
              child: KeyedSubtree(key: ValueKey(_currentTab), child: pages[_currentTab]),
            )),
          ]),
        ),
      ]),
      floatingActionButton: AnimatedScale(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        scale: _currentTab == 0 ? 1.0 : 0.0,
        child: FloatingActionButton.extended(
          onPressed: _currentTab == 0 ? () => _addNewGame(context, gameProvider) : null,
          icon: const Icon(Icons.add), label: const Text("新建条目"),
        ),
      ),
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
