/// Game detail screen: view game metadata, versions, tags.

import "package:flutter/material.dart";
import "package:provider/provider.dart";

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
      appBar: AppBar(title: Text(game.name)),
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
