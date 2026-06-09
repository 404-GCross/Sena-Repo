/// Game detail screen — Playnite-style layout with cover on right, metadata grid on left.

import "dart:convert";

import "package:flutter/material.dart";
import "package:provider/provider.dart";
import "package:http/http.dart" as http;

import "../models/game.dart";
import "../services/api_client.dart";
import "../providers/game_provider.dart";
import "game_edit_screen.dart";

class GameDetailScreen extends StatefulWidget {
  final int gameId;
  const GameDetailScreen({super.key, required this.gameId});

  @override
  State<GameDetailScreen> createState() => _GameDetailScreenState();
}

class _GameDetailScreenState extends State<GameDetailScreen> {
  GameDetail? _game;
  bool _isLoading = true;

  ApiClient get _api => context.read<GameProvider>().api;
  String get _baseUrl => _api.baseUrl;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final game = await _api.getGame(widget.gameId);
      if (mounted) setState(() { _game = game; _isLoading = false; });
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
    final hasBg = game.bgPath != null && game.bgPath!.isNotEmpty;

    return Scaffold(
      extendBodyBehindAppBar: hasBg,
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: hasBg ? Colors.transparent : null,
        forceMaterialTransparency: hasBg,
        title: Text(game.name),
        actions: [
          IconButton(icon: const Icon(Icons.search), tooltip: "搜索元数据", onPressed: () => _showSearchDialog(context, game)),
          IconButton(icon: const Icon(Icons.edit), tooltip: "编辑",
            onPressed: () async {
              final changed = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => GameEditScreen(game: game)));
              if (changed == true) _load();
            }),
        ],
      ),
      body: Stack(children: [
        // Background banner (Playnite style)
        if (hasBg)
          Positioned(
            top: 0, left: 0, right: 0, height: 400,
            child: ShaderMask(
              shaderCallback: (rect) => const LinearGradient(
                begin: Alignment.topCenter, end: Alignment.bottomCenter,
                colors: [Color(0x88000000), Color(0x44000000), Colors.transparent],
                stops: [0.0, 0.3, 1.0],
              ).createShader(rect),
              blendMode: BlendMode.dstIn,
              child: Image.network(
                "$_baseUrl/api/files/backgrounds${game.bgPath!}",
                fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          ),
        SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(children: [
              // ── Header: cover right, name left ──
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(game.name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                      if (game.companyName != null) ...[
                        const SizedBox(height: 4),
                        Text(game.companyName!, style: TextStyle(fontSize: 15, color: Colors.grey[400])),
                      ],
                      const SizedBox(height: 12),
                      Row(children: [
                        _sourceBadge("VNDB", game.vndbId),
                        _sourceBadge("Steam", game.steamId),
                        _sourceBadge("Bangumi", game.bangumiId),
                      ]),
                    ]),
                  ),
                  const SizedBox(width: 20),
                  ClipRRect(borderRadius: BorderRadius.circular(10),
                    child: SizedBox(width: 200, height: 280,
                      child: hasCover
                          ? Image.network("$_baseUrl/api/files/covers${game.coverPath!}",
                              fit: BoxFit.cover, errorBuilder: (_, __, ___) => _coverPlaceholder())
                          : _coverPlaceholder())),
                ]),
              ),

              // ── Body: left metadata + right description ──
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // Left: metadata grid + versions
                  Expanded(
                    flex: 5,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      _section("详细信息"),
                      _infoRow("开发商", game.developer),
                      _infoRow("发售日", game.releaseDate),
                      const SizedBox(height: 12),
                      _section("版本"),
                      if (game.versions.isEmpty)
                        Text("无", style: TextStyle(color: Colors.grey[500], fontSize: 13))
                      else
                        ...game.versions.map((v) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.04), borderRadius: BorderRadius.circular(6)),
                            child: Row(children: [
                              Expanded(child: Text(v.filename, style: const TextStyle(fontSize: 13))),
                              const SizedBox(width: 8),
                              Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(4)),
                                child: Text(v.platform, style: const TextStyle(fontSize: 11))),
                              const SizedBox(width: 4),
                              Text(_formatSize(v.fileSize), style: TextStyle(fontSize: 11, color: Colors.grey[500])),
                            ]),
                          ),
                        )),
                      const SizedBox(height: 12),
                      if (game.tags.isNotEmpty) ...[
                        _section("标签"),
                        Wrap(spacing: 6, children: game.tags.map((t) => Chip(
                          label: Text(t.name, style: const TextStyle(fontSize: 12)),
                          visualDensity: VisualDensity.compact,
                        )).toList()),
                      ],
                    ]),
                  ),
                  const SizedBox(width: 24),
                  // Right: description
                  Expanded(
                    flex: 4,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      _section("简介"),
                      Text(game.description?.isNotEmpty == true ? game.description! : "暂无简介",
                          style: TextStyle(fontSize: 13, color: game.description?.isNotEmpty == true ? null : Colors.grey[500], height: 1.5)),
                    ]),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    ]),
    );
  }

  Widget _section(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 6, top: 4),
    child: Text(t, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white70)),
  );

  Widget _infoRow(String label, String? value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 80, child: Padding(padding: const EdgeInsets.only(top: 2),
          child: Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[500])))),
        Expanded(child: Text(value?.isNotEmpty == true ? value! : "—",
            style: TextStyle(fontSize: 13, color: value?.isNotEmpty == true ? null : Colors.grey[700]))),
      ]),
    );
  }

  Widget _sourceBadge(String label, String? id) {
    final active = id != null && id.isNotEmpty;
    return Padding(padding: const EdgeInsets.only(right: 6),
      child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: active ? Colors.green.withValues(alpha: 0.2) : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: active ? Colors.green.withValues(alpha: 0.4) : Colors.white24)),
        child: Text(label, style: TextStyle(fontSize: 11, color: active ? Colors.green : Colors.grey))));
  }

  Widget _coverPlaceholder() => Container(
    color: Colors.grey[850], width: 200, height: 280,
    child: Center(child: Icon(Icons.image, size: 64, color: Colors.grey[700])),
  );

  String _formatSize(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1048576) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1073741824) return "${(bytes / 1048576).toStringAsFixed(1)} MB";
    return "${(bytes / 1073741824).toStringAsFixed(1)} GB";
  }

  // ── Search Dialog ──

  Future<void> _showSearchDialog(BuildContext context, game) async {
    final sources = {"vndb_kana": "VNDB Kana v2", "bangumi": "Bangumi", "steam": "Steam", "dlsite": "DLsite"};
    final srcToId = {"vndb_kana": game.vndbId, "bangumi": game.bangumiId, "steam": game.steamId};

    final src = await showDialog<String>(
      context: context, builder: (ctx) => AlertDialog(
        title: const Text("搜索元数据"), content: Column(mainAxisSize: MainAxisSize.min,
          children: sources.entries.map((e) => ListTile(title: Text(e.value), trailing: const Icon(Icons.chevron_right), onTap: () => Navigator.pop(ctx, e.key))).toList()),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消"))],
      ),
    );
    if (src == null || !mounted) return;

    final hasId = srcToId[src] != null && srcToId[src]!.isNotEmpty;
    final ctrl = TextEditingController(text: hasId ? srcToId[src]! : game.name);
    final picked = await showDialog<Map<String, dynamic>>(
      context: context, builder: (ctx) {
        var results = <Map<String, dynamic>>[];
        var searching = false;
        return StatefulBuilder(builder: (ctx, setD) => AlertDialog(
          title: Text("${sources[src]} — 搜索"),
          content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(child: TextField(controller: ctrl, autofocus: true,
                decoration: InputDecoration(labelText: hasId ? "已有 ID" : "名称/ID", hintText: hasId ? "按 ID 搜索" : "输入名称或ID", isDense: true),
                onSubmitted: (v) async { setD(() { searching = true; results = []; });
                  try { final r = await http.get(Uri.parse("$_baseUrl/api/scrape/search?q=${Uri.encodeComponent(v)}&source=$src"));
                    results = ((jsonDecode(r.body) as Map)["results"] as List).cast<Map<String, dynamic>>(); } catch (_) {}
                  setD(() => searching = false); })),
              const SizedBox(width: 8),
              IconButton.filled(icon: const Icon(Icons.search, size: 18), onPressed: () async {
                setD(() { searching = true; results = []; });
                try { final r = await http.get(Uri.parse("$_baseUrl/api/scrape/search?q=${Uri.encodeComponent(ctrl.text)}&source=$src"));
                  results = ((jsonDecode(r.body) as Map)["results"] as List).cast<Map<String, dynamic>>(); } catch (_) {}
                setD(() => searching = false); }),
            ]),
            const SizedBox(height: 8),
            if (searching) const Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()),
            if (!searching && results.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text("无结果", style: TextStyle(color: Colors.grey))),
            if (results.isNotEmpty) SizedBox(height: 350, child: ListView.builder(itemCount: results.length, itemBuilder: (_, i) {
              final r = results[i]; final cov = (r["cover_url"] ?? "").toString();
              return ListTile(
                leading: cov.isNotEmpty ? ClipRRect(borderRadius: BorderRadius.circular(4), child: Image.network(cov, width: 50, height: 70, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _noCover())) : _noCover(),
                title: Text(r["title"] ?? "", style: const TextStyle(fontSize: 13)),
                subtitle: Text("${r["developer"] ?? ""} · ${r["release_date"] ?? ""}", maxLines: 2, style: const TextStyle(fontSize: 11)),
                onTap: () => Navigator.pop(ctx, r),
              );
            })),
          ])),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消"))],
        ));
      },
    );
    if (picked == null || !mounted) return;

    try { await http.post(Uri.parse("$_baseUrl/api/games/${game.id}/scrape-apply"), headers: {"Content-Type": "application/json"}, body: jsonEncode({"source_id": picked["source_id"] ?? "", "source": src, "cover_url": picked["cover_url"] ?? "", "title": picked["title"] ?? "", "developer": picked["developer"] ?? "", "description": picked["description"] ?? "", "release_date": picked["release_date"] ?? ""}));
      _load(); _showDialog(context, "完成", "元数据已应用"); } catch (e) { _showDialog(context, "错误", "$e"); }
  }

  void _showDialog(BuildContext ctx, String title, String msg) {
    showDialog(context: ctx, builder: (c) => AlertDialog(title: Text(title), content: Text(msg), actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text("确定"))]));
  }

  Widget _noCover() => const Icon(Icons.image, size: 36, color: Colors.grey);
}
