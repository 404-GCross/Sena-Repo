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
import "../services/shortcut_service.dart";
import "../services/steam_integration_service.dart";
import "../providers/game_provider.dart";
import "../utils/theme_utils.dart";
import "download_manager_screen.dart";
import "game_edit_screen.dart";

void _showDialog(BuildContext ctx, String title, String msg) {
  showDialog(context: ctx, builder: (c) => AlertDialog(title: Text(title), content: Text(msg), actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text("确定"))]));
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
    try {
      final game = await _api.getGame(widget.gameId);
      if (mounted) setState(() { _game = game; _isLoading = false; _refreshKey++; });
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return Scaffold(appBar: AppBar(title: const Text("加载中...")), body: const Center(child: CircularProgressIndicator()));
    final game = _game;
    if (game == null) return Scaffold(appBar: AppBar(title: const Text("错误")), body: const Center(child: Text("游戏未找到")));

    final hasCover = game.coverPath != null && game.coverPath!.isNotEmpty;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(game.name),
        actions: [
          IconButton(icon: const Icon(Icons.edit), tooltip: "编辑",
            onPressed: () async {
              final changed = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => GameEditScreen(game: game)));
              if (changed == true) _load();
            }),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: LayoutBuilder(builder: (ctx, constraints) {
              final w = constraints.maxWidth;
              final wide = w > 500;
              final heroH = wide ? (w > 700 ? 280.0 : 200.0) : 140.0;
              final coverW = wide ? (w > 700 ? 200.0 : 150.0) : 130.0;
              final coverH = coverW * 1.4;
              return Column(children: [
              // ── Hero banner (landscape, 16:9) ──
              if (game.bgPath != null && game.bgPath!.isNotEmpty)
                Padding(
                  padding: EdgeInsets.fromLTRB(wide ? 16 : 0, wide ? 12 : 0, wide ? 16 : 0, 0),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(wide ? 14 : 0),
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: Image.network(
                        "$_baseUrl/api/files/backgrounds/${game.bgPath!.split("/").last}?t=$_refreshKey",
                        width: double.infinity,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      ),
                  ),
                ),
              ),
              // ── Header ──
              Padding(
                padding: EdgeInsets.fromLTRB(wide ? 32 : 8, wide ? 20 : 10, wide ? 32 : 8, 0),
                child: wide
                    ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(game.name, style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, height: 1.2)),
                            if (game.companyName != null) ...[
                              const SizedBox(height: 6),
                              Row(children: [
                                Icon(Icons.business, size: 16, color: subTextColor(context)),
                                const SizedBox(width: 6),
                                Text(game.companyName!, style: TextStyle(fontSize: 16, color: subTextColor(context))),
                              ]),
                            ],
                            if (game.vndbId != null || game.steamId != null || game.bangumiId != null) ...[
                              const SizedBox(height: 10),
                              Row(children: [
                                _sourceBadge("VNDB", game.vndbId),
                                _sourceBadge("Steam", game.steamId),
                                _sourceBadge("Bangumi", game.bangumiId),
                              ]),
                            ],
                            const SizedBox(height: 16),
                            if (game.versions.isNotEmpty)
                              FilledButton.icon(
                                onPressed: () => _showDownloadDialog(game),
                                icon: const Icon(Icons.download, size: 18),
                                label: const Text("下载游戏"),
                                style: FilledButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                                ),
                              ),
                          ]),
                        ),
                        const SizedBox(width: 24),
                        Container(
                          width: coverW, height: coverH,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            boxShadow: [
                              BoxShadow(color: cs.primary.withValues(alpha: 0.3), blurRadius: 24, offset: const Offset(0, 12)),
                              BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 8, offset: const Offset(0, 4)),
                            ],
                            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: hasCover
                                ? Image.network("$_baseUrl/api/files/covers${game.coverPath!}?t=$_refreshKey",
                                    fit: BoxFit.cover, errorBuilder: (_, __, ___) => _coverPlaceholder())
                                : _coverPlaceholder()),
                        ),
                      ])
                    // Narrow: cover top, name centered below
                    : Column(children: [
                        if (hasCover)
                          Center(
                            child: Container(
                              width: coverW, height: coverH,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                boxShadow: [
                                  BoxShadow(color: cs.primary.withValues(alpha: 0.2), blurRadius: 20, offset: const Offset(0, 8)),
                                ],
                                border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(14),
                                child: Image.network("$_baseUrl/api/files/covers${game.coverPath!}?t=$_refreshKey",
                                    fit: BoxFit.cover, errorBuilder: (_, __, ___) => _coverPlaceholder()),
                              ),
                            ),
                          ),
                        const SizedBox(height: 10),
                        Text(game.name, textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, height: 1.2)),
                        if (game.companyName != null) ...[
                          const SizedBox(height: 4),
                          Text(game.companyName!, textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 14, color: subTextColor(context))),
                        ],
                        if (game.vndbId != null || game.steamId != null || game.bangumiId != null) ...[
                          const SizedBox(height: 8),
                          Wrap(alignment: WrapAlignment.center, spacing: 6, children: [
                            _sourceBadge("VNDB", game.vndbId),
                            _sourceBadge("Steam", game.steamId),
                            _sourceBadge("Bangumi", game.bangumiId),
                          ]),
                        ],
                        if (game.versions.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Center(
                            child: FilledButton.icon(
                              onPressed: () => _showDownloadDialog(game),
                              icon: const Icon(Icons.download, size: 18),
                              label: const Text("下载游戏"),
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                              ),
                            ),
                          ),
                        ],
                      ]),
              ),

              // ── Body: responsive ──
              Padding(
                padding: EdgeInsets.fromLTRB(wide ? 32 : 8, 24, wide ? 32 : 8, 0),
                child: wide
                    ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        // Left: description + tags
                        Expanded(flex: 5, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          _section("简介", Icons.description_outlined),
                          Container(
                            padding: const EdgeInsets.all(18),
                            decoration: BoxDecoration(
                              color: cardBg(context),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: cardBorder(context)),
                            ),
                            child: Text(
                              game.description?.isNotEmpty == true ? game.description! : "暂无简介",
                              style: AppText.body.copyWith(height: 1.7,
                                color: game.description?.isNotEmpty == true ? null : Colors.grey[500]),
                            ),
                          ),
                          if (game.tags.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            _section("标签", Icons.label_outline),
                            const SizedBox(height: 4),
                            Wrap(spacing: 8, runSpacing: 6, children: game.tags.map((t) => Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.18)),
                              ),
                              child: Text(t.name, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.primary)),
                            )).toList()),
                          ],
                        ])),
                        const SizedBox(width: 28),
                        // Right: info + versions
                        Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          _section("详细信息", Icons.info_outline),
                          _fieldCard(children: [
                            _infoRow("开发商", game.developer, Icons.business),
                            _divider(),
                            _infoRow("发售日", game.releaseDate, Icons.calendar_today),
                            _divider(),
                            _infoRow("游戏时长", _formatPlaytime(game), Icons.timer),
                          ]),
                          const SizedBox(height: 20),
                          _section("版本", Icons.folder_outlined),
                          if (game.versions.isEmpty)
                            _hintCard("暂无版本信息")
                          else
                            _fieldCard(children:
                              game.versions.asMap().entries.map((e) {
                                final v = e.value;
                                final isLast = e.key == game.versions.length - 1;
                                return Column(children: [
                                  Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 10),
                                    child: Row(children: [
                                      Icon(Icons.insert_drive_file_outlined, size: 18, color: hintColor(context)),
                                      const SizedBox(width: 10),
                                      Expanded(child: Text(v.filename, style: const TextStyle(fontSize: 14))),
                                      const SizedBox(width: 12),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(12),
                                          color: _platformColor(v.platform).withValues(alpha: 0.15),
                                        ),
                                        child: Text(v.platform, style: AppText.label.copyWith( fontWeight: FontWeight.w500, color: _platformColor(v.platform))),
                                      ),
                                      const SizedBox(width: 10),
                                      Text(_formatSize(v.fileSize), style: AppText.label.copyWith( color: hintColor(context))),
                                    ]),
                                  ),
                                  if (!isLast) _divider(),
                                ]);
                              }).toList(),
                            ),
                        ])),
                      ])
                    // Narrow: single column
                    : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        _section("简介", Icons.description_outlined),
                        Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: cardBg(context),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: cardBorder(context)),
                          ),
                          child: Text(
                            game.description?.isNotEmpty == true ? game.description! : "暂无简介",
                            style: AppText.body.copyWith(height: 1.7,
                              color: game.description?.isNotEmpty == true ? null : Colors.grey[500]),
                          ),
                        ),
                        if (game.tags.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          _section("标签", Icons.label_outline),
                          const SizedBox(height: 4),
                          Wrap(spacing: 8, runSpacing: 6, children: game.tags.map((t) => Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.18)),
                            ),
                            child: Text(t.name, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.primary)),
                          )).toList()),
                        ],
                        const SizedBox(height: 20),
                        _section("详细信息", Icons.info_outline),
                        _fieldCard(children: [
                          _infoRow("开发商", game.developer, Icons.business),
                          _divider(),
                          _infoRow("发售日", game.releaseDate, Icons.calendar_today),
                          _divider(),
                          _infoRow("游戏时长", _formatPlaytime(game), Icons.timer),
                        ]),
                        const SizedBox(height: 20),
                        _section("版本", Icons.folder_outlined),
                        if (game.versions.isEmpty)
                          _hintCard("暂无版本信息")
                        else
                          _fieldCard(children:
                            game.versions.asMap().entries.map((e) {
                              final v = e.value;
                              final isLast = e.key == game.versions.length - 1;
                              return Column(children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                  child: Row(children: [
                                    Icon(Icons.insert_drive_file_outlined, size: 18, color: hintColor(context)),
                                    const SizedBox(width: 10),
                                    Expanded(child: Text(v.filename, style: const TextStyle(fontSize: 14))),
                                    const SizedBox(width: 12),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(12),
                                        color: _platformColor(v.platform).withValues(alpha: 0.15),
                                      ),
                                      child: Text(v.platform, style: AppText.label.copyWith( fontWeight: FontWeight.w500, color: _platformColor(v.platform))),
                                    ),
                                    const SizedBox(width: 10),
                                    Text(_formatSize(v.fileSize), style: AppText.label.copyWith( color: hintColor(context))),
                                  ]),
                                ),
                                if (!isLast) _divider(),
                              ]);
                            }).toList(),
                          ),
                      ]),
              ),
            ]);
          }),
        ),
      ),
      ),
    );
  }

  Widget _section(String t, [IconData? icon]) => Padding(
    padding: const EdgeInsets.only(bottom: 8, top: 4),
    child: Row(children: [
      if (icon != null) ...[
        Icon(icon, size: 18, color: sectionIconColor(context)),
        const SizedBox(width: 6),
      ],
      Text(t, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: sectionTextColor(context))),
    ]),
  );

  Widget _fieldCard({required List<Widget> children}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    decoration: BoxDecoration(
      color: cardBg(context),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: cardBorder(context)),
    ),
    child: Column(children: children),
  );

  Widget _hintCard(String text) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: cardBg(context),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: cardBorder(context)),
    ),
    child: Row(children: [
      Icon(Icons.info_outline, size: 18, color: hintColor(context)),
      const SizedBox(width: 8),
      Text(text, style: AppText.bodyMedium.copyWith( color: hintColor(context))),
    ]),
  );

  Color _platformColor(String platform) {
    switch (platform.toLowerCase()) {
      case "windows": return Colors.blue;
      case "android": return Colors.green;
      case "linux": return Colors.orange;
      case "mac": return Colors.grey;
      default: return Colors.blueGrey;
    }
  }

  Widget _infoRow(String label, String? value, [IconData? icon]) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: hintColor(context)),
          const SizedBox(width: 8),
        ],
        SizedBox(width: 70, child: Padding(padding: const EdgeInsets.only(top: 1),
          child: Text(label, style: AppText.bodyMedium.copyWith( color: hintColor(context))))),
        Expanded(child: Text(value?.isNotEmpty == true ? value! : "—",
            style: AppText.body.copyWith( color: value?.isNotEmpty == true ? null : Colors.grey[700]))),
      ]),
    );
  }

  Widget _divider() => Divider(height: 1, thickness: 0.5, color: cardBorder(context));

  Widget _sourceBadge(String label, String? id) {
    final active = id != null && id.isNotEmpty;
    return Padding(padding: const EdgeInsets.only(right: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active ? Colors.green.withValues(alpha: 0.15) : cardBg(context),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: active ? Colors.green.withValues(alpha: 0.35) : Colors.white24)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (active)
            Padding(padding: const EdgeInsets.only(right: 4),
              child: Icon(Icons.check_circle, size: 12, color: Colors.green[300])),
          Text(label, style: AppText.label.copyWith( fontWeight: FontWeight.w500, color: active ? Colors.green[300] : Colors.grey)),
        ])));
  }

  Widget _coverPlaceholder() => Container(
    decoration: BoxDecoration(
      color: Theme.of(context).brightness == Brightness.dark ? Colors.grey[850] : Colors.grey[200],
      borderRadius: BorderRadius.circular(12),
    ),
    width: 200, height: 280,
    child: Center(child: Icon(Icons.image, size: 64,
        color: Theme.of(context).brightness == Brightness.dark ? Colors.grey[700] : Colors.grey[400])),
  );

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
      case 1: return "很短 (< 2h)";
      case 2: return "短 (2–10h)";
      case 3: return "中等 (10–30h)";
      case 4: return "长 (30–50h)";
      case 5: return "很长 (> 50h)";
      default: return "—";
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
        title: const Row(children: [
          Icon(Icons.download, size: 22, color: Colors.blue),
          SizedBox(width: 8),
          Text("选择版本"),
        ]),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, children:
            game.versions.map((v) => Card(
              margin: const EdgeInsets.only(bottom: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => Navigator.pop(ctx, v),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(children: [
                    Icon(Icons.insert_drive_file_outlined, size: 20, color: subTextColor(context)),
                    const SizedBox(width: 12),
                    Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(v.filename, style: AppText.bodyMedium.copyWith( fontWeight: FontWeight.w500)),
                        const SizedBox(height: 2),
                        Text(_formatSize(v.fileSize), style: AppText.label.copyWith( color: hintColor(context))),
                      ],
                    )),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: _platformColor(v.platform).withValues(alpha: 0.12),
                      ),
                      child: Text(v.platform, style: AppText.label.copyWith( fontWeight: FontWeight.w500,
                          color: _platformColor(v.platform))),
                    ),
                  ]),
                ),
              ),
            )).toList(),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消"))],
      ),
    );
    if (v == null || !mounted) return;
    _startDownload(game, v);
  }

  Future<void> _startDownload(GameDetail game, dynamic v) async {
    final prefs = await SharedPreferences.getInstance();
    var dlDir = prefs.getString("local_download_dir");
    if (dlDir == null || dlDir.isEmpty) {
      if (mounted) {
        final result = await FilePicker.platform.getDirectoryPath(dialogTitle: "选择游戏下载目录");
        if (result == null || !mounted) return;
        dlDir = result;
        await prefs.setString("local_download_dir", result);
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
  State<_DownloadProgressDialog> createState() => _DownloadProgressDialogState();
}

class _DownloadProgressDialogState extends State<_DownloadProgressDialog> {
  late DownloadTask _task;
  StreamSubscription<List<DownloadTask>>? _sub;

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
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(children: [
        _statusIcon(),
        const SizedBox(width: 10),
        Expanded(child: Text(_task.fileName,
            style: const TextStyle(fontSize: 16), maxLines: 1, overflow: TextOverflow.ellipsis)),
      ]),
      content: SizedBox(width: 360, child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text("${_task.companyName}/${_task.gameName}",
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: AppText.label.copyWith( color: hintColor(context))),
          const SizedBox(height: 16),
          _buildProgressSection(),
        ],
      )),
      actions: [
        if (_task.status == "failed")
          Row(children: [
            FilledButton(
              onPressed: () => DownloadService().retryTask(_task),
              child: const Text("重试"),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text("关闭")),
          ])
        else if (_task.status == "done" || _task.status == "cancelled")
          Row(children: [
            // PC-only: Steam + Shortcut buttons (Android has no Steam/desktop)
            if (_task.status == "done" && _task.outputPath != null && !_task.isApk && !Platform.isAndroid) ...[
              OutlinedButton.icon(
                onPressed: () => _addToSteamDownload(_task),
                icon: const Icon(Icons.gamepad, size: 16),
                label: const Text("Steam", style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6)),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => _createShortcut(_task),
                icon: const Icon(Icons.desktop_windows, size: 16),
                label: const Text("快捷方式", style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6)),
              ),
            ],
            const Spacer(),
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text("关闭")),
          ]),
        if (_task.status == "paused")
          Row(children: [
            FilledButton(
              onPressed: () => DownloadService().resumeTask(_task),
              child: const Text("继续下载"),
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 16)),
            ),
            TextButton(
              onPressed: () { DownloadService().cancelTask(_task); },
              child: const Text("取消", style: TextStyle(color: Colors.red)),
            ),
          ]),
        if (_task.status == "downloading" || _task.status == "extracting" || _task.status == "pending")
          Row(children: [
            TextButton(
              onPressed: () { DownloadService().pauseTask(_task); },
              child: const Text("暂停"),
            ),
            TextButton(
              onPressed: () { DownloadService().cancelTask(_task); },
              child: const Text("取消", style: TextStyle(color: Colors.red)),
            ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text("后台运行")),
          ]),
      ],
    );
  }

  Future<void> _addToSteamDownload(DownloadTask task) async {
    if (task.outputPath == null) return;
    final exes = ShortcutService.findAllExecutables(task.outputPath!);
    if (exes.isEmpty) {
      _showDialog(context, "提示", "未找到可执行文件");
      return;
    }
    String exe = exes.first;
    if (exes.length > 1) {
      final picked = await showDialog<String>(
        context: context, builder: (ctx) => AlertDialog(
          title: const Text("选择启动程序"),
          content: SizedBox(width: 400, child: ListView.builder(
            shrinkWrap: true, itemCount: exes.length,
            itemBuilder: (_, i) => ListTile(
              leading: const Icon(Icons.insert_drive_file, size: 20),
              title: Text(exes[i].split(RegExp(r"[/\\]")).last, style: const TextStyle(fontSize: 13)),
              subtitle: Text(exes[i], style: const TextStyle(fontSize: 11)),
              onTap: () => Navigator.pop(ctx, exes[i]),
            ),
          )),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消"))],
        ),
      );
      if (picked != null) exe = picked; else return;
    }
    // Resolve cover/hero URLs: use task values, or refetch from API if missing
    String coverUrl = task.coverUrl ?? "";
    String heroUrl = task.bgUrl ?? "";
    if ((coverUrl.isEmpty || heroUrl.isEmpty) && task.gameId > 0) {
      try {
        final api = context.read<GameProvider>().api;
        final resp = await http.get(Uri.parse("${api.baseUrl}/api/games/${task.gameId}"), headers: api.headers);
        if (resp.statusCode == 200) {
          final g = jsonDecode(resp.body);
          if (coverUrl.isEmpty && g["cover_path"] != null && g["cover_path"].toString().isNotEmpty) {
            final name = g["cover_path"].toString().split(RegExp(r'[/\\]')).last;
            coverUrl = "${api.baseUrl}/api/files/covers/$name";
          }
          if (heroUrl.isEmpty && g["bg_path"] != null && g["bg_path"].toString().isNotEmpty) {
            final name = g["bg_path"].toString().split(RegExp(r'[/\\]')).last;
            heroUrl = "${api.baseUrl}/api/files/backgrounds/$name";
          }
        }
      } catch (_) {}
    }

    var result = await SteamIntegrationService().addToSteam(
      gameName: task.gameName, exePath: exe,
      coverUrl: coverUrl,
      heroUrl: heroUrl,
    );
    if (!result.success && result.message.contains("未配置 Steam 目录")) {
      final picked = await FilePicker.platform.getDirectoryPath(dialogTitle: "选择 Steam steamapps 目录");
      if (picked != null) {
        await SteamIntegrationService().setSteamappsDir(picked);
        result = await SteamIntegrationService().addToSteam(
          gameName: task.gameName, exePath: exe,
          coverUrl: coverUrl,
          heroUrl: heroUrl,
        );
      }
    }
    _showDialog(context, result.success ? "完成" : "失败", result.message);
  }

  Future<void> _createShortcut(DownloadTask task) async {
    if (task.outputPath == null) return;
    final exes = ShortcutService.findAllExecutables(task.outputPath!);
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
          content: SizedBox(width: 400, child: ListView.builder(
            shrinkWrap: true, itemCount: exes.length,
            itemBuilder: (_, i) => ListTile(
              leading: const Icon(Icons.insert_drive_file, size: 20),
              title: Text(exes[i].split(RegExp(r"[/\\]")).last, style: const TextStyle(fontSize: 13)),
              subtitle: Text(exes[i], style: const TextStyle(fontSize: 11)),
              onTap: () => Navigator.pop(ctx, exes[i]),
            ),
          )),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消"))],
        ),
      );
      if (picked != null) exe = picked; else return;
    }
    String? coverPath;
    try {
      final api = context.read<GameProvider>().api;
      final base = api.baseUrl;
      final coverUrl = "$base/api/files/covers${_task.gameId}";
      coverPath = await ShortcutService.downloadCover(coverUrl, task.gameName);
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
      case "downloading": return SizedBox(
        width: 24, height: 24,
        child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.blue[300])),
      );
      case "extracting": return Icon(Icons.folder_zip, size: 24, color: Colors.orange[300]);
      case "done": return Icon(Icons.check_circle, size: 24, color: Colors.green[300]);
      case "failed": return Icon(Icons.error, size: 24, color: Colors.red[300]);
      default: return Icon(Icons.download, size: 24, color: subTextColor(context));
    }
  }

  String _formatSpeed(int bytesPerSec) {
    if (bytesPerSec <= 0) return "下载中...";
    if (bytesPerSec < 1024) return "$bytesPerSec B/s";
    if (bytesPerSec < 1048576) return "${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s";
    return "${(bytesPerSec / 1048576).toStringAsFixed(1)} MB/s";
  }

  Widget _buildProgressSection() {
    switch (_task.status) {
      case "downloading":
        return Column(children: [
          ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(4)),
            child: LinearProgressIndicator(
              value: _task.progress, minHeight: 8,
              backgroundColor: cardBorder(context),
            ),
          ),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text("${(_task.progress * 100).toStringAsFixed(0)}%",
                style: AppText.bodyMedium.copyWith( fontWeight: FontWeight.w600)),
            Text(_formatSpeed(_task.speedBytesPerSecond),
                style: AppText.bodySmall.copyWith( color: subTextColor(context))),
          ]),
        ]);
      case "extracting":
        return Row(children: [
          const SizedBox(width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Text("正在解压...", style: AppText.bodyMedium.copyWith( color: Colors.orange[300])),
        ]);
      case "done":
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.check_circle, color: Colors.green[300], size: 20),
            const SizedBox(width: 8),
            Text("下载并解压完成", style: AppText.body.copyWith( color: Colors.green[300])),
          ]),
          if (_task.outputPath != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: cardBg(context),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(_task.outputPath!,
                  style: AppText.label.copyWith( color: subTextColor(context), fontFamily: "monospace")),
            ),
          ],
        ]);
      case "paused":
        return Row(children: [
          Icon(Icons.pause_circle, color: Colors.orange[300], size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text("${(_task.progress * 100).toStringAsFixed(0)}% · 已暂停",
              style: AppText.bodyMedium.copyWith( color: Colors.orange[300]))),
        ]);
      case "failed":
        return Row(children: [
          Icon(Icons.error, color: Colors.red[300], size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(_task.error ?? "下载失败",
              style: AppText.bodySmall.copyWith( color: Colors.red[300]))),
        ]);
      default:
        return Row(children: [
          Icon(Icons.error, color: Colors.red[300], size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(_task.error ?? "下载失败",
              style: AppText.bodySmall.copyWith( color: Colors.red[300]))),
        ]);
    }
  }

}
