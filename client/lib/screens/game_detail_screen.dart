/// Game detail screen: view game metadata, versions, tags.

import "dart:convert";

import "package:flutter/material.dart";
import "package:file_picker/file_picker.dart";
import "package:provider/provider.dart";
import "package:http/http.dart" as http;

import "../models/game.dart";
import "../services/api_client.dart";
import "../providers/game_provider.dart";

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

  Future<void> _showEditDialog(BuildContext context) async {
    if (_game == null) return;
    final game = _game!;
    final nameCtrl = TextEditingController(text: game.name);
    final devCtrl = TextEditingController(text: game.developer ?? "");
    final descCtrl = TextEditingController(text: game.description ?? "");
    final dateCtrl = TextEditingController(text: game.releaseDate ?? "");
    final vndbCtrl = TextEditingController(text: game.vndbId ?? "");
    final steamCtrl = TextEditingController(text: game.steamId ?? "");
    final bgmCtrl = TextEditingController(text: game.bangumiId ?? "");
    final coverCtrl = TextEditingController(text: "");
    final bgCtrl = TextEditingController(text: game.bgPath ?? "");

    Future<void> pickImage(TextEditingController ctrl) async {
      final result = await FilePicker.platform.pickFiles(type: FileType.image);
      if (result != null && result.files.single.path != null) {
        ctrl.text = result.files.single.path!;
      }
    }

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("编辑「${game.name}」"),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: "游戏名")),
              const SizedBox(height: 8),
              TextField(controller: devCtrl, decoration: const InputDecoration(labelText: "开发商")),
              const SizedBox(height: 8),
              TextField(controller: dateCtrl, decoration: const InputDecoration(labelText: "发行日期")),
              const SizedBox(height: 8),
              TextField(controller: descCtrl, decoration: const InputDecoration(labelText: "简介"), maxLines: 3),
              const SizedBox(height: 12),
              const Text("刮削源 ID", style: TextStyle(fontWeight: FontWeight.bold)),
              TextField(controller: vndbCtrl, decoration: const InputDecoration(labelText: "VNDB ID")),
              TextField(controller: steamCtrl, decoration: const InputDecoration(labelText: "Steam App ID")),
              TextField(controller: bgmCtrl, decoration: const InputDecoration(labelText: "Bangumi ID")),
              const SizedBox(height: 12),
              const Text("封面与背景", style: TextStyle(fontWeight: FontWeight.bold)),
              Row(children: [
                Expanded(child: TextField(controller: coverCtrl, decoration: const InputDecoration(labelText: "封面 URL", isDense: true))),
                const SizedBox(width: 4),
                IconButton(icon: const Icon(Icons.folder_open), tooltip: "本地图片", onPressed: () => pickImage(coverCtrl)),
              ]),
              Row(children: [
                Expanded(child: TextField(controller: bgCtrl, decoration: const InputDecoration(labelText: "背景 URL", isDense: true))),
                const SizedBox(width: 4),
                IconButton(icon: const Icon(Icons.folder_open), tooltip: "本地图片", onPressed: () => pickImage(bgCtrl)),
              ]),
              const SizedBox(height: 12),
              if (game.versions.isNotEmpty) ...[
                const Text("版本管理", style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                ...game.versions.map((v) => ListTile(
                  dense: true,
                  title: Text(v.filename, style: const TextStyle(fontSize: 13)),
                  subtitle: Text(v.platform),
                  trailing: PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, size: 18),
                    onSelected: (action) async {
                      if (action == "move") {
                        await _showMoveDialog(context, v);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: "move", child: Text("移动到其他游戏...")),
                    ],
                  ),
                )),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("取消")),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("保存")),
        ],
      ),
    );

    if (saved == true) {
      try {
        final body = <String, dynamic>{
          "name": nameCtrl.text.trim(),
          "developer": devCtrl.text.trim(),
          "description": descCtrl.text.trim(),
          "release_date": dateCtrl.text.trim(),
          "vndb_id": vndbCtrl.text.trim(),
          "steam_id": steamCtrl.text.trim(),
          "bangumi_id": bgmCtrl.text.trim(),
        };
        final resp = await http.put(
          Uri.parse("${_api.baseUrl}/api/games/${game.id}"),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode(body),
        );
        // Update cover if provided
        if (coverCtrl.text.trim().isNotEmpty) {
          final covUrl = coverCtrl.text.trim();
          if (covUrl.startsWith("http")) {
            await http.post(Uri.parse("${_api.baseUrl}/api/games/${game.id}/cover?cover_url=${Uri.encodeComponent(covUrl)}"));
          }
        }
        // Update background if changed
        if (bgCtrl.text.trim().isNotEmpty && bgCtrl.text.trim() != (game.bgPath ?? "")) {
          final bgUrl = bgCtrl.text.trim();
          if (bgUrl.startsWith("http")) {
            await http.post(Uri.parse("${_api.baseUrl}/api/games/${game.id}/background?bg_url=${Uri.encodeComponent(bgUrl)}"));
          }
        }
        if (resp.statusCode == 200) {
          _load();
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("已保存")));
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$e")));
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
          icon: const Icon(Icons.edit),
          tooltip: "编辑",
          onPressed: () => _showEditDialog(context),
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
              Text("制作: ${game.companyName}", style: const TextStyle(fontSize: 16)),
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
            const Text("版本", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
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
