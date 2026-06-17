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
  List<PatchMatch> _matches = [];
  bool _loading = false;
  String? _status;
  bool _showNoPatch = false;
  final Map<String, Map<String, dynamic>> _injectState = {}; // appId → {stage, progress, received, total, speed}

  @override
  void initState() {
    super.initState();
    _loadSavedDir();
  }

  Future<void> _loadSavedDir() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString("steamapps_dir") ?? prefs.getString("steam_common_dir");
    if (saved != null && saved.isNotEmpty && mounted) {
      setState(() => _commonDir = saved);
      _scanAndCheck();
    }
  }

  Future<void> _pickDirectory() async {
    final dir = await SteamService.pickSteamDir();
    if (dir != null && mounted) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("steamapps_dir", dir);
      setState(() {
        _commonDir = dir;
        _matches = [];
        _status = null;
      });
      _scanAndCheck();
    }
  }

  Future<void> _scanAndCheck() async {
    if (_commonDir == null) return;

    setState(() {
      _loading = true;
      _status = "正在扫描本地 Steam 库...";
      _matches = [];
    });

    // Phase 1: scan local
    final games = SteamService.scanInstalledGames(_commonDir!);
    if (!mounted) return;

    setState(() => _status = "扫描到 ${games.length} 个游戏，正在匹配补丁...");

    // Phase 2: check patches
    try {
      final api = context.read<GameProvider>().api;
      final matches = await SteamService.checkPatches(api, games);
      if (!mounted) return;

      // Sort: available first, then by name
      matches.sort((a, b) {
        if (a.patchAvailable != b.patchAvailable) {
          return a.patchAvailable ? -1 : 1;
        }
        return a.gameName.compareTo(b.gameName);
      });

      final available = matches.where((m) => m.patchAvailable).length;

      setState(() {
        _matches = matches;
        _loading = false;
        _status = available > 0
            ? "扫描完成 — ${matches.length} 个游戏，$available 个有可用补丁"
            : "扫描完成 — ${matches.length} 个游戏，暂无可用补丁";
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _status = "补丁检测失败: $e";
        _matches = games
            .map((g) => PatchMatch(
                  appId: g.appId,
                  gameName: g.name,
                  installDir: g.installDir,
                  patchAvailable: false,
                ))
            .toList();
      });
    }
  }

  List<PatchMatch> get _availablePatches =>
      _matches.where((m) => m.patchAvailable).toList();
  List<PatchMatch> get _noPatchGames =>
      _matches.where((m) => !m.patchAvailable).toList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final available = _availablePatches;

    return Scaffold(
      body: Column(children: [
        // ── Header ──
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.25),
            border: Border(bottom: BorderSide(color: cardBorder(context))),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              FaIcon(FontAwesomeIcons.steam, size: 24, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Text("Steam 补丁管理",
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
            ]),
            const SizedBox(height: 6),
            Text("自动扫描 Steam 库内游戏，匹配服务器上的汉化补丁",
                style: AppText.bodyMedium.copyWith(color: subTextColor(context))),
          ]),
        ),

        // ── Directory selector ──
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: _buildDirRow(),
        ),

        // ── Status ──
        if (_status != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: _buildStatusBar(),
          ),

        const SizedBox(height: 8),

        // ── Results ──
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _matches.isEmpty
                  ? _emptyState()
                  : _buildResults(),
        ),
      ]),
    );
  }

  // ── Directory row ──

  Widget _buildDirRow() {
    final hasDir = _commonDir != null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cardBg(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cardBorder(context)),
      ),
      child: Row(children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: hasDir ? Colors.blue.withValues(alpha: 0.12) : cardBg(context),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(Icons.folder, size: 22, color: hasDir ? Colors.blue[300] : Colors.grey[500]),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(hasDir ? _commonDir! : "未选择 Steam 库目录",
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: AppText.bodySmall.copyWith(
                    color: hasDir ? null : Colors.grey[500], fontWeight: hasDir ? FontWeight.w500 : null)),
          ]),
        ),
        const SizedBox(width: 8),
        _miniBtn(Icons.folder_open, hasDir ? "更换" : "选择", _pickDirectory),
        if (hasDir) ...[
          const SizedBox(width: 8),
          _miniBtn(Icons.refresh, "刷新", _loading ? null : _scanAndCheck),
        ],
      ]),
    );
  }

  Widget _miniBtn(IconData icon, String label, VoidCallback? onTap) {
    return Material(
      color: cardBorder(context),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15, color: onTap == null ? Colors.grey : null),
            const SizedBox(width: 5),
            Text(label, style: AppText.bodySmall.copyWith(fontWeight: FontWeight.w500)),
          ]),
        ),
      ),
    );
  }

  // ── Status bar ──

  Widget _buildStatusBar() {
    final available = _availablePatches.length;
    final color = available > 0 ? Colors.green : Colors.grey;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.15)),
      ),
      child: Row(children: [
        Icon(
          available > 0 ? Icons.check_circle_outline : Icons.info_outline,
          size: 18, color: color[300],
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(_status!,
              style: AppText.bodySmall.copyWith(color: color[200])),
        ),
      ]),
    );
  }

  // ── Results ──

  Widget _buildResults() {
    final available = _availablePatches;
    final noPatch = _noPatchGames;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      children: [
        // Available patches section
        if (available.isNotEmpty) ...[
          _sectionHeader("可注入 (${available.length})", Icons.download, Colors.green),
          ...available.map((m) => _gameCard(m)),
        ],

        // No-patch section (collapsible)
        if (noPatch.isNotEmpty) ...[
          const SizedBox(height: 8),
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _showNoPatch = !_showNoPatch),
            child: _sectionHeader(
              "暂无补丁 (${noPatch.length})",
              _showNoPatch ? Icons.expand_less : Icons.expand_more,
              Colors.grey,
            ),
          ),
          if (_showNoPatch) ...noPatch.map((m) => _simpleCard(m)),
        ],
      ],
    );
  }

  Widget _sectionHeader(String title, IconData icon, MaterialColor color) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Row(children: [
        Icon(icon, size: 16, color: color[300]),
        const SizedBox(width: 8),
        Text(title, style: AppText.bodySmall.copyWith(color: color[300], fontWeight: FontWeight.w600)),
      ]),
    );
  }

  // ── Game card with patch available ──

  Widget _gameCard(PatchMatch m) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: cardBg(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cardBorder(context)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Game name + inject button
          Row(children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.download, size: 18, color: Colors.green[300]),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(m.gameName, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text("AppID ${m.appId}  ·  ${m.installDir}",
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: AppText.bodySmall.copyWith(color: hintColor(context), fontSize: 11)),
              ]),
            ),
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.edit, size: 16),
              onPressed: () => _showEditDialog(m),
              tooltip: "编辑补丁参数",
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.all(6),
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 4),
            _buildInjectButton(m),
          ]),
          // Progress or patch info
          _buildInjectProgress(m),
          const SizedBox(height: 6),
        ]),
      ),
    );
  }

  // ── Simple card for no-patch games ──

  Widget _simpleCard(PatchMatch m) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cardBg(context),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        Icon(Icons.block, size: 14, color: Colors.grey[600]),
        const SizedBox(width: 10),
        Expanded(
          child: Text(m.gameName, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: AppText.bodySmall.copyWith(color: hintColor(context))),
        ),
        Text("AppID ${m.appId}",
            style: AppText.bodySmall.copyWith(color: Colors.grey[600], fontSize: 11)),
      ]),
    );
  }

  // ── Inject button / progress ──

  Widget _buildInjectButton(PatchMatch m) {
    final state = _injectState[m.appId];
    if (state != null && state["stage"] != "error") return const SizedBox.shrink();

    final hasError = state != null && state["stage"] == "error";
    return FilledButton.tonalIcon(
      onPressed: () => _startInjection(m),
      icon: Icon(hasError ? Icons.refresh : Icons.auto_fix_high, size: 16),
      label: Text(hasError ? "重试" : "注入", style: AppText.bodySmall.copyWith(fontWeight: FontWeight.w600)),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        minimumSize: Size.zero,
        backgroundColor: hasError ? Colors.red.withValues(alpha: 0.15) : null,
      ),
    );
  }

  Widget _buildInjectProgress(PatchMatch m) {
    final state = _injectState[m.appId];
    if (state == null) {
      // Default: show patch info
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.green.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(children: [
          Icon(Icons.archive, size: 14, color: Colors.green[300]),
          const SizedBox(width: 6),
          Row(mainAxisSize: MainAxisSize.min, children: [
            _typeBadge(m.type),
            const SizedBox(width: 6),
            Text(m.label ?? m.patchFilename ?? "补丁文件",
                style: AppText.bodySmall.copyWith(color: Colors.green[200])),
          ]),
          const Spacer(),
          Text(_formatSize(m.patchSize),
              style: AppText.bodySmall.copyWith(color: Colors.green[200], fontWeight: FontWeight.w600)),
        ]),
      );
    }

    if (state["stage"] == "done") {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.green.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(children: [
          Icon(Icons.check_circle, size: 14, color: Colors.green[300]),
          const SizedBox(width: 6),
          Text("注入完成", style: AppText.bodySmall.copyWith(color: Colors.green[300])),
        ]),
      );
    }

    if (state["stage"] == "error") {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(children: [
          Icon(Icons.error_outline, size: 14, color: Colors.red[300]),
          const SizedBox(width: 6),
          Expanded(child: Text(state["error"]?.toString() ?? "注入失败",
              maxLines: 2, overflow: TextOverflow.ellipsis,
              style: AppText.bodySmall.copyWith(color: Colors.red[200]))),
        ]),
      );
    }

    // Downloading or extracting
    final progress = (state["progress"] as num?)?.toDouble() ?? 0.0;
    final received = (state["received"] as int?) ?? 0;
    final total = (state["total"] as int?) ?? 0;
    final speed = (state["speed"] as int?) ?? 0;
    final isExtracting = state["stage"] == "extracting";

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 4),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: isExtracting ? null : (progress > 0 ? progress : null),
          minHeight: 6,
          backgroundColor: cardBorder(context),
        ),
      ),
      const SizedBox(height: 6),
      Row(children: [
        Text(
          isExtracting ? "解压中..." : "${(progress * 100).toStringAsFixed(0)}%",
          style: AppText.bodySmall.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 12),
        if (!isExtracting) ...[
          Text("${_formatSize(received)} / ${_formatSize(total)}",
              style: AppText.bodySmall.copyWith(color: hintColor(context))),
          const Spacer(),
          if (speed > 0)
            Text("${_formatSize(speed)}/s",
                style: AppText.bodySmall.copyWith(color: hintColor(context))),
        ],
      ]),
    ]);
  }

  Future<void> _showEditDialog(PatchMatch m) async {
    final patchCtrl = TextEditingController(text: m.patchDir ?? "");
    final targetCtrl = TextEditingController(text: m.targetDir ?? "");
    final labelCtrl = TextEditingController(text: m.label ?? "");
    String ptype = m.type ?? "misc";

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("编辑补丁 — ${m.gameName}"),
        content: SizedBox(width: 380, child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: patchCtrl, decoration: const InputDecoration(labelText: "补丁源目录 (patch_dir)", hintText: "解压后取此子目录", isDense: true)),
            const SizedBox(height: 10),
            TextField(controller: targetCtrl, decoration: const InputDecoration(labelText: "目标目录 (target_dir)", hintText: "复制到游戏目录下的子路径", isDense: true)),
            const SizedBox(height: 10),
            TextField(controller: labelCtrl, decoration: const InputDecoration(labelText: "显示名称 (label)", hintText: "界面显示的补丁名", isDense: true)),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              value: ptype,
              items: _typeLabels.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
              onChanged: (v) => ptype = v ?? "misc",
              decoration: const InputDecoration(labelText: "补丁类型", isDense: true),
            ),
          ],
        )),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
          FilledButton(onPressed: () {
            Navigator.pop(ctx, {
              "patch_dir": patchCtrl.text.trim(),
              "target_dir": targetCtrl.text.trim(),
              "label": labelCtrl.text.trim(),
              "type": ptype,
            });
          }, child: const Text("保存")),
        ],
      ),
    );

    if (result == null || !mounted) return;
    try {
      final api = context.read<GameProvider>().api;
      await SteamService.updatePatch(
        api: api, appId: m.appId,
        patchDir: result["patch_dir"] ?? "",
        targetDir: result["target_dir"] ?? "",
        label: result["label"] ?? "",
        type: result["type"] ?? "misc",
      );
      // Refresh the list to show updated values
      _scanAndCheck();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("保存失败: $e")));
      }
    }
  }

  static final _typeLabels = {
    "translation": "汉化",
    "voice": "音声",
    "story": "剧情",
    "extra": "额外",
    "misc": "其他",
  };

  static final _typeColors = {
    "translation": Colors.blue,
    "voice": Colors.purple,
    "story": Colors.orange,
    "extra": Colors.teal,
    "misc": Colors.grey,
  };

  Widget _typeBadge(String? type) {
    final t = type ?? "misc";
    final label = _typeLabels[t] ?? "其他";
    final color = _typeColors[t] ?? Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color[300])),
    );
  }

  // ── Inject logic ──

  Future<void> _startInjection(PatchMatch m) async {
    final api = context.read<GameProvider>().api;
    setState(() => _injectState[m.appId] = {"stage": "downloading", "progress": 0.0, "received": 0, "total": 0, "speed": 0});

    try {
      final stream = SteamService.injectPatch(
        downloadUrl: "${api.baseUrl}/api/steam/patches/${m.appId}/download",
        installDir: m.installDir,
        api: api,
        patchDir: m.patchDir,
        targetDir: m.targetDir,
      );
      await for (final update in stream) {
        if (!mounted) return;
        if (update.containsKey("error")) {
          setState(() => _injectState[m.appId] = {"stage": "error", "error": update["error"]});
          return;
        }
        setState(() => _injectState[m.appId] = update);
        if (update["stage"] == "done") {
          setState(() => _injectState[m.appId] = {"stage": "done"});
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _injectState[m.appId] = {"stage": "error", "error": "$e"});
      }
    }
  }

  // ── Empty state ──

  Widget _emptyState() => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: cardBg(context),
          shape: BoxShape.circle,
        ),
        child: FaIcon(FontAwesomeIcons.steam, size: 48, color: Colors.grey[600]),
      ),
      const SizedBox(height: 20),
      Text("选择 Steam 库目录开始扫描", style: AppText.body.copyWith(color: hintColor(context))),
      const SizedBox(height: 6),
      Text("自动匹配 steamapps 内游戏的汉化补丁",
          style: AppText.bodySmall.copyWith(color: Colors.grey[600])),
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: _pickDirectory,
        icon: const Icon(Icons.folder_open, size: 18),
        label: const Text("选择 steamapps 目录"),
      ),
    ]),
  );

  String _formatSize(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    return "${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB";
  }
}
