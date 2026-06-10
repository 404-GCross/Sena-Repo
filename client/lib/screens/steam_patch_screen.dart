/// Steam patch injection screen — PC-only (Windows / Linux).

import "package:flutter/material.dart";
import "package:provider/provider.dart";
import "package:shared_preferences/shared_preferences.dart";

import "package:font_awesome_flutter/font_awesome_flutter.dart";

import "../providers/game_provider.dart";
import "../utils/theme_utils.dart";
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

  @override
  void initState() {
    super.initState();
    _loadSavedDir();
  }

  Future<void> _loadSavedDir() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString("steam_common_dir");
    if (saved != null && saved.isNotEmpty && mounted) {
      setState(() => _commonDir = saved);
    }
  }

  Future<void> _pickDirectory() async {
    final dir = await SteamService.pickSteamDir();
    if (dir != null && mounted) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("steam_common_dir", dir);
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
    final hasDir = _commonDir != null;
    final theme = Theme.of(context);

    return Scaffold(
      body: Column(children: [
        // ── Header banner ──
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
            border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.06))),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              FaIcon(FontAwesomeIcons.steam, size: 24, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Text("Steam 补丁注入", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
            ]),
            const SizedBox(height: 8),
            Text("选择 Steam 库的 steamapps/common 目录，自动匹配库内游戏的汉化补丁",
                style: TextStyle(fontSize: 14, color: Colors.grey[400])),
          ]),
        ),

        // ── Directory section ──
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: hasDir ? Colors.blue.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  hasDir ? Icons.folder : Icons.folder_open,
                  size: 24,
                  color: hasDir ? Colors.blue[300] : Colors.grey[500],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text("Steam 库目录", style: TextStyle(fontSize: 13, color: Colors.grey[500])),
                  const SizedBox(height: 2),
                  Text(
                    hasDir ? _commonDir! : "未选择",
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: hasDir ? null : Colors.grey[600]),
                  ),
                ]),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: _pickDirectory,
                icon: const Icon(Icons.folder_open, size: 18),
                label: Text(hasDir ? "更换" : "选择目录"),
              ),
            ]),
          ),
        ),

        // ── Action buttons ──
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(children: [
            Expanded(
              child: _actionBtn(
                icon: _scanning ? Icons.hourglass_empty : Icons.search,
                label: _scanning ? "扫描中..." : "扫描本地游戏",
                onPressed: _scanning || !hasDir ? null : _scanLocal,
                primary: true,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _actionBtn(
                icon: _checking ? Icons.hourglass_empty : Icons.cloud_sync,
                label: _checking ? "检测中..." : "检测补丁",
                onPressed: _checking || _installedGames.isEmpty ? null : _checkPatches,
                primary: false,
              ),
            ),
          ]),
        ),

        // ── Status banner ──
        if (_status != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.blue.withValues(alpha: 0.2)),
              ),
              child: Row(children: [
                Icon(Icons.info_outline, size: 18, color: Colors.blue[300]),
                const SizedBox(width: 8),
                Expanded(child: Text(_status!, style: TextStyle(fontSize: 13, color: Colors.blue[200]))),
              ]),
            ),
          ),

        const SizedBox(height: 8),

        // ── Results ──
        Expanded(
          child: _matches.isEmpty
              ? _emptyState()
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: _matches.length,
                  itemBuilder: (_, i) => _matchCard(_matches[i], i == _matches.length - 1),
                ),
        ),
      ]),
    );
  }

  Widget _actionBtn({required IconData icon, required String label, required VoidCallback? onPressed, required bool primary}) {
    if (primary) {
      return FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label, style: const TextStyle(fontSize: 14)),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    }
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontSize: 14)),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Widget _emptyState() => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.videogame_asset_outlined, size: 56, color: Colors.grey[600]),
      ),
      const SizedBox(height: 16),
      Text(
        _installedGames.isEmpty ? "选择 Steam 库目录并开始扫描" : "点击「检测补丁」查询可用补丁",
        style: TextStyle(fontSize: 15, color: Colors.grey[500]),
      ),
      const SizedBox(height: 4),
      Text(
        "支持自动匹配库内游戏的汉化/修正补丁",
        style: TextStyle(fontSize: 13, color: Colors.grey[600]),
      ),
    ]),
  );

  Widget _matchCard(PatchMatch match, bool isLast) {
    final available = match.patchAvailable;
    return Container(
      margin: EdgeInsets.only(bottom: isLast ? 20 : 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          // Status icon
          Container(
            width: 42, height: 42,
            decoration: BoxDecoration(
              color: available ? Colors.green.withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              available ? Icons.check_circle : Icons.block,
              size: 22,
              color: available ? Colors.green[300] : Colors.grey[600],
            ),
          ),
          const SizedBox(width: 14),
          // Info
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(match.gameName, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 3),
              Text(
                available ? "${match.patchFilename}  ·  ${_formatSize(match.patchSize)}" : "暂无可用补丁",
                style: TextStyle(fontSize: 13, color: Colors.grey[500]),
              ),
            ]),
          ),
          // Action
          if (available)
            FilledButton.tonalIcon(
              onPressed: () {
                showDialog(context: context, builder: (c) => AlertDialog(
                  icon: Icon(Icons.download_for_offline, size: 32, color: Theme.of(context).colorScheme.primary),
                  title: const Text("补丁注入"),
                  content: Text("即将注入补丁: ${match.gameName}\n\n此功能开发中，敬请期待。"),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c), child: const Text("关闭")),
                    FilledButton(onPressed: () => Navigator.pop(c), child: const Text("确定")),
                  ],
                ));
              },
              icon: const Icon(Icons.download, size: 17),
              label: const Text("注入"),
            ),
        ]),
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    return "${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB";
  }
}
