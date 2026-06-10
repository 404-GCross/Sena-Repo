/// Main home screen with bottom tab navigation.
/// Steam patch tab is hidden on Android (PC-only feature).

import "dart:async";
import "dart:io" show File, Platform;

import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "package:font_awesome_flutter/font_awesome_flutter.dart";

import "../providers/theme_provider.dart";
import "../utils/theme_utils.dart";

import "../providers/game_provider.dart";
import "../utils/theme_utils.dart";
import "../services/download_service.dart";
import "../widgets/game_grid.dart";
import "../widgets/game_list.dart";
import "download_manager_screen.dart";
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
  bool _multiSelect = false;
  final _selectedIds = <int>{};
  final _searchController = TextEditingController();
  int _downloadCount = 0;
  StreamSubscription? _downloadSub;

  bool _isWide(BuildContext ctx) => !Platform.isAndroid || MediaQuery.of(ctx).size.shortestSide > 600;
  bool _isMobile(BuildContext ctx) => Platform.isAndroid && MediaQuery.of(ctx).size.shortestSide <= 600;

  @override
  void initState() {
    super.initState();
    _pollBackground();
    _downloadSub = DownloadService().tasks.listen((tasks) {
      final count = tasks.where((t) => t.status == "downloading" || t.status == "pending" || t.status == "paused" || t.status == "extracting").length;
      if (mounted && count != _downloadCount) setState(() => _downloadCount = count);
    });
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
                hintStyle: TextStyle(color: hintColor(context), fontSize: 14),
                prefixIcon: Icon(Icons.search, color: hintColor(context), size: 22),
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
                fillColor: cardBorder(context),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: cardBorder(context)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: cardBorder(context)),
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
        // ── Filter/Sort bar ──
        if (!gameProvider.isLoading)
          Container(
            margin: const EdgeInsets.fromLTRB(12, 4, 12, 6),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: cardBg(context),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: cardBorder(context)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text("${gameProvider.games.length} 款游戏",
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.primary)),
                ),
                const Spacer(),
                // Action buttons moved from sidebar
                IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  onPressed: gameProvider.loadGames,
                  tooltip: "刷新",
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  icon: Icon(_isGridView ? Icons.list : Icons.grid_view, size: 20),
                  onPressed: () => setState(() => _isGridView = !_isGridView),
                  tooltip: _isGridView ? "列表视图" : "网格视图",
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  icon: Icon(_multiSelect ? Icons.check_box : Icons.check_box_outline_blank, size: 20),
                  onPressed: _toggleMultiSelect,
                  tooltip: "多选",
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 4),
                if (gameProvider.filterPlatform != null || gameProvider.filterHasCover != null || gameProvider.sortBy != null)
                  GestureDetector(
                    onTap: () => gameProvider.clearFilters(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.close, size: 14, color: Colors.red[300]),
                        const SizedBox(width: 4),
                        Text("清除", style: TextStyle(fontSize: 11, color: Colors.red[300])),
                      ]),
                    ),
                  ),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                // Platform filters with icons
                _filterChip("PC", Icons.desktop_windows, gameProvider.filterPlatform == "PC",
                    () => _togglePlatformFilter("PC")),
                _filterChip("KRKR", Icons.android, gameProvider.filterPlatform == "KRKR",
                    () => _togglePlatformFilter("KRKR")),
                _filterChip("ONS", Icons.language, gameProvider.filterPlatform == "ONS",
                    () => _togglePlatformFilter("ONS")),
                _filterChip("Ty", Icons.phone_android, gameProvider.filterPlatform == "Ty",
                    () => _togglePlatformFilter("Ty")),
                _filterChip("直装", Icons.phone_iphone, gameProvider.filterPlatform == "直装",
                    () => _togglePlatformFilter("直装")),
                Container(width: 1, height: 18, color: cardBorder(context)),
                const SizedBox(width: 6),
                _filterChip("有封面", Icons.image, gameProvider.filterHasCover == true,
                    () => gameProvider.setFilters(hasCover: gameProvider.filterHasCover == true ? null : true)),
                _filterChip("缺封面", Icons.hide_image, gameProvider.filterHasCover == false,
                    () => gameProvider.setFilters(hasCover: gameProvider.filterHasCover == false ? null : false)),
                const Spacer(),
                // Sort: styled popup menu
                PopupMenuButton<String>(
                  offset: const Offset(0, 36),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  onSelected: (v) => gameProvider.setSort(v),
                  itemBuilder: (_) => [
                    _sortItem(null, "导入时间 ↓", Icons.schedule, gameProvider.sortBy == null),
                    _sortItem("name", "名称 A → Z", Icons.sort_by_alpha, gameProvider.sortBy == "name"),
                    _sortItem("name_desc", "名称 Z → A", Icons.text_rotation_none, gameProvider.sortBy == "name_desc"),
                    _sortItem("company", "会社 A → Z", Icons.business, gameProvider.sortBy == "company"),
                    _sortItem("developer", "开发商 A → Z", Icons.code, gameProvider.sortBy == "developer"),
                  ],
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: gameProvider.sortBy != null
                          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
                          : cardBg(context),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: gameProvider.sortBy != null
                          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.3)
                          : cardBorder(context)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.sort, size: 16, color: gameProvider.sortBy != null
                          ? Theme.of(context).colorScheme.primary
                          : (Theme.of(context).brightness == Brightness.dark ? Colors.grey[500] : Colors.grey[600])),
                      const SizedBox(width: 4),
                      Text(_sortLabel(gameProvider.sortBy),
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500,
                              color: gameProvider.sortBy != null
                                  ? Theme.of(context).colorScheme.primary
                                  : (Theme.of(context).brightness == Brightness.dark ? Colors.grey[500] : Colors.grey[700]))),
                      const SizedBox(width: 2),
                      Icon(Icons.arrow_drop_down, size: 18, color: gameProvider.sortBy != null
                          ? Theme.of(context).colorScheme.primary
                          : (Theme.of(context).brightness == Brightness.dark ? Colors.grey[500] : Colors.grey[600])),
                    ]),
                  ),
                ),
                if (gameProvider.sortBy != null) const SizedBox(width: 4),
              ]),
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
                              style: TextStyle(color: hintColor(context), fontSize: 18)),
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
                          selectedIds: _selectedIds,
                          onSelect: (id) => _toggleSelect(id),
                          multiSelect: _multiSelect,
                        )
                      : GameList(
                          games: gameProvider.games,
                          coverBaseUrl: gameProvider.api.baseUrl,
                          onTap: (game) => _openDetail(game),
                          selectedIds: _selectedIds,
                          onSelect: (id) => _toggleSelect(id),
                          multiSelect: _multiSelect,
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

  void _openDetail(game) async {
    if (_multiSelect) {
      _toggleSelect(game.id);
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => GameDetailScreen(gameId: game.id)),
    );
    if (mounted) {
      context.read<GameProvider>().loadGames();
    }
  }

  void _toggleSelect(int id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
        if (_selectedIds.isEmpty) _multiSelect = false;
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _toggleMultiSelect() {
    setState(() {
      _multiSelect = !_multiSelect;
      if (!_multiSelect) _selectedIds.clear();
    });
  }

  Future<void> _batchDelete() async {
    final confirmed = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text("批量删除"),
      content: Text("确定删除 ${_selectedIds.length} 个游戏？不会删除本地文件。"),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text("取消")),
        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text("删除", style: TextStyle(color: Colors.red))),
      ],
    ));
    if (confirmed != true || !mounted) return;
    try {
      final base = context.read<GameProvider>().api.baseUrl;
      await http.post(Uri.parse("$base/api/games/batch-delete"),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({"game_ids": _selectedIds.toList()}));
      await context.read<GameProvider>().loadGames();
      setState(() { _selectedIds.clear(); _multiSelect = false; });
    } catch (_) {}
  }

  Future<void> _batchScrape() async {
    try {
      final base = context.read<GameProvider>().api.baseUrl;
      await http.post(Uri.parse("$base/api/scrape/batch"),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({"game_ids": _selectedIds.toList()}));
      if (mounted) {
        showDialog(context: context, builder: (c) => AlertDialog(
          title: const Text("批量刮削"), content: Text("已触发 ${_selectedIds.length} 个游戏的刮削任务"),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text("确定"))],
        ));
      }
      setState(() { _selectedIds.clear(); _multiSelect = false; });
    } catch (_) {}
  }

  Widget? _buildBottomBar(BuildContext context, bool showSteam) {
    if (_multiSelect && _selectedIds.isNotEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          border: Border(top: BorderSide(color: cardBorder(context))),
        ),
        child: Row(children: [
          TextButton.icon(
            onPressed: _batchClearSelection,
            icon: const Icon(Icons.close, size: 18),
            label: Text("${_selectedIds.length} 项"),
            style: TextButton.styleFrom(foregroundColor: Colors.white70),
          ),
          const Spacer(),
          FilledButton.tonalIcon(
            onPressed: _batchScrape,
            icon: const Icon(Icons.image_search, size: 18),
            label: const Text("刮削"),
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8)),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: _batchDelete,
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text("删除"),
            style: FilledButton.styleFrom(foregroundColor: Colors.red, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8)),
          ),
        ]),
      );
    }
    if (_isWide(context)) return null;
    return NavigationBar(
      selectedIndex: _currentTab,
      onDestinationSelected: (i) => setState(() => _currentTab = i),
      destinations: [
        const NavigationDestination(icon: Icon(Icons.gamepad_outlined), selectedIcon: Icon(Icons.gamepad), label: "游戏库"),
        if (showSteam)
          const NavigationDestination(icon: Icon(FontAwesomeIcons.steam), selectedIcon: Icon(FontAwesomeIcons.steam), label: "Steam补丁"),
        const NavigationDestination(icon: Icon(Icons.person_outlined), selectedIcon: Icon(Icons.person), label: "我的"),
      ],
    );
  }

  @override
  void dispose() {
    _downloadSub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _batchClearSelection() {
    setState(() { _selectedIds.clear(); _multiSelect = false; });
  }

  String _sortLabel(String? sortBy) {
    switch (sortBy) {
      case "name": return "名称 A-Z";
      case "name_desc": return "名称 Z-A";
      case "company": return "会社 A-Z";
      case "developer": return "开发商 A-Z";
      default: return "排序";
    }
  }

  PopupMenuItem<String> _sortItem(String? value, String label, IconData icon, bool active) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(children: [
        Icon(icon, size: 18, color: active ? Theme.of(context).colorScheme.primary : Colors.grey[400]),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(
          fontSize: 13, fontWeight: active ? FontWeight.w600 : FontWeight.normal,
          color: active ? Theme.of(context).colorScheme.primary : Colors.grey[300],
        )),
        if (active) ...[
          const Spacer(),
          Icon(Icons.check, size: 16, color: Theme.of(context).colorScheme.primary),
        ],
      ]),
    );
  }

  void _togglePlatformFilter(String platform) {
    final provider = context.read<GameProvider>();
    provider.setFilters(platform: provider.filterPlatform == platform ? null : platform);
  }

  Widget _filterChip(String label, IconData? icon, bool active, VoidCallback onTap) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: active
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.18)
                : (isDark ? cardBg(context) : Colors.black.withValues(alpha: 0.04)),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: active
                  ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)
                  : (isDark ? cardBorder(context) : Colors.black.withValues(alpha: 0.08)),
            ),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: active ? Theme.of(context).colorScheme.primary : Colors.grey[600]),
              const SizedBox(width: 4),
            ],
            Text(label, style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w500,
              color: active ? Theme.of(context).colorScheme.primary : (isDark ? Colors.grey[400] : Colors.grey[600]),
            )),
          ]),
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
            // Download manager entry
            IconButton(
              icon: Badge(
                isLabelVisible: _downloadCount > 0,
                label: Text("$_downloadCount", style: const TextStyle(fontSize: 10)),
                child: const Icon(Icons.download_outlined, size: 22),
              ),
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const DownloadManagerScreen())),
              tooltip: "下载管理",
            ),
            const Spacer(),
            // Nav tabs centered
            _navTab(Icons.gamepad, Icons.gamepad_outlined, "游戏库", 0),
            if (showSteam) _navTab(FontAwesomeIcons.steam, FontAwesomeIcons.steam, "Steam", 1),
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
      floatingActionButton: _multiSelect ? null : AnimatedScale(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        scale: _currentTab == 0 ? 1.0 : 0.0,
        child: FloatingActionButton.extended(
          onPressed: _currentTab == 0 ? () => _addNewGame(context, gameProvider) : null,
          icon: const Icon(Icons.add), label: const Text("新建条目"),
        ),
      ),
      bottomNavigationBar: _buildBottomBar(context, showSteam),
      ),
    ]);
  }

}
