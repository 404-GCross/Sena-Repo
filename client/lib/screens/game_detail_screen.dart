/// Game detail screen — Playnite-style layout with cover on right, metadata grid on left.

import "dart:async";
import "dart:convert";
import "dart:io" show Platform;

import "package:flutter/material.dart";
import "package:provider/provider.dart";
import "package:file_picker/file_picker.dart";
import "package:http/http.dart" as http;
import "package:shared_preferences/shared_preferences.dart";

import "../models/game.dart";
import "../services/api_client.dart";
import "../services/download_service.dart";
import "../services/file_open_service.dart";
import "../services/manager_install_service.dart";
import "../services/shortcut_service.dart";
import "../services/steam_integration_service.dart";
import "../providers/game_provider.dart";
import "../utils/theme_utils.dart";
import "../widgets/app_shell.dart";
import "../widgets/nsfw_image.dart";
import "game_edit_screen.dart";

void _showDialog(BuildContext ctx, String title, String msg) {
  showDialog(
    context: ctx,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(msg),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(c),
          child: const Text("确定"),
        ),
      ],
    ),
  );
}

class GameDetailScreen extends StatefulWidget {
  final int gameId;
  const GameDetailScreen({super.key, required this.gameId});

  @override
  State<GameDetailScreen> createState() => _GameDetailScreenState();
}

