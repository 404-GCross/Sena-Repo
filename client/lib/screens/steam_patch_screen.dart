/// Steam patch injection screen — PC-only (Windows / Linux).

import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../providers/game_provider.dart";
import "../services/steam_service.dart";

class SteamPatchScreen extends StatefulWidget {
  const SteamPatchScreen({super.key});

  @override
  State<SteamPatchScreen> createState() => _SteamPatchScreenState();
}

class _SteamPatchScreenState extends State<SteamPatchScreen> {
  String? _commonDir;
  List<SteamGameInfo> _installedGames = [];
  List<PatchMatch> _matches = [];
  bool _scanning = false;
  bool _checking = false;
  String? _status;

  Future<void> _pickDirectory() async {
    final dir = await SteamService.pickSteamDir();
    if (dir != null && mounted) {
      setState(() {
        _commonDir = dir;
        _status = null;
      });
      _scanLocal();
    }
  }

  void _scanLocal() {
    if (_commonDir == null) return;
    setState(() => _scanning = true);

    final games = SteamService.scanInstalledGames(_commonDir!);

    setState(() {
      _installedGames = games;
      _scanning = false;
      _status = "本地扫描完成，找到 ${games.length} 个 Steam 游戏";
      _matches = [];
    });
  }

  Future<void> _checkPatches() async {
    if (_installedGames.isEmpty) return;
    final api = context.read<GameProvider>().api;

    setState(() {
      _checking = true;
      _status = null;
    });

    try {
      final matches = await SteamService.checkPatches(api, _installedGames);
      if (mounted) {
        setState(() {
          _matches = matches;
          _checking = false;
          final available = matches.where((m) => m.patchAvailable).length;
          _status = "检测完成: $available / ${matches.length} 个游戏有可用补丁";
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _checking = false;
          _status = "检测失败: $e";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Steam 补丁注入")),
      body: Column(
        children: [
          // ── Directory picker ──
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _commonDir ?? "未选择目录",
                    style: TextStyle(color: _commonDir != null ? null : Colors.grey),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _pickDirectory,
                  icon: const Icon(Icons.folder_open),
                  label: const Text("选择目录"),
                ),
              ],
            ),
          ),

          // ── Actions ──
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: _scanning || _commonDir == null ? null : _scanLocal,
                icon: const Icon(Icons.search),
                label: Text(_scanning ? "扫描中..." : "扫描本地游戏"),
              ),
              const SizedBox(width: 16),
              OutlinedButton.icon(
                onPressed: _checking || _installedGames.isEmpty ? null : _checkPatches,
                icon: const Icon(Icons.cloud_sync),
                label: Text(_checking ? "检测中..." : "检测补丁"),
              ),
            ],
          ),

          // ── Status ──
          if (_status != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Card(
                color: Theme.of(context).colorScheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_status!)),
                    ],
                  ),
                ),
              ),
            ),

          // ── Results ──
          Expanded(
            child: _matches.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.videogame_asset, size: 64,
                            color: Colors.grey[600]),
                        const SizedBox(height: 12),
                        Text(
                          _installedGames.isEmpty
                              ? "选择 Steam 库目录并开始扫描"
                              : "点击「检测补丁」查询可用补丁",
                          style: TextStyle(color: Colors.grey[500]),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _matches.length,
                    itemBuilder: (_, i) {
                      final match = _matches[i];
                      return ListTile(
                        leading: Icon(
                          match.patchAvailable
                              ? Icons.check_circle
                              : Icons.cancel_outlined,
                          color: match.patchAvailable ? Colors.green : Colors.grey,
                          size: 32,
                        ),
                        title: Text(match.gameName),
                        subtitle: Text(
                          match.patchAvailable
                              ? "补丁: ${match.patchFilename} (${_formatSize(match.patchSize)})"
                              : "暂无补丁",
                        ),
                        trailing: match.patchAvailable
                            ? FilledButton.tonalIcon(
                                onPressed: () {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text("补丁注入待实现: ${match.gameName}"),
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.download_for_offline, size: 18),
                                label: const Text("注入"),
                              )
                            : null,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    return "${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB";
  }
}
