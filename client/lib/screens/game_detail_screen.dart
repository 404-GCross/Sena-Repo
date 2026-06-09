/// Game detail screen: view game metadata, versions, tags.

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
  bool _isDeleting = false;

  ApiClient get _api => context.read<GameProvider>().api;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final game = await _api.getGame(widget.gameId);
      setState(() {
        _game = game;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("加载失败: $e")),
        );
      }
    }
  }

  Future<void> _showMoveDialog(BuildContext context, dynamic version) async {
    final ctrl = TextEditingController();
    final gameId = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("移动到哪个游戏？"),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: "目标游戏 ID", hintText: "输入游戏ID"),
          keyboardType: TextInputType.number,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
          FilledButton(onPressed: () {
            final id = int.tryParse(ctrl.text.trim());
            Navigator.pop(ctx, id);
          }, child: const Text("移动")),
        ],
      ),
    );
    if (gameId != null) {
      try {
        await http.post(Uri.parse("${_api.baseUrl}/api/games/${_game!.id}/versions/${version.id}/move?to_game_id=$gameId"));
        _load();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("已移动")));
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$e")));
      }
    }
  }

  Future<void> _showSearchDialog(BuildContext context) async {
    if (_game == null) return;
    final game = _game!;
    final searchCtrl = TextEditingController(text: game.name);
    String selectedSource = "vndb_kana";
    List<Map<String, dynamic>> candidates = [];
    bool searching = false;
    String? searchError;
    Map<String, dynamic>? selected;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDState) => AlertDialog(
          title: Text("搜索「${game.name}」"),
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: searchCtrl,
                      decoration: const InputDecoration(labelText: "搜索关键词", isDense: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DropdownButton<String>(
                    value: selectedSource,
                    underline: const SizedBox(),
                    items: const [
                      DropdownMenuItem(value: "vndb_kana", child: Text("VNDB")),
                      DropdownMenuItem(value: "bangumi", child: Text("Bangumi")),
                      DropdownMenuItem(value: "steam", child: Text("Steam")),
                      DropdownMenuItem(value: "dlsite", child: Text("DLsite")),
                      DropdownMenuItem(value: "muyue", child: Text("muyue")),
                    ],
                    onChanged: (v) => setDState(() => selectedSource = v!),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: const Icon(Icons.search, size: 18),
                    label: const Text("搜索"),
                    onPressed: () async {
                      setDState(() { searching = true; candidates = []; searchError = null; });
                      try {
                        final resp = await http.get(Uri.parse(
                          "${_api.baseUrl}/api/scrape/search?q=${Uri.encodeComponent(searchCtrl.text)}&source=$selectedSource"));
                        final data = jsonDecode(resp.body) as Map<String, dynamic>;
                        setDState(() {
                          candidates = (data["results"] as List).cast<Map<String, dynamic>>();
                          searching = false;
                        });
                      } catch (e) {
                        setDState(() { searchError = "$e"; searching = false; });
                      }
                    },
                  ),
                ]),
                const SizedBox(height: 12),
                if (searching) const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
                if (searchError != null) Text(searchError!, style: const TextStyle(color: Colors.red)),
                if (candidates.isNotEmpty)
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: candidates.length,
                      itemBuilder: (_, i) {
                        final c = candidates[i];
                        final isSelected = selected?["source_id"] == c["source_id"]
                            && selected?["source"] == selectedSource;
                        return ListTile(
                          selected: isSelected,
                          leading: c["cover_url"] != null && c["cover_url"].toString().isNotEmpty
                              ? ClipRRect(borderRadius: BorderRadius.circular(4),
                                  child: Image.network(c["cover_url"].toString(), width: 60, height: 85, fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => const Icon(Icons.image, size: 40)))
                              : const Icon(Icons.image, size: 40),
                          title: Text(c["title"] ?? "", style: const TextStyle(fontSize: 14)),
                          subtitle: Text(
                            [c["developer"], c["release_date"]].where((s) => s != null && s.toString().isNotEmpty).join(" · "),
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () {
                            setDState(() {
                              selected = {"source_id": c["source_id"], "source": selectedSource,
                                "cover_url": c["cover_url"], "developer": c["developer"],
                                "title": c["title"], "description": c["description"],
                                "release_date": c["release_date"]};
                            });
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
            FilledButton(
              onPressed: selected == null ? null : () => Navigator.pop(ctx, selected),
              child: const Text("应用选中"),
            ),
          ],
        ),
      ),
    );
    if (result != null && mounted) {
      try {
        final body = {
          "source_id": result["source_id"], "source": result["source"],
          "cover_url": result["cover_url"] ?? "", "developer": result["developer"] ?? "",
          "title": result["title"] ?? "", "description": result["description"] ?? "",
          "release_date": result["release_date"] ?? "",
        };
        await http.post(
          Uri.parse("${_api.baseUrl}/api/games/${game.id}/scrape-apply"),
          headers: {"Content-Type": "application/json"}, body: jsonEncode(body),
        );
        _load();
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("已应用")));
      } catch (e) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$e")));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text("加载中...")),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_game == null) {
      return Scaffold(
        appBar: AppBar(title: const Text("错误")),
        body: const Center(child: Text("游戏未找到")),
      );
    }

    final game = _game!;
    return Scaffold(
      appBar: AppBar(title: Text(game.name), actions: [
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: "搜索刮削",
          onPressed: () => _showSearchDialog(context),
        ),
        IconButton(
          icon: const Icon(Icons.edit),
          tooltip: "编辑",
          onPressed: () async {
            final changed = await Navigator.push<bool>(
              context, MaterialPageRoute(builder: (_) => GameEditScreen(game: game)));
            if (changed == true) _load();
          },
        ),
      ]),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Cover image
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: game.coverPath != null
                    ? Image.network(
                        "${_api.baseUrl}/api/files/covers${game.coverPath!}",
                        height: 300,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _placeholderCover(),
                      )
                    : _placeholderCover(),
              ),
            ),
            const SizedBox(height: 16),

            // Info
            if (game.companyName != null)
              Text("制作: ${game.companyName}", style: const TextStyle(fontSize: 14)),
            if (game.developer != null)
              Text("开发商: ${game.developer}", style: const TextStyle(fontSize: 14)),
            if (game.releaseDate != null)
              Text("发售日: ${game.releaseDate}", style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 8),

            // Tags
            if (game.tags.isNotEmpty) ...[
              Wrap(
                spacing: 6,
                children: game.tags.map((t) => Chip(label: Text(t.name))).toList(),
              ),
              const SizedBox(height: 16),
            ],

            // Versions
            const Text("版本", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...game.versions.map((v) => Card(
                  child: ListTile(
                    leading: _platformIcon(v.platform),
                    title: Text(v.filename),
                    subtitle: Text("${v.platform} · ${_formatSize(v.fileSize)}"),
                    trailing: IconButton(
                      icon: const Icon(Icons.download),
                      onPressed: () {
                        // TODO: Implement download
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text("下载功能待实现: ${v.filename}")),
                        );
                      },
                    ),
                  ),
                )),

            // Actions
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  onPressed: () => context.read<GameProvider>().scrapeGame(game.id),
                  icon: const Icon(Icons.image_search),
                  label: const Text("刮削封面"),
                ),
                ElevatedButton.icon(
                  onPressed: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text("确认删除"),
                        content: Text("确定删除「${game.name}」吗？\n不会删除本地文件。"),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("取消")),
                          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("删除")),
                        ],
                      ),
                    );
                    if (confirmed == true && mounted) {
                      await context.read<GameProvider>().deleteGame(game.id);
                      if (mounted) Navigator.pop(context);
                    }
                  },
                  icon: const Icon(Icons.delete),
                  label: const Text("删除"),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholderCover() {
    return Container(
      height: 300,
      width: 200,
      color: Colors.grey[800],
      child: const Center(child: Icon(Icons.image, size: 64, color: Colors.grey)),
    );
  }

  Widget _platformIcon(String platform) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.deepPurple.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(platform, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1024 * 1024 * 1024) return "${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB";
    return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB";
  }
}