class _GameDetailScreenState extends State<GameDetailScreen>
    with WidgetsBindingObserver {
  GameDetail? _game;
  int _refreshKey = 0;
  bool _isLoading = true;

  // Pending download info — retried after storage permission granted
  GameDetail? _pendingGame;
  dynamic _pendingVersion;

  ApiClient get _api => context.read<GameProvider>().api;
  String get _baseUrl => _api.baseUrl;

  Future<bool> _refreshIsAdmin() async {
    final prefs = await SharedPreferences.getInstance();
    var isAdmin = prefs.getBool("is_admin") ?? false;
    try {
      final resp = await http
          .get(
            Uri.parse("$_baseUrl/api/auth/profile/me"),
            headers: _api.headers,
          )
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        isAdmin = data["is_admin"] == true;
        await ApiClient.persistSessionInfo(
          username: data["username"]?.toString(),
          isAdmin: isAdmin,
        );
      }
    } catch (_) {}
    return isAdmin;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _pendingGame != null &&
        _pendingVersion != null) {
      _retryPendingDownload();
    }
  }

  Future<void> _retryPendingDownload() async {
    final game = _pendingGame;
    final v = _pendingVersion;
    _pendingGame = null;
    _pendingVersion = null;
    if (game == null || v == null || !mounted) return;
    final granted = await DownloadService().checkStoragePermissionGranted();
    if (granted) {
      _startDownload(game, v);
    }
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final game = await _api.getGame(widget.gameId);
      if (mounted)
        setState(() {
          _game = game;
          _isLoading = false;
          _refreshKey++;
        });
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading)
      return const AppScaffold(
        title: "加载中",
        subtitle: "正在读取游戏详情",
        leading: Icon(Icons.videogame_asset_outlined, size: 24),
        child: AppStateView.loading(title: "正在加载游戏详情"),
      );
    final game = _game;
    if (game == null)
      return const AppScaffold(
        title: "错误",
        subtitle: "无法打开游戏详情",
        leading: Icon(Icons.error_outline, size: 24),
        child: AppStateView(
          icon: Icons.search_off_outlined,
          title: "游戏未找到",
          message: "该条目可能已被删除或服务器暂时无法返回详情",
        ),
      );

    final hasCover = game.coverPath != null && game.coverPath!.isNotEmpty;
    final cs = Theme.of(context).colorScheme;

    return AppScaffold(
      title: game.name,
      subtitle: "游戏详情、资源和下载操作",
      leading: const Icon(Icons.videogame_asset_outlined, size: 24),
      scrollable: false,
      padding: EdgeInsets.zero,
      maxWidth: 1480,
      actions: [
        AppActionButton(
          icon: Icons.edit_outlined,
          label: "编辑",
          onPressed: () async {
            final isAdmin = await _refreshIsAdmin();
            if (!isAdmin) {
              if (mounted) _showDialog(context, "权限不足", "仅限管理员可操作");
              return;
            }
            final changed = await Navigator.push<bool>(
              context,
              MaterialPageRoute(builder: (_) => GameEditScreen(game: game)),
            );
            if (changed == true) _load();
          },
        ),
      ],
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1420),
            child: LayoutBuilder(
              builder: (ctx, constraints) {
                final w = constraints.maxWidth;
                final useDesktopLayout = !Platform.isAndroid ||
                    MediaQuery.sizeOf(context).shortestSide > 600;
                if (useDesktopLayout && w >= 720) {
                  return _buildDesktopDetail(game);
                }
                final wide = w > 500;
                final coverW = wide ? (w > 700 ? 200.0 : 150.0) : 130.0;
                final coverH = coverW * 1.4;
                return Column(
                  children: [
                    // ── Hero banner (landscape, 16:9) ──
                    if (game.bgPath != null && game.bgPath!.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          wide ? 16 : 0,
                          wide ? 12 : 0,
                          wide ? 16 : 0,
                          0,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(wide ? 14 : 0),
                          child: AspectRatio(
                            aspectRatio: 16 / 9,
                            child: NsfwImage(
                              isNsfw: game.isNsfw,
                              child: Image.network(
                                "$_baseUrl/api/files/backgrounds/${game.bgPath!.split("/").last}?t=$_refreshKey",
                                headers: mediaAuthHeaders,
                                width: double.infinity,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) =>
                                    const SizedBox.shrink(),
                              ),
                            ),
                          ),
                        ),
                      ),
                    // ── Header ──
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        wide ? 32 : 8,
                        wide ? 20 : 10,
                        wide ? 32 : 8,
                        0,
                      ),
                      child: wide
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        game.name,
                                        style: TextStyle(
                                          fontSize: 28,
                                          fontWeight: FontWeight.bold,
                                          height: 1.2,
                                        ),
                                      ),
                                      if (game.companyName != null) ...[
                                        const SizedBox(height: 6),
                                        Row(
                                          children: [
                                            Icon(
                                              Icons.business,
                                              size: 16,
                                              color: subTextColor(context),
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              game.companyName!,
                                              style: TextStyle(
                                                fontSize: 16,
                                                color: subTextColor(context),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                      if (game.vndbId != null ||
                                          game.steamId != null ||
                                          game.bangumiId != null) ...[
                                        const SizedBox(height: 10),
                                        Row(
                                          children: [
                                            _sourceBadge("VNDB", game.vndbId),
                                            _sourceBadge("Steam", game.steamId),
                                            _sourceBadge(
                                              "Bangumi",
                                              game.bangumiId,
                                            ),
                                          ],
                                        ),
                                      ],
                                      if (game.tags.isNotEmpty) ...[
                                        const SizedBox(height: 10),
                                        _tagChips(game.tags, compact: true),
                                      ],
                                      const SizedBox(height: 16),
                                      if (game.versions.isNotEmpty)
                                        FilledButton.icon(
                                          onPressed: () =>
                                              _showDownloadDialog(game),
                                          icon: const Icon(
                                            Icons.download,
                                            size: 18,
                                          ),
                                          label: const Text("下载游戏"),
                                          style: FilledButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 20,
                                              vertical: 12,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 24),
                                Container(
                                  width: coverW,
                                  height: coverH,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(14),
                                    boxShadow: [
                                      BoxShadow(
                                        color: cs.primary.withValues(
                                          alpha: 0.3,
                                        ),
                                        blurRadius: 24,
                                        offset: const Offset(0, 12),
                                      ),
                                      BoxShadow(
                                        color: Colors.black.withValues(
                                          alpha: 0.2,
                                        ),
                                        blurRadius: 8,
                                        offset: const Offset(0, 4),
                                      ),
                                    ],
                                    border: Border.all(
                                      color: cs.outlineVariant.withValues(
                                        alpha: 0.5,
                                      ),
                                    ),
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(14),
                                    child: hasCover
                                        ? NsfwImage(
                                            isNsfw: game.isNsfw,
                                            child: Image.network(
                                              "$_baseUrl/api/files/covers${game.coverPath!}?t=$_refreshKey",
                                              headers: mediaAuthHeaders,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, __, ___) =>
                                                  _coverPlaceholder(),
                                            ),
                                          )
                                        : _coverPlaceholder(),
                                  ),
                                ),
                              ],
                            )
                          // Narrow: cover top, name centered below
                          : Column(
                              children: [
                                if (hasCover)
                                  Center(
                                    child: Container(
                                      width: coverW,
                                      height: coverH,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(14),
                                        boxShadow: [
                                          BoxShadow(
                                            color: cs.primary.withValues(
                                              alpha: 0.2,
                                            ),
                                            blurRadius: 20,
                                            offset: const Offset(0, 8),
                                          ),
                                        ],
                                        border: Border.all(
                                          color: cs.outlineVariant.withValues(
                                            alpha: 0.4,
                                          ),
                                        ),
                                      ),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(14),
                                        child: NsfwImage(
                                          isNsfw: game.isNsfw,
                                          child: Image.network(
                                            "$_baseUrl/api/files/covers${game.coverPath!}?t=$_refreshKey",
                                            headers: mediaAuthHeaders,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, __, ___) =>
                                                _coverPlaceholder(),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                const SizedBox(height: 10),
                                Text(
                                  game.name,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    height: 1.2,
                                  ),
                                ),
                                if (game.companyName != null) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    game.companyName!,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: subTextColor(context),
                                    ),
                                  ),
                                ],
                                if (game.vndbId != null ||
                                    game.steamId != null ||
                                    game.bangumiId != null) ...[
                                  const SizedBox(height: 8),
                                  Wrap(
                                    alignment: WrapAlignment.center,
                                    spacing: 6,
                                    children: [
                                      _sourceBadge("VNDB", game.vndbId),
                                      _sourceBadge("Steam", game.steamId),
                                      _sourceBadge("Bangumi", game.bangumiId),
                                    ],
                                  ),
                                ],
                                if (game.tags.isNotEmpty) ...[
                                  const SizedBox(height: 10),
                                  _tagChips(
                                    game.tags,
                                    centered: true,
                                    compact: true,
                                  ),
                                ],
                                if (game.versions.isNotEmpty) ...[
                                  const SizedBox(height: 12),
                                  Center(
                                    child: FilledButton.icon(
                                      onPressed: () =>
                                          _showDownloadDialog(game),
                                      icon: const Icon(
                                        Icons.download,
                                        size: 18,
                                      ),
                                      label: const Text("下载游戏"),
                                      style: FilledButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 20,
                                          vertical: 10,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                    ),

                    // ── Body: responsive ──
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        wide ? 32 : 8,
                        24,
                        wide ? 32 : 8,
                        0,
                      ),
                      child: wide
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Left: description + tags
                                Expanded(
                                  flex: 5,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      _section(
                                        "简介",
                                        Icons.description_outlined,
                                      ),
                                      Container(
                                        padding: const EdgeInsets.all(18),
                                        decoration: BoxDecoration(
                                          color: cardBg(context),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          border: Border.all(
                                            color: cardBorder(context),
                                          ),
                                        ),
                                        child: Text(
                                          game.description?.isNotEmpty == true
                                              ? game.description!
                                              : "暂无简介",
                                          style: AppText.body.copyWith(
                                            height: 1.7,
                                            color:
                                                game.description?.isNotEmpty ==
                                                        true
                                                    ? null
                                                    : Colors.grey[500],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 28),
                                // Right: info + versions
                                Expanded(
                                  flex: 4,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      _section("详细信息", Icons.info_outline),
                                      _fieldCard(
                                        children: [
                                          _infoRow(
                                            "开发商",
                                            game.developer,
                                            Icons.business,
                                          ),
                                          _divider(),
                                          _infoRow(
                                            "发售日",
                                            game.releaseDate,
                                            Icons.calendar_today,
                                          ),
                                          _divider(),
                                          _infoRow(
                                            "平均游戏时长",
                                            _formatPlaytime(game),
                                            Icons.timer,
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 20),
                                      _section("版本", Icons.folder_outlined),
                                      if (game.versions.isEmpty)
                                        _hintCard("暂无版本信息")
                                      else
                                        _fieldCard(
                                          children: game.versions
                                              .asMap()
                                              .entries
                                              .map((
                                            e,
                                          ) {
                                            final v = e.value;
                                            final isLast = e.key ==
                                                game.versions.length - 1;
                                            return Column(
                                              children: [
                                                Padding(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    vertical: 10,
                                                  ),
                                                  child: Row(
                                                    children: [
                                                      Icon(
                                                        Icons
                                                            .insert_drive_file_outlined,
                                                        size: 18,
                                                        color: hintColor(
                                                          context,
                                                        ),
                                                      ),
                                                      const SizedBox(width: 10),
                                                      Expanded(
                                                        child: Column(
                                                          crossAxisAlignment:
                                                              CrossAxisAlignment
                                                                  .start,
                                                          children: [
                                                            Text(
                                                              v.filename,
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style:
                                                                  const TextStyle(
                                                                fontSize: 14,
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                              height: 2,
                                                            ),
                                                            Text(
                                                              _versionSourceDetail(
                                                                v,
                                                              ),
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: AppText
                                                                  .caption
                                                                  .copyWith(
                                                                color:
                                                                    hintColor(
                                                                  context,
                                                                ),
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                      const SizedBox(width: 12),
                                                      Container(
                                                        padding:
                                                            const EdgeInsets
                                                                .symmetric(
                                                          horizontal: 10,
                                                          vertical: 4,
                                                        ),
                                                        decoration:
                                                            BoxDecoration(
                                                          borderRadius:
                                                              BorderRadius
                                                                  .circular(
                                                            12,
                                                          ),
                                                          color: _platformColor(
                                                            v.platform,
                                                          ).withValues(
                                                            alpha: 0.15,
                                                          ),
                                                        ),
                                                        child: Text(
                                                          v.platform,
                                                          style: AppText.label
                                                              .copyWith(
                                                            fontWeight:
                                                                FontWeight.w500,
                                                            color:
                                                                _platformColor(
                                                              v.platform,
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                      const SizedBox(width: 10),
                                                      Text(
                                                        _formatSize(v.fileSize),
                                                        style: AppText.label
                                                            .copyWith(
                                                          color: hintColor(
                                                            context,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                if (!isLast) _divider(),
                                              ],
                                            );
                                          }).toList(),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            )
                          // Narrow: single column
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _section("简介", Icons.description_outlined),
                                Container(
                                  padding: const EdgeInsets.all(18),
                                  decoration: BoxDecoration(
                                    color: cardBg(context),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: cardBorder(context),
                                    ),
                                  ),
                                  child: Text(
                                    game.description?.isNotEmpty == true
                                        ? game.description!
                                        : "暂无简介",
                                    style: AppText.body.copyWith(
                                      height: 1.7,
                                      color:
                                          game.description?.isNotEmpty == true
                                              ? null
                                              : Colors.grey[500],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 20),
                                _section("详细信息", Icons.info_outline),
                                _fieldCard(
                                  children: [
                                    _infoRow(
                                      "开发商",
                                      game.developer,
                                      Icons.business,
                                    ),
                                    _divider(),
                                    _infoRow(
                                      "发售日",
                                      game.releaseDate,
                                      Icons.calendar_today,
                                    ),
                                    _divider(),
                                    _infoRow(
                                      "平均游戏时长",
                                      _formatPlaytime(game),
                                      Icons.timer,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 20),
                                _section("版本", Icons.folder_outlined),
                                if (game.versions.isEmpty)
                                  _hintCard("暂无版本信息")
                                else
                                  _fieldCard(
                                    children:
                                        game.versions.asMap().entries.map((
                                      e,
                                    ) {
                                      final v = e.value;
                                      final isLast =
                                          e.key == game.versions.length - 1;
                                      return Column(
                                        children: [
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 10,
                                            ),
                                            child: Row(
                                              children: [
                                                Icon(
                                                  Icons
                                                      .insert_drive_file_outlined,
                                                  size: 18,
                                                  color: hintColor(context),
                                                ),
                                                const SizedBox(width: 10),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Text(
                                                        v.filename,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: const TextStyle(
                                                          fontSize: 14,
                                                        ),
                                                      ),
                                                      const SizedBox(height: 2),
                                                      Text(
                                                        _versionSourceDetail(v),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: AppText.caption
                                                            .copyWith(
                                                          color: hintColor(
                                                              context),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                const SizedBox(width: 12),
                                                Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    horizontal: 10,
                                                    vertical: 4,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                      12,
                                                    ),
                                                    color: _platformColor(
                                                      v.platform,
                                                    ).withValues(alpha: 0.15),
                                                  ),
                                                  child: Text(
                                                    v.platform,
                                                    style:
                                                        AppText.label.copyWith(
                                                      fontWeight:
                                                          FontWeight.w500,
                                                      color: _platformColor(
                                                        v.platform,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 10),
                                                Text(
                                                  _formatSize(v.fileSize),
                                                  style: AppText.label.copyWith(
                                                    color: hintColor(context),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          if (!isLast) _divider(),
                                        ],
                                      );
                                    }).toList(),
                                  ),
                              ],
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopDetail(GameDetail game) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 1000;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: compact ? 60 : 64,
                    child: _desktopHero(game),
                  ),
                  SizedBox(width: compact ? 18 : 28),
                  Expanded(
                    flex: compact ? 40 : 36,
                    child: _desktopIdentity(game, compact: compact),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 30),
          Divider(height: 1, color: cardBorder(context)),
          const SizedBox(height: 28),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 1000;
              final sideWidth = compact ? 260.0 : 340.0;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _desktopMainColumn(game, compact: compact)),
                  SizedBox(width: compact ? 18 : 28),
                  Container(
                    width: 1,
                    constraints: const BoxConstraints(minHeight: 420),
                    color: cardBorder(context),
                  ),
                  SizedBox(width: compact ? 18 : 28),
                  SizedBox(
                    width: sideWidth,
                    child: _desktopSideColumn(game),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _desktopHero(GameDetail game) {
    final hasBackground = game.bgPath?.isNotEmpty == true;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: cardBg(context),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: cardBorder(context)),
          boxShadow: [
            BoxShadow(
              color: softShadowColor(context),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: hasBackground
            ? NsfwImage(
                isNsfw: game.isNsfw,
                child: Image.network(
                  "$_baseUrl/api/files/backgrounds/${game.bgPath!.split("/").last}?t=$_refreshKey",
                  headers: mediaAuthHeaders,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  errorBuilder: (_, __, ___) => _desktopMediaPlaceholder(),
                ),
              )
            : _desktopMediaPlaceholder(),
      ),
    );
  }

  Widget _desktopMediaPlaceholder() {
    return ColoredBox(
      color: cardBg(context),
      child: Center(
        child: Icon(
          Icons.panorama_outlined,
          size: 54,
          color: hintColor(context),
        ),
      ),
    );
  }

  Widget _desktopIdentity(GameDetail game, {required bool compact}) {
    final hasCover = game.coverPath?.isNotEmpty == true;
    final completeness = _metadataCompleteness(game);
    final hasSourceIds =
        game.vndbId != null || game.steamId != null || game.bangumiId != null;
    final studio = game.companyName?.isNotEmpty == true
        ? game.companyName!
        : game.developer?.isNotEmpty == true
            ? game.developer!
            : null;
    final coverWidth = compact ? 88.0 : 132.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: coverWidth,
              height: coverWidth * 1.42,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: cardBg(context),
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: cardBorder(context)),
                boxShadow: [
                  BoxShadow(
                    color: softShadowColor(context),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: hasCover
                  ? NsfwImage(
                      isNsfw: game.isNsfw,
                      child: Image.network(
                        "$_baseUrl/api/files/covers${game.coverPath!}?t=$_refreshKey",
                        headers: mediaAuthHeaders,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _coverPlaceholder(),
                      ),
                    )
                  : _coverPlaceholder(),
            ),
            SizedBox(width: compact ? 12 : 18),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      game.name,
                      style: TextStyle(
                        fontSize: compact ? 22 : 28,
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                      ),
                    ),
                    if (studio != null) ...[
                      const SizedBox(height: 9),
                      Row(
                        children: [
                          Icon(
                            Icons.business_outlined,
                            size: 17,
                            color: subTextColor(context),
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              studio,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.bodyMedium.copyWith(
                                color: subTextColor(context),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
        if (hasSourceIds) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 7,
            runSpacing: 7,
            children: [
              _desktopSourceBadge("VNDB", game.vndbId),
              _desktopSourceBadge("Steam", game.steamId),
              _desktopSourceBadge("Bangumi", game.bangumiId),
              if (game.isNsfw) _desktopStatusBadge("NSFW", Colors.red),
              _desktopStatusBadge("资料 $completeness%", Colors.green),
            ],
          ),
        ],
        if (game.tags.isNotEmpty) ...[
          SizedBox(height: hasSourceIds ? 12 : 16),
          _tagChips(game.tags, compact: compact),
        ],
        const SizedBox(height: 18),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: cardBorder(context)),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Row(
            children: [
              Expanded(
                child: _desktopFact(
                  "发售日期",
                  game.releaseDate?.isNotEmpty == true
                      ? game.releaseDate!
                      : "—",
                ),
              ),
              SizedBox(
                height: 54,
                child: VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: cardBorder(context),
                ),
              ),
              Expanded(
                child: _desktopFact("平均时长", _formatPlaytime(game)),
              ),
              SizedBox(
                height: 54,
                child: VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: cardBorder(context),
                ),
              ),
              Expanded(
                  child: _desktopFact("可用版本", "${game.versions.length} 个")),
            ],
          ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          height: 44,
          child: FilledButton.icon(
            onPressed:
                game.versions.isEmpty ? null : () => _showDownloadDialog(game),
            icon: const Icon(Icons.download_outlined, size: 19),
            label: const Text("下载游戏"),
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
            ),
          ),
        ),
        if (ManagerInstallService.isSupportedDesktop) ...[
          const SizedBox(height: 10),
          SizedBox(
            height: 42,
            child: OutlinedButton.icon(
              onPressed: game.versions.isEmpty
                  ? null
                  : () => _showManagerInstallDialog(game),
              icon: const Icon(Icons.send_outlined, size: 18),
              label: const Text("推送到管理器下载"),
              style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _desktopFact(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(color: hintColor(context)),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.bodySmall.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Widget _desktopSourceBadge(String label, String? id) {
    final active = id?.isNotEmpty == true;
    final color = active ? Colors.green.shade700 : hintColor(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: active ? Colors.green.withValues(alpha: 0.09) : cardBg(context),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: active
              ? Colors.green.withValues(alpha: 0.28)
              : cardBorder(context),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (active) ...[
            Icon(Icons.check_circle_outline, size: 14, color: color),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: AppText.caption.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _desktopStatusBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Text(
        label,
        style: AppText.caption.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _desktopMainColumn(GameDetail game, {required bool compact}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _desktopSectionTitle("简介", Icons.subject_outlined),
        Text(
          game.description?.isNotEmpty == true ? game.description! : "暂无简介",
          style: AppText.body.copyWith(
            height: 1.75,
            color: game.description?.isNotEmpty == true
                ? subTextColor(context)
                : hintColor(context),
          ),
        ),
        const SizedBox(height: 32),
        _desktopSectionTitle("可下载版本", Icons.folder_outlined),
        if (game.versions.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Text(
              "暂无版本信息",
              style: AppText.bodyMedium.copyWith(color: hintColor(context)),
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: cardBorder(context))),
            ),
            child: Column(
              children: game.versions.asMap().entries.map((entry) {
                final version = entry.value;
                return _desktopVersionRow(
                  game,
                  version,
                  compact: compact,
                  isLast: entry.key == game.versions.length - 1,
                );
              }).toList(),
            ),
          ),
      ],
    );
  }

  Widget _desktopVersionRow(
    GameDetail game,
    GameVersion version, {
    required bool compact,
    required bool isLast,
  }) {
    final platformColor = _platformColor(version.platform);
    return Container(
      constraints: const BoxConstraints(minHeight: 66),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(bottom: BorderSide(color: cardBorder(context))),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: platformColor.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(
              Icons.file_present_outlined,
              size: 18,
              color: platformColor,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  version.filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      AppText.bodySmall.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  _versionSourceDetail(version),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(color: hintColor(context)),
                ),
                if (version.extractPassword?.isNotEmpty == true) ...[
                  const SizedBox(height: 3),
                  Text(
                    "已收录解压密码",
                    style: AppText.caption.copyWith(color: hintColor(context)),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: platformColor.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              version.platform,
              style: AppText.caption.copyWith(
                color: platformColor,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (!compact) ...[
            const SizedBox(width: 14),
            SizedBox(
              width: 68,
              child: Text(
                _formatSize(version.fileSize),
                textAlign: TextAlign.right,
                style: AppText.caption.copyWith(color: hintColor(context)),
              ),
            ),
          ],
          const SizedBox(width: 8),
          IconButton(
            tooltip: "下载此版本",
            onPressed: () => _startDownload(game, version),
            icon: const Icon(Icons.download_outlined, size: 20),
            color: Theme.of(context).colorScheme.primary,
          ),
        ],
      ),
    );
  }

  Widget _desktopSideColumn(GameDetail game) {
    final platforms = game.versions
        .map((version) => version.platform.trim())
        .where((platform) => platform.isNotEmpty)
        .toSet()
        .join("、");
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _desktopSectionTitle("数据完整度", Icons.fact_check_outlined),
        _desktopCompletenessCard(game),
        const SizedBox(height: 32),
        _desktopSectionTitle("详细信息", Icons.info_outline),
        Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: cardBorder(context))),
          ),
          child: Column(
            children: [
              _desktopInfoRow("开发商", game.developer),
              _desktopInfoRow("发售日", game.releaseDate),
              _desktopInfoRow("平均时长", _formatPlaytime(game)),
              _desktopInfoRow("平台", platforms),
              _desktopInfoRow("资源总大小", _formatSize(_totalVersionBytes(game))),
              _desktopInfoRow("资源来源", "${_versionSourceCount(game)} 类"),
            ],
          ),
        ),
        const SizedBox(height: 32),
        _desktopSectionTitle("元数据", Icons.storage_outlined),
        Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: cardBorder(context))),
          ),
          child: Column(
            children: [
              _desktopMetadataRow("VNDB", game.vndbId),
              _desktopMetadataRow("Steam", game.steamId),
              _desktopMetadataRow("Bangumi", game.bangumiId),
            ],
          ),
        ),
      ],
    );
  }

  Widget _desktopCompletenessCard(GameDetail game) {
    final score = _metadataCompleteness(game);
    final missing = _metadataMissingLabels(game);
    final color = score >= 80
        ? Colors.green
        : score >= 55
            ? Colors.orange
            : Colors.red;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  "$score%",
                  style: AppText.headline.copyWith(
                    color: color,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                missing.isEmpty ? "资料完整" : "缺失 ${missing.length} 项",
                style: AppText.caption.copyWith(color: hintColor(context)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: score / 100,
              minHeight: 7,
              backgroundColor: cardBorder(context).withValues(alpha: 0.45),
              color: color,
            ),
          ),
          if (missing.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: missing
                  .map((label) => _desktopStatusBadge(label, Colors.orange))
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _desktopSectionTitle(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Icon(icon, size: 20, color: sectionIconColor(context)),
          const SizedBox(width: 9),
          Text(
            title,
            style: AppText.section.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Widget _desktopInfoRow(String label, String? value) {
    final displayValue = value?.isNotEmpty == true ? value! : "—";
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: cardBorder(context))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: AppText.bodySmall.copyWith(color: hintColor(context)),
            ),
          ),
          Expanded(
            child: Text(
              displayValue,
              style: AppText.bodySmall.copyWith(
                color: displayValue == "—" ? hintColor(context) : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _desktopMetadataRow(String label, String? value) {
    final active = value?.isNotEmpty == true;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: cardBorder(context))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: AppText.bodySmall.copyWith(color: subTextColor(context)),
            ),
          ),
          Text(
            active ? value! : "未关联",
            style: AppText.bodySmall.copyWith(
              color: active
                  ? Theme.of(context).colorScheme.primary
                  : hintColor(context),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String t, [IconData? icon]) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: sectionIconColor(context)),
              const SizedBox(width: 6),
            ],
            Text(
              t,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: sectionTextColor(context),
              ),
            ),
          ],
        ),
      );

  Widget _fieldCard({required List<Widget> children}) => AppSurface(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        radius: AppRadius.md,
        child: Column(children: children),
      );

  Widget _hintCard(String text) => AppSurface(
        padding: const EdgeInsets.all(16),
        radius: AppRadius.md,
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 18, color: hintColor(context)),
            const SizedBox(width: 8),
            Text(
              text,
              style: AppText.bodyMedium.copyWith(color: hintColor(context)),
            ),
          ],
        ),
      );

  Color _platformColor(String platform) {
    switch (platform.toLowerCase()) {
      case "windows":
        return Colors.blue;
      case "android":
        return Colors.green;
      case "linux":
        return Colors.orange;
      case "mac":
        return Colors.grey;
      default:
        return Colors.blueGrey;
    }
  }

  Widget _infoRow(String label, String? value, [IconData? icon]) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: hintColor(context)),
            const SizedBox(width: 8),
          ],
          SizedBox(
            width: 70,
            child: Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(
                label,
                style: AppText.bodyMedium.copyWith(color: hintColor(context)),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value?.isNotEmpty == true ? value! : "—",
              style: AppText.body.copyWith(
                color: value?.isNotEmpty == true ? null : Colors.grey[700],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider() =>
      Divider(height: 1, thickness: 0.5, color: cardBorder(context));

  Widget _sourceBadge(String label, String? id) {
    final active = id != null && id.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color:
              active ? Colors.green.withValues(alpha: 0.15) : cardBg(context),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color:
                active ? Colors.green.withValues(alpha: 0.35) : Colors.white24,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (active)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(
                  Icons.check_circle,
                  size: 12,
                  color: Colors.green[300],
                ),
              ),
            Text(
              label,
              style: AppText.label.copyWith(
                fontWeight: FontWeight.w500,
                color: active ? Colors.green[300] : Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tagChips(
    List<Tag> tags, {
    bool centered = false,
    bool compact = false,
  }) {
    return Wrap(
      alignment: centered ? WrapAlignment.center : WrapAlignment.start,
      spacing: compact ? 6 : 8,
      runSpacing: compact ? 6 : 8,
      children: tags.map((tag) {
        final color = _tagColor(tag);
        return Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 9 : 11,
            vertical: compact ? 5 : 6,
          ),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: color.withValues(alpha: 0.24)),
          ),
          child: Text(
            tag.name,
            style: AppText.caption.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
      }).toList(),
    );
  }

  Color _tagColor(Tag tag) {
    final raw = tag.color.trim();
    final hex = raw.startsWith("#") ? raw.substring(1) : raw;
    if (hex.length == 6 || hex.length == 8) {
      final value = int.tryParse(hex, radix: 16);
      if (value != null) {
        return Color(hex.length == 6 ? 0xFF000000 | value : value);
      }
    }
    return Theme.of(context).colorScheme.primary;
  }

  Widget _coverPlaceholder() => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.grey[850]
              : Colors.grey[200],
          borderRadius: BorderRadius.circular(12),
        ),
        width: 200,
        height: 280,
        child: Center(
          child: Icon(
            Icons.image,
            size: 64,
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.grey[700]
                : Colors.grey[400],
          ),
        ),
      );

  int _metadataCompleteness(GameDetail game) {
    final checks = <bool>[
      game.coverPath?.isNotEmpty == true,
      game.bgPath?.isNotEmpty == true,
      game.description?.isNotEmpty == true,
      game.developer?.isNotEmpty == true,
      game.releaseDate?.isNotEmpty == true,
      game.lengthMinutes > 0 || game.length > 0,
      game.tags.isNotEmpty,
      game.versions.isNotEmpty,
      game.vndbId?.isNotEmpty == true ||
          game.steamId?.isNotEmpty == true ||
          game.bangumiId?.isNotEmpty == true,
    ];
    final filled = checks.where((value) => value).length;
    return ((filled / checks.length) * 100).round();
  }

  List<String> _metadataMissingLabels(GameDetail game) {
    final missing = <String>[];
    if (game.coverPath?.isNotEmpty != true) missing.add("封面");
    if (game.bgPath?.isNotEmpty != true) missing.add("背景");
    if (game.description?.isNotEmpty != true) missing.add("简介");
    if (game.developer?.isNotEmpty != true) missing.add("开发商");
    if (game.releaseDate?.isNotEmpty != true) missing.add("发售日");
    if (game.lengthMinutes <= 0 && game.length <= 0) missing.add("平均时长");
    if (game.tags.isEmpty) missing.add("标签");
    if (game.versions.isEmpty) missing.add("版本");
    if (game.vndbId?.isNotEmpty != true &&
        game.steamId?.isNotEmpty != true &&
        game.bangumiId?.isNotEmpty != true) {
      missing.add("来源ID");
    }
    return missing;
  }

  int _totalVersionBytes(GameDetail game) =>
      game.versions.fold(0, (total, version) => total + version.fileSize);

  int _versionSourceCount(GameDetail game) => game.versions
      .map((version) => _versionSourceLabel(version))
      .where((source) => source.isNotEmpty)
      .toSet()
      .length;

  String _versionSourceLabel(GameVersion version) {
    final type = version.sourceType.trim().toLowerCase();
    return switch (type) {
      "openlist" => "OpenList",
      "local" => "本地",
      "steam_patch" => "Steam 补丁库",
      "" => "本地",
      _ => version.sourceType,
    };
  }

  String _versionSourceDetail(GameVersion version) {
    final label = _versionSourceLabel(version);
    final path = version.sourcePath?.trim();
    if (path != null && path.isNotEmpty) return "$label · $path";
    return label;
  }

  String _formatPlaytime(GameDetail game) {
    final minutes = game.lengthMinutes;
    if (minutes > 0) {
      final h = minutes ~/ 60;
      final m = minutes % 60;
      if (h > 0 && m > 0) return "$h 小时 $m 分";
      if (h > 0) return "$h 小时";
      return "$m 分";
    }
    // Fallback: VNDB length category
    switch (game.length) {
      case 1:
        return "很短 (< 2h)";
      case 2:
        return "短 (2–10h)";
      case 3:
        return "中等 (10–30h)";
      case 4:
        return "长 (30–50h)";
      case 5:
        return "很长 (> 50h)";
      default:
        return "—";
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1048576) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1073741824) return "${(bytes / 1048576).toStringAsFixed(1)} MB";
    return "${(bytes / 1073741824).toStringAsFixed(1)} GB";
  }

  Future<void> _showDownloadDialog(GameDetail game) async {
    final v = await showDialog<dynamic>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.download, size: 22, color: Colors.blue),
            SizedBox(width: 8),
            Text("选择版本"),
          ],
        ),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: game.versions
                .map(
                  (v) => Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => Navigator.pop(ctx, v),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            Icon(
                              Icons.insert_drive_file_outlined,
                              size: 20,
                              color: subTextColor(context),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    v.filename,
                                    style: AppText.bodyMedium.copyWith(
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    "${_formatSize(v.fileSize)} · ${_versionSourceDetail(v)}",
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppText.label.copyWith(
                                      color: hintColor(context),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                color: _platformColor(
                                  v.platform,
                                ).withValues(alpha: 0.12),
                              ),
                              child: Text(
                                v.platform,
                                style: AppText.label.copyWith(
                                  fontWeight: FontWeight.w500,
                                  color: _platformColor(v.platform),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("取消"),
          ),
        ],
      ),
    );
    if (v == null || !mounted) return;
    _startDownload(game, v);
  }

  Future<void> _showManagerInstallDialog(GameDetail game) async {
    if (game.versions.isEmpty) {
      _showDialog(context, "提示", "暂无可推送的下载版本");
      return;
    }

    GameVersion selectedVersion = game.versions.first;
    String? runningTarget;
    String? errorText;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final isBusy = runningTarget != null;
          final missingBangumi = (game.bangumiId ?? "").trim().isEmpty;

          Future<void> pushToManager(String target) async {
            if (isBusy) return;
            final version = selectedVersion;
            if (target == "reinamanager" && missingBangumi) {
              setDialogState(() {
                errorText = "ReinaManager 推送需要 Bangumi ID，请先补全该条目的 Bangumi ID。";
              });
              return;
            }

            setDialogState(() {
              runningTarget = target;
              errorText = null;
            });

            try {
              final link = await _api.createManagerInstallLink(
                gameId: game.id,
                versionId: version.id,
                target: target,
              );
              await ManagerInstallService.openInstallUrl(link.installUrl);
              if (!mounted) return;
              Navigator.of(dialogContext).pop();
              _showDialog(
                context,
                "已发起推送",
                "已打开 ${_managerDisplayName(target)}，下载和入库由目标管理器继续处理。",
              );
            } catch (e) {
              if (!mounted) return;
              setDialogState(() {
                runningTarget = null;
                errorText = _cleanErrorMessage(e);
              });
            }
          }

          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            titlePadding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
            contentPadding: const EdgeInsets.fromLTRB(22, 16, 22, 8),
            actionsPadding: const EdgeInsets.fromLTRB(22, 0, 22, 18),
            title: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Icon(
                    Icons.send_outlined,
                    size: 20,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "推送到管理器下载",
                        style: AppText.title.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        "先选择版本，再选择目标管理器",
                        style: AppText.caption.copyWith(
                          color: hintColor(context),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (game.versions.length > 1) ...[
                    _managerVersionSelector(
                      versions: game.versions,
                      selected: selectedVersion,
                      disabled: isBusy,
                      onChanged: (version) {
                        setDialogState(() {
                          selectedVersion = version;
                          errorText = null;
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                  ],
                  _managerPayloadSummary(game, selectedVersion),
                  const SizedBox(height: 14),
                  _managerInstallOption(
                    name: "LunaBox",
                    description: "通过 lunabox://install 打开，后续刮削由 LunaBox 完成。",
                    assetPath: "assets/manager_icons/lunabox.png",
                    loading: runningTarget == "lunabox",
                    disabled: isBusy && runningTarget != "lunabox",
                    onTap: () => pushToManager("lunabox"),
                  ),
                  const SizedBox(height: 10),
                  _managerInstallOption(
                    name: "ReinaManager",
                    description: missingBangumi
                        ? "需要先补全 Bangumi ID，才能推送到 ReinaManager。"
                        : "通过 reinamanager://install 打开，后续刮削由 ReinaManager 完成。",
                    assetPath: "assets/manager_icons/reinamanager.png",
                    loading: runningTarget == "reinamanager",
                    disabled: missingBangumi ||
                        (isBusy && runningTarget != "reinamanager"),
                    onTap: () => pushToManager("reinamanager"),
                  ),
                  if (errorText != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        border: Border.all(
                          color: Colors.red.withValues(alpha: 0.18),
                        ),
                      ),
                      child: Text(
                        errorText!,
                        style: AppText.bodySmall.copyWith(color: Colors.red),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: isBusy ? null : () => Navigator.pop(dialogContext),
                child: const Text("取消"),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _managerPayloadSummary(GameDetail game, GameVersion version) {
    final ids = <Widget>[
      if ((game.bangumiId ?? "").trim().isNotEmpty)
        _managerMetaChip("BGM", game.bangumiId!.trim()),
      if ((game.vndbId ?? "").trim().isNotEmpty)
        _managerMetaChip("VNDB", game.vndbId!.trim()),
      if ((game.steamId ?? "").trim().isNotEmpty)
        _managerMetaChip("Steam", game.steamId!.trim()),
    ];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardBg(context),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: cardBorder(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            game.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.bodyMedium.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            version.filename,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.label.copyWith(color: subTextColor(context)),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _managerMetaChip("大小", _formatSize(version.fileSize)),
              _managerMetaChip("平台", version.platform),
              if (ids.isNotEmpty) ...ids,
            ],
          ),
        ],
      ),
    );
  }

  Widget _managerVersionSelector({
    required List<GameVersion> versions,
    required GameVersion selected,
    required bool disabled,
    required ValueChanged<GameVersion> onChanged,
  }) {
    return DropdownButtonFormField<GameVersion>(
      value: selected,
      isExpanded: true,
      onChanged: disabled
          ? null
          : (version) {
              if (version != null) onChanged(version);
            },
      decoration: InputDecoration(
        labelText: "选择下载版本",
        prefixIcon: const Icon(Icons.folder_zip_outlined, size: 20),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide(color: cardBorder(context)),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      items: versions
          .map(
            (version) => DropdownMenuItem<GameVersion>(
              value: version,
              child: Text(
                "${version.platform} · ${version.filename} · ${_formatSize(version.fileSize)}",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _managerMetaChip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        "$label: $value",
        style: AppText.caption.copyWith(
          color: subTextColor(context),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _managerInstallOption({
    required String name,
    required String description,
    required String assetPath,
    required bool loading,
    required bool disabled,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    final fg = disabled ? hintColor(context) : cs.onSurface;
    return Material(
      color: disabled
          ? cs.surfaceContainerHighest.withValues(alpha: 0.32)
          : cardBg(context),
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: disabled || loading ? null : onTap,
        child: Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: disabled
                  ? cardBorder(context).withValues(alpha: 0.58)
                  : cs.primary.withValues(alpha: 0.18),
            ),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                child: Image.asset(
                  assetPath,
                  width: 42,
                  height: 42,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 42,
                    height: 42,
                    color: cs.primary.withValues(alpha: 0.12),
                    child: Icon(Icons.apps_outlined, color: cs.primary),
                  ),
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: AppText.bodyMedium.copyWith(
                        color: fg,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(
                        color: disabled
                            ? hintColor(context)
                            : subTextColor(context),
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (loading)
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  disabled ? Icons.info_outline : Icons.open_in_new_outlined,
                  size: 20,
                  color: disabled ? hintColor(context) : cs.primary,
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _managerDisplayName(String target) =>
      target == "reinamanager" ? "ReinaManager" : "LunaBox";

  String _cleanErrorMessage(Object error) {
    final message = error.toString().trim();
    return message
        .replaceFirst(RegExp(r"^Exception:\s*"), "")
        .replaceFirst(RegExp(r"^HttpException:\s*"), "");
  }

  Future<void> _startDownload(GameDetail game, dynamic v) async {
    final prefs = await SharedPreferences.getInstance();
    var dlDir = prefs.getString("local_download_dir");
    if (dlDir == null || dlDir.isEmpty) {
      if (mounted) {
        final result = await FilePicker.platform.getDirectoryPath(
          dialogTitle: "选择游戏下载目录",
        );
        if (result == null || !mounted) return;
        dlDir = result;
        await DownloadService().setDownloadDir(result);
      }
    }

    // On Android: check storage permission before starting download
    if (Platform.isAndroid &&
        dlDir != null &&
        DownloadService().needsStoragePermission(dlDir)) {
      final granted = await DownloadService().checkStoragePermissionGranted();
      if (!granted && mounted) {
        // Save pending download so we can retry after permission granted
        _pendingGame = game;
        _pendingVersion = v;
        await _showStoragePermissionDialog();
        return;
      }
    }

    final downloadUrl = "$_baseUrl/api/download/${game.id}/${v.id}";
    // Build cover and background URLs from scraped metadata
    String? coverUrl;
    String? bgUrl;
    if (game.coverPath != null && game.coverPath!.isNotEmpty) {
      final name = game.coverPath!.split(RegExp(r'[/\\]')).last;
      coverUrl = "$_baseUrl/api/files/covers/$name";
    }
    if (game.bgPath != null && game.bgPath!.isNotEmpty) {
      final name = game.bgPath!.split(RegExp(r'[/\\]')).last;
      bgUrl = "$_baseUrl/api/files/backgrounds/$name";
    }
    final task = DownloadService().startDownload(
      gameId: game.id,
      versionId: v.id,
      fileName: v.filename,
      downloadUrl: downloadUrl,
      gameName: game.name,
      companyName: game.companyName ?? "",
      coverUrl: coverUrl,
      bgUrl: bgUrl,
      extractPassword: v.extractPassword,
    );
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => _DownloadProgressDialog(task: task),
      );
    }
  }

  Future<void> _showStoragePermissionDialog() async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.folder_off, size: 32, color: Colors.orange[300]),
        title: const Text("需要存储权限"),
        content: const Text(
          "Android 11+ 解压游戏到共享存储需要「所有文件访问」权限，否则会解压失败。\n\n"
          "点击下方按钮跳转系统设置，开启权限后返回应用将自动继续下载。",
        ),
        actions: [
          OutlinedButton.icon(
            onPressed: () async {
              Navigator.pop(ctx);
              await DownloadService().openStoragePermissionSettings();
              // Result auto-detected via WidgetsBindingObserver when app resumes
            },
            icon: const Icon(Icons.settings, size: 16),
            label: const Text("前往设置"),
          ),
          FilledButton(
            onPressed: () {
              _pendingGame = null;
              _pendingVersion = null;
              Navigator.pop(ctx);
            },
            child: const Text("取消"),
          ),
        ],
      ),
    );
  }
}

// ── Download progress dialog ──
class _DownloadProgressDialog extends StatefulWidget {
  final DownloadTask task;
  const _DownloadProgressDialog({required this.task});

  @override
  State<_DownloadProgressDialog> createState() =>
      _DownloadProgressDialogState();
}

class _DownloadProgressDialogState extends State<_DownloadProgressDialog> {
  late DownloadTask _task;
  StreamSubscription<List<DownloadTask>>? _sub;
  final _pwdCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _task = widget.task;
    _sub = DownloadService().tasks.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _pwdCtrl.dispose();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          _statusIcon(),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _task.fileName,
              style: const TextStyle(fontSize: 16),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              "${_task.companyName}/${_task.gameName}",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.label.copyWith(color: hintColor(context)),
            ),
            const SizedBox(height: 16),
            _buildProgressSection(),
          ],
        ),
      ),
      actions: [
        if (_task.status == "failed")
          _task.needsPassword
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _pwdCtrl,
                            obscureText: true,
                            decoration: const InputDecoration(
                              hintText: "请输入压缩包密码",
                              isDense: true,
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () {
                            final pwd = _pwdCtrl.text.trim();
                            if (pwd.isNotEmpty)
                              DownloadService().retryWithPassword(_task, pwd);
                          },
                          child: const Text("带密码重试"),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        FilledButton(
                          onPressed: () => DownloadService().retryTask(_task),
                          child: const Text("无密码重试"),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text("关闭"),
                        ),
                      ],
                    ),
                  ],
                )
              : Row(
                  children: [
                    FilledButton(
                      onPressed: () => DownloadService().retryTask(_task),
                      child: const Text("重试"),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text("关闭"),
                    ),
                  ],
                )
        else if (_task.status == "done" || _task.status == "cancelled")
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // PC-only: Steam + Shortcut buttons (Android has no Steam/desktop)
              if (_task.status == "done" &&
                  _task.outputPath != null &&
                  !_task.isApk &&
                  !Platform.isAndroid) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _openTargetFolder(_task.outputPath!),
                      icon: const Icon(Icons.folder_open, size: 16),
                      label: const Text(
                        "打开文件夹",
                        style: TextStyle(fontSize: 12),
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _addToSteamDownload(_task),
                      icon: const Icon(Icons.gamepad, size: 16),
                      label: const Text(
                        "Steam",
                        style: TextStyle(fontSize: 12),
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _createShortcut(_task),
                      icon: const Icon(Icons.desktop_windows, size: 16),
                      label: const Text("快捷方式", style: TextStyle(fontSize: 12)),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
              ],
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("关闭"),
                ),
              ),
            ],
          ),
        if (_task.status == "paused")
          Row(
            children: [
              FilledButton(
                onPressed: () => DownloadService().resumeTask(_task),
                child: const Text("继续下载"),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
              ),
              TextButton(
                onPressed: _cancelAndClose,
                child: const Text("取消", style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        if (_task.status == "downloading" || _task.status == "extracting")
          Row(
            children: [
              TextButton(
                onPressed: () {
                  DownloadService().pauseTask(_task);
                },
                child: const Text("暂停"),
              ),
              TextButton(
                onPressed: _cancelAndClose,
                child: const Text("取消", style: TextStyle(color: Colors.red)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("后台运行"),
              ),
            ],
          ),
        if (_task.status == "pending")
          Row(
            children: [
              TextButton(
                onPressed: _cancelAndClose,
                child: const Text("取消", style: TextStyle(color: Colors.red)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("后台运行"),
              ),
            ],
          ),
      ],
    );
  }

  void _cancelAndClose() {
    DownloadService().cancelTask(_task);
    Navigator.pop(context);
  }

  Future<void> _openTargetFolder(String path) async {
    try {
      final ok = await FileOpenService.openTargetFolder(path);
      if (!ok) _showDialog(context, "提示", "无法打开目标文件夹");
    } catch (e) {
      _showDialog(context, "提示", "无法打开目标文件夹: $e");
    }
  }

  Future<void> _addToSteamDownload(DownloadTask task) async {
    if (task.outputPath == null) return;
    final exes = ShortcutService.findAllExecutables(
      task.outputPath!,
      gameName: task.gameName,
    );
    if (exes.isEmpty) {
      _showDialog(context, "提示", "未找到可执行文件");
      return;
    }
    String exe = exes.first;
    if (exes.length > 1) {
      final picked = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("选择启动程序"),
          content: SizedBox(
            width: 400,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: exes.length,
              itemBuilder: (_, i) => ListTile(
                leading: const Icon(Icons.insert_drive_file, size: 20),
                title: Text(
                  exes[i].split(RegExp(r"[/\\]")).last,
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(exes[i], style: const TextStyle(fontSize: 11)),
                onTap: () => Navigator.pop(ctx, exes[i]),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("取消"),
            ),
          ],
        ),
      );
      if (picked != null)
        exe = picked;
      else
        return;
    }
    // Resolve cover/hero URLs: use task values, or refetch from API if missing
    String coverUrl = task.coverUrl ?? "";
    String heroUrl = task.bgUrl ?? "";
    if ((coverUrl.isEmpty || heroUrl.isEmpty) && task.gameId > 0) {
      try {
        final api = context.read<GameProvider>().api;
        final resp = await http.get(
          Uri.parse("${api.baseUrl}/api/games/${task.gameId}"),
          headers: api.headers,
        );
        if (resp.statusCode == 200) {
          final g = jsonDecode(resp.body);
          if (coverUrl.isEmpty &&
              g["cover_path"] != null &&
              g["cover_path"].toString().isNotEmpty) {
            final name =
                g["cover_path"].toString().split(RegExp(r'[/\\]')).last;
            coverUrl = "${api.baseUrl}/api/files/covers/$name";
          }
          if (heroUrl.isEmpty &&
              g["bg_path"] != null &&
              g["bg_path"].toString().isNotEmpty) {
            final name = g["bg_path"].toString().split(RegExp(r'[/\\]')).last;
            heroUrl = "${api.baseUrl}/api/files/backgrounds/$name";
          }
        }
      } catch (_) {}
    }

    var result = await SteamIntegrationService().addToSteam(
      gameName: task.gameName,
      exePath: exe,
      coverUrl: coverUrl,
      heroUrl: heroUrl,
    );
    if (!result.success && result.message.contains("未配置 Steam 目录")) {
      final picked = await FilePicker.platform.getDirectoryPath(
        dialogTitle: "选择 Steam steamapps 目录",
      );
      if (picked != null) {
        await SteamIntegrationService().setSteamappsDir(picked);
        result = await SteamIntegrationService().addToSteam(
          gameName: task.gameName,
          exePath: exe,
          coverUrl: coverUrl,
          heroUrl: heroUrl,
        );
      }
    }
    _showDialog(context, result.success ? "完成" : "失败", result.message);
  }

  Future<void> _createShortcut(DownloadTask task) async {
    if (task.outputPath == null) return;
    final exes = ShortcutService.findAllExecutables(
      task.outputPath!,
      gameName: task.gameName,
    );
    if (exes.isEmpty) {
      _showDialog(context, "提示", "未找到可执行文件");
      return;
    }
    String exe = exes.first;
    if (exes.length > 1) {
      final picked = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("选择启动程序"),
          content: SizedBox(
            width: 400,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: exes.length,
              itemBuilder: (_, i) => ListTile(
                leading: const Icon(Icons.insert_drive_file, size: 20),
                title: Text(
                  exes[i].split(RegExp(r"[/\\]")).last,
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(exes[i], style: const TextStyle(fontSize: 11)),
                onTap: () => Navigator.pop(ctx, exes[i]),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("取消"),
            ),
          ],
        ),
      );
      if (picked != null)
        exe = picked;
      else
        return;
    }
    String? coverPath;
    try {
      final api = context.read<GameProvider>().api;
      final resp = await http.get(
        Uri.parse("${api.baseUrl}/api/games/${task.gameId}"),
        headers: api.headers,
      );
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final cover = data["cover_path"]?.toString() ?? "";
        if (cover.isNotEmpty) {
          final name = cover.split(RegExp(r'[/\\]')).last;
          coverPath = await ShortcutService.downloadCover(
            "${api.baseUrl}/api/files/covers/$name",
            task.gameName,
          );
        }
      }
    } catch (_) {}
    try {
      await ShortcutService.createShortcut(
        gameName: task.gameName,
        exePath: exe,
        coverPath: coverPath,
      );
      _showDialog(context, "完成", "桌面快捷方式已创建");
    } catch (e) {
      _showDialog(context, "失败", "$e");
    }
  }

  Widget _statusIcon() {
    switch (_task.status) {
      case "downloading":
        return SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(Colors.blue[300]),
          ),
        );
      case "extracting":
        return Icon(Icons.folder_zip, size: 24, color: Colors.orange[300]);
      case "done":
        return Icon(Icons.check_circle, size: 24, color: Colors.green[300]);
      case "failed":
        return Icon(Icons.error, size: 24, color: Colors.red[300]);
      default:
        return Icon(Icons.download, size: 24, color: subTextColor(context));
    }
  }

  String _formatSpeed(int bytesPerSec) {
    if (bytesPerSec <= 0) return "下载中...";
    if (bytesPerSec < 1024) return "$bytesPerSec B/s";
    if (bytesPerSec < 1048576)
      return "${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s";
    return "${(bytesPerSec / 1048576).toStringAsFixed(1)} MB/s";
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1048576) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1073741824) return "${(bytes / 1048576).toStringAsFixed(1)} MB";
    return "${(bytes / 1073741824).toStringAsFixed(1)} GB";
  }

  String _downloadProgressLabel() {
    if (_task.totalBytes > 0) {
      return "${(_task.progress * 100).toStringAsFixed(0)}%";
    }
    if (_task.receivedBytes > 0) {
      return "已下载 ${_formatBytes(_task.receivedBytes)}";
    }
    if (_task.headersReceived) {
      return "已连接，等待数据...";
    }
    return "正在连接...";
  }

  Widget _buildProgressSection() {
    switch (_task.status) {
      case "downloading":
        return Column(
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(4)),
              child: LinearProgressIndicator(
                value: _task.totalBytes > 0 ? _task.progress : null,
                minHeight: 8,
                backgroundColor: cardBorder(context),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _downloadProgressLabel(),
                  style: AppText.bodyMedium.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  _formatSpeed(_task.speedBytesPerSecond),
                  style: AppText.bodySmall.copyWith(
                    color: subTextColor(context),
                  ),
                ),
              ],
            ),
          ],
        );
      case "pending":
        return Row(
          children: [
            Icon(Icons.schedule, color: subTextColor(context), size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                "等待下载队列...",
                style: AppText.bodyMedium.copyWith(
                  color: subTextColor(context),
                ),
              ),
            ),
          ],
        );
      case "extracting":
        return Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Text(
              "正在解压...",
              style: AppText.bodyMedium.copyWith(color: Colors.orange[300]),
            ),
          ],
        );
      case "done":
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green[300], size: 20),
                const SizedBox(width: 8),
                Text(
                  "下载并解压完成",
                  style: AppText.body.copyWith(color: Colors.green[300]),
                ),
              ],
            ),
            if (_task.outputPath != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: cardBg(context),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _task.outputPath!,
                  style: AppText.label.copyWith(
                    color: subTextColor(context),
                    fontFamily: "monospace",
                  ),
                ),
              ),
            ],
          ],
        );
      case "paused":
        return Row(
          children: [
            Icon(Icons.pause_circle, color: Colors.orange[300], size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                "${(_task.progress * 100).toStringAsFixed(0)}% · 已暂停",
                style: AppText.bodyMedium.copyWith(color: Colors.orange[300]),
              ),
            ),
          ],
        );
      case "failed":
        return Row(
          children: [
            Icon(Icons.error, color: Colors.red[300], size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _task.error ?? "下载失败",
                style: AppText.bodySmall.copyWith(color: Colors.red[300]),
              ),
            ),
          ],
        );
      case "cancelled":
        return Row(
          children: [
            Icon(Icons.cancel, color: subTextColor(context), size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                "已取消",
                style: AppText.bodySmall.copyWith(color: subTextColor(context)),
              ),
            ),
          ],
        );
      default:
        return Row(
          children: [
            Icon(Icons.download, color: subTextColor(context), size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                "准备下载...",
                style: AppText.bodySmall.copyWith(color: subTextColor(context)),
              ),
            ),
          ],
        );
    }
  }
}
