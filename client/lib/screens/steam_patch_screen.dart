/// Steam patch injection screen — PC-only (Windows / Linux).

import "dart:async";

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
  int _tabIndex = 0; // 0=客户端, 1=服务端

  // Client tab
  String? _commonDir;
  List<PatchMatch> _matches = [];
  bool _loading = false;
  String? _status;
  bool _showNoPatch = false;
  final Map<String, String> _injectState = {}; // appId → status

  // Server tab
  List<Map<String, dynamic>> _serverPatches = [];
  bool _serverLoading = false;
  String? _serverStatus;

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
    }
  }

  Future<void> _pickDirectory() async {
    final dir = await SteamService.pickSteamDir();
    if (dir != null && mounted) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("steamapps_dir", dir);
      setState(() { _commonDir = dir; _matches = []; _status = null; });
      _scanAndCheck();
    }
  }

  Future<void> _scanAndCheck() async {
    if (_commonDir == null) return;
    setState(() { _loading = true; _status = "正在扫描本地 Steam 库..."; _matches = []; });
    final games = SteamService.scanInstalledGames(_commonDir!);
    if (!mounted) return;
    setState(() => _status = "扫描到 ${games.length} 个游戏，正在匹配补丁...");
    try {
      final api = context.read<GameProvider>().api;
      final matches = await SteamService.checkPatches(api, games);
      if (!mounted) return;
      matches.sort((a, b) {
        if (a.patchAvailable != b.patchAvailable) return a.patchAvailable ? -1 : 1;
        return a.gameName.compareTo(b.gameName);
      });
      final available = matches.where((m) => m.patchAvailable).length;
      setState(() {
        _matches = matches; _loading = false;
        _status = available > 0 ? "扫描完成 — ${matches.length} 个游戏，$available 个有可用补丁" : "扫描完成 — ${matches.length} 个游戏，暂无可用补丁";
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false; _status = "补丁检测失败: $e";
        _matches = games.map((g) => PatchMatch(appId: g.appId, gameName: g.name, installDir: g.installDir, patchAvailable: false)).toList();
      });
    }
  }

  List<PatchMatch> get _availablePatches => _matches.where((m) => m.patchAvailable).toList();
  List<PatchMatch> get _noPatchGames => _matches.where((m) => !m.patchAvailable).toList();

  // ── Server tab ──

  Future<void> _loadServerPatches() async {
    setState(() { _serverLoading = true; _serverStatus = null; });
    try {
      final api = context.read<GameProvider>().api;
      final data = await SteamService.listPatches(api);
      final patches = (data["patches"] as List).cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() { _serverPatches = patches; _serverLoading = false; _serverStatus = "共 ${patches.length} 个补丁索引"; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _serverLoading = false; _serverStatus = "加载失败: $e"; });
    }
  }

  Future<void> _scanServerPatches() async {
    setState(() { _serverLoading = true; _serverStatus = "正在扫描..."; });
    try {
      final api = context.read<GameProvider>().api;
      final result = await SteamService.scanPatches(api);
      final scanned = (result["scanned"] as int?) ?? 0;
      await _loadServerPatches();
      if (!mounted) return;
      if (_commonDir != null && _commonDir!.isNotEmpty) {
        setState(() => _tabIndex = 0);
        _scanAndCheck();
        _showMsg("扫描完成，找到 $scanned 个文件。正在匹配本地 Steam 库...");
      } else {
        _showMsg("扫描完成，找到 $scanned 个补丁文件");
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _serverLoading = false; _serverStatus = "扫描失败: $e"; });
    }
  }

  void _showMsg(String msg, {bool error = false}) {
    if (!mounted) return;
    showDialog(context: context, builder: (ctx) => AlertDialog(
      icon: Icon(error ? Icons.error_outline : Icons.check_circle, size: 28, color: error ? Colors.red[300] : Colors.green[300]),
      content: Text(msg, style: const TextStyle(fontSize: 14)),
      actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text("确定"))],
    ));
  }

  // ── Inject ──

  Future<void> _startInjection(PatchMatch m) async {
    final api = context.read<GameProvider>().api;
    setState(() => _injectState[m.appId] = "0|0|0|0"); // progress|received|total|speed
    try {
      final result = await SteamService.injectPatch(
        appId: m.appId,
        downloadUrl: "${api.baseUrl}/api/steam/patches/${m.appId}/download",
        installDir: m.installDir,
        patchFilename: m.patchFilename ?? "patch_${m.appId}.zip",
        patchDir: m.patchDir,
        targetDir: m.targetDir,
        onProgress: (p, r, t, s) {
          if (mounted) setState(() => _injectState[m.appId] = "$p|$r|$t|$s");
        },
      );
      if (!mounted) return;
      if (result["error"] != null) {
        setState(() => _injectState[m.appId] = "error:${result["error"]}");
      } else {
        setState(() => _injectState.remove(m.appId));
        _showMsg("注入完成\n${result["output"] ?? m.installDir}");
      }
    } catch (e) {
      if (mounted) setState(() => _injectState[m.appId] = "error:$e");
    }
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Column(children: [
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
              Text("Steam 补丁管理", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
              const Spacer(),
              IconButton(icon: const Icon(Icons.manage_search, size: 20), tooltip: "关键词快捷匹配",
                onPressed: _showKeywordsDialog,
                style: IconButton.styleFrom(backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.1))),
            ]),
            const SizedBox(height: 12),
            Row(children: [_tabBtn("客户端", Icons.computer, 0), const SizedBox(width: 8), _tabBtn("服务端", Icons.dns, 1)]),
          ]),
        ),
        if (_tabIndex == 0) Expanded(child: _buildClientTab()) else Expanded(child: _buildServerTab()),
      ]),
    );
  }

  Widget _tabBtn(String label, IconData icon, int index) {
    final active = _tabIndex == index;
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: active ? cs.primary.withValues(alpha: 0.12) : cardBg(context),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          setState(() => _tabIndex = index);
          if (index == 1 && _serverPatches.isEmpty && !_serverLoading) _loadServerPatches();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: active ? cs.primary : subTextColor(context)),
            const SizedBox(width: 6),
            Text(label, style: AppText.bodySmall.copyWith(fontWeight: active ? FontWeight.w600 : FontWeight.w400, color: active ? cs.primary : subTextColor(context))),
          ]),
        ),
      ),
    );
  }

  // ── Client tab ──

  Widget _buildClientTab() {
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 0), child: _buildDirRow()),
      if (_status != null) Padding(padding: const EdgeInsets.fromLTRB(20, 12, 20, 0), child: _buildStatusBar()),
      const SizedBox(height: 8),
      if (_loading) const Expanded(child: Center(child: CircularProgressIndicator()))
      else if (_matches.isEmpty) Expanded(child: _emptyClientState())
      else Expanded(child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        children: [
          if (_availablePatches.isNotEmpty) ...[
            _sectionHeader("可注入 (${_availablePatches.length})", Icons.download, Colors.green),
            ..._availablePatches.map((m) => _gameCard(m)),
          ],
          if (_noPatchGames.isNotEmpty) ...[
            const SizedBox(height: 8),
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _showNoPatch = !_showNoPatch),
              child: _sectionHeader("暂无补丁 (${_noPatchGames.length})", _showNoPatch ? Icons.expand_less : Icons.expand_more, Colors.grey),
            ),
            if (_showNoPatch) ..._noPatchGames.map((m) => _simpleCard(m)),
          ],
        ],
      )),
    ]);
  }

  Widget _buildDirRow() {
    final hasDir = _commonDir != null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: cardBg(context), borderRadius: BorderRadius.circular(12), border: Border.all(color: cardBorder(context))),
      child: Row(children: [
        Container(width: 40, height: 40, decoration: BoxDecoration(color: hasDir ? Colors.blue.withValues(alpha: 0.12) : cardBg(context), borderRadius: BorderRadius.circular(10)),
          child: Icon(Icons.folder, size: 22, color: hasDir ? Colors.blue[300] : Colors.grey[500])),
        const SizedBox(width: 12),
        Expanded(child: Text(hasDir ? _commonDir! : "未选择 Steam 库目录", maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodySmall.copyWith(color: hasDir ? null : Colors.grey[500], fontWeight: hasDir ? FontWeight.w500 : null))),
        const SizedBox(width: 8),
        _miniBtn(Icons.folder_open, hasDir ? "更换" : "选择", _pickDirectory),
        if (hasDir) ...[const SizedBox(width: 8), _miniBtn(Icons.refresh, "刷新", _loading ? null : _scanAndCheck)],
      ]),
    );
  }

  Widget _miniBtn(IconData icon, String label, VoidCallback? onTap) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.primary.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8),
      child: InkWell(borderRadius: BorderRadius.circular(8), onTap: onTap,
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15, color: onTap == null ? cs.outline : cs.primary),
            const SizedBox(width: 5),
            Text(label, style: AppText.bodySmall.copyWith(fontWeight: FontWeight.w500, color: cs.primary)),
          ])),
      ),
    );
  }

  Widget _buildStatusBar() {
    final available = _availablePatches.length;
    final color = available > 0 ? Colors.green : Colors.grey;
    return Container(
      width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withValues(alpha: 0.2))),
      child: Row(children: [
        Icon(available > 0 ? Icons.check_circle_outline : Icons.info_outline, size: 18, color: color[600]),
        const SizedBox(width: 8),
        Expanded(child: Text(_status!, style: AppText.bodySmall.copyWith(color: color[700], fontWeight: FontWeight.w500))),
      ]),
    );
  }

  Widget _sectionHeader(String title, IconData icon, MaterialColor color) {
    return Padding(padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Row(children: [
        Icon(icon, size: 16, color: color[600]),
        const SizedBox(width: 8),
        Text(title, style: AppText.bodySmall.copyWith(color: color[700], fontWeight: FontWeight.w600)),
      ]));
  }

  Widget _gameCard(PatchMatch m) {
    final state = _injectState[m.appId];
    return Container(
      margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: cardBg(context), borderRadius: BorderRadius.circular(12), border: Border.all(color: cardBorder(context))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 36, height: 36, decoration: BoxDecoration(color: Colors.green.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
            child: Icon(Icons.download, size: 18, color: Colors.green[600])),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(m.gameName, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text("AppID ${m.appId}  ·  ${m.installDir}", maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodySmall.copyWith(color: subTextColor(context), fontSize: 11)),
          ])),
          if (state == null)
            FilledButton.tonalIcon(onPressed: () => _startInjection(m), icon: const Icon(Icons.auto_fix_high, size: 16),
              label: Text("注入", style: AppText.bodySmall.copyWith(fontWeight: FontWeight.w600)),
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8), minimumSize: Size.zero))
          else if (!state.startsWith("error") && state != "done")
            Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
          else if (state.startsWith("error"))
            Row(mainAxisSize: MainAxisSize.min, children: [
              Text(state.substring(6), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodySmall.copyWith(color: Colors.red[200])),
              IconButton(icon: const Icon(Icons.close, size: 14), onPressed: () => setState(() => _injectState.remove(m.appId)), visualDensity: VisualDensity.compact, padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            ]),
        ]),
        if (m.patchFilename != null && state == null)
          Padding(padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              _typeBadge(m.type),
              const SizedBox(width: 6),
              Text(m.label ?? m.patchFilename ?? "", style: AppText.bodySmall.copyWith(color: Colors.green[700], fontWeight: FontWeight.w500)),
              const Spacer(),
              Text(_formatSize(m.patchSize), style: AppText.bodySmall.copyWith(color: Colors.green[700], fontWeight: FontWeight.w600)),
            ])),
        if (state != null && !state.startsWith("error") && state != "done") ...[
          const SizedBox(height: 6),
          _buildInjectProgress(m.appId, state),
        ],
      ]),
    );
  }

  Widget _simpleCard(PatchMatch m) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: cardBg(context), borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        Icon(Icons.block, size: 14, color: subTextColor(context)),
        const SizedBox(width: 10),
        Expanded(child: Text(m.gameName, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodySmall.copyWith(color: subTextColor(context)))),
        Text("AppID ${m.appId}", style: AppText.bodySmall.copyWith(color: subTextColor(context), fontSize: 11)),
      ]),
    );
  }

  Widget _emptyClientState() => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.inventory_2_outlined, size: 48, color: placeholderIcon(context)),
      const SizedBox(height: 12),
      Text("选择 Steam 库目录开始扫描", style: AppText.bodyMedium.copyWith(color: hintColor(context))),
    ]),
  );

  // ── Server tab ──

  Widget _buildServerTab() {
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: Row(children: [
          _miniBtn(Icons.refresh, "加载", _serverLoading ? null : _loadServerPatches),
          const SizedBox(width: 8),
          _miniBtn(Icons.folder, "扫描补丁", _serverLoading ? null : _scanServerPatches),
        ])),
      if (_serverStatus != null) Padding(padding: const EdgeInsets.fromLTRB(20, 12, 20, 0), child: _buildServerStatusBar()),
      const SizedBox(height: 8),
      if (_serverLoading) const Expanded(child: Center(child: CircularProgressIndicator()))
      else if (_serverPatches.isEmpty) Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.archive_outlined, size: 48, color: placeholderIcon(context)),
        const SizedBox(height: 12), Text("无补丁索引", style: AppText.bodyMedium.copyWith(color: hintColor(context))),
        const SizedBox(height: 4), Text("点击'扫描补丁'索引服务端补丁文件", style: AppText.bodySmall.copyWith(color: hintColor(context))),
      ])))
      else Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 20), children: _serverPatches.map((p) => _serverPatchCard(p)).toList())),
    ]);
  }

  Widget _buildServerStatusBar() {
    return Container(
      width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(10), border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15))),
      child: Text(_serverStatus!, style: AppText.bodySmall.copyWith(color: subTextColor(context))),
    );
  }

  Widget _serverPatchCard(Map<String, dynamic> p) {
    final file = (p["file"] ?? "").toString();
    final label = (p["label"] ?? "").toString();
    final ptype = (p["type"] ?? "misc").toString();
    final patchDir = (p["patch_dir"] ?? "").toString();
    final targetDir = (p["target_dir"] ?? "").toString();
    final appId = (p["app_id"] ?? "").toString();
    final matched = (p["matched_game"] ?? "").toString();
    final hasAppId = appId.isNotEmpty && appId != "None" && appId != "null";

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(color: cardBg(context), borderRadius: BorderRadius.circular(12), border: Border.all(color: cardBorder(context)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 4, offset: const Offset(0, 2))]),
      child: Padding(padding: const EdgeInsets.all(14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: 40, height: 40, decoration: BoxDecoration(color: hasAppId ? Colors.blue.withValues(alpha: 0.1) : Colors.orange.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
            child: Icon(hasAppId ? Icons.videogame_asset : Icons.archive, size: 20, color: hasAppId ? Colors.blue[400] : Colors.orange[400])),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(label.isNotEmpty ? label : file.split("/").last, style: AppText.bodyMedium.copyWith(fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 4), _typeBadge(ptype),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              if (hasAppId) ...[ _appIdChip(appId), const SizedBox(width: 6) ]
              else ...[ Icon(Icons.warning_amber, size: 12, color: Colors.orange[300]), const SizedBox(width: 2), Text("无 AppID", style: AppText.caption.copyWith(color: Colors.orange[300])), const SizedBox(width: 6) ],
              if (matched.isNotEmpty) ...[ Icon(Icons.link, size: 10, color: hintColor(context)), const SizedBox(width: 2), Text(matched, style: AppText.caption.copyWith(color: hintColor(context))), const SizedBox(width: 4) ],
              Expanded(child: Text(file, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: hintColor(context), fontSize: 10))),
            ]),
            if (patchDir.isNotEmpty && targetDir.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 4), child: Row(children: [
                Icon(Icons.folder_copy, size: 10, color: hintColor(context)), const SizedBox(width: 4),
                Expanded(child: Text("$patchDir → /$targetDir", style: AppText.caption.copyWith(color: hintColor(context)))),
              ])),
          ])),
          const SizedBox(width: 4),
          IconButton(icon: const Icon(Icons.edit, size: 16), tooltip: "编辑", visualDensity: VisualDensity.compact, padding: const EdgeInsets.all(6), constraints: const BoxConstraints(),
            onPressed: () => _showEditDialog(PatchMatch(appId: appId, gameName: label.isNotEmpty ? label : file.split("/").last, installDir: "", patchAvailable: true, patchFilename: file, patchDir: patchDir, targetDir: targetDir, label: label, type: ptype))),
        ])),
    );
  }

  // ── Edit dialog ──

  Future<void> _showEditDialog(PatchMatch m) async {
    final patchCtrl = TextEditingController(text: m.patchDir ?? "");
    final targetCtrl = TextEditingController(text: m.targetDir ?? "");
    final labelCtrl = TextEditingController(text: m.label ?? "");
    final appIdCtrl = TextEditingController(text: m.appId != "null" && m.appId != "None" && m.appId.isNotEmpty ? m.appId : "");
    String ptype = m.type ?? "misc";

    final result = await showDialog<Map<String, String>>(context: context, builder: (ctx) => AlertDialog(
      title: Text("编辑补丁 — ${m.gameName}"),
      content: SizedBox(width: 380, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: appIdCtrl, decoration: const InputDecoration(labelText: "Steam App ID", hintText: "Steam 商店游戏ID", isDense: true), keyboardType: TextInputType.number),
        const SizedBox(height: 10),
        TextField(controller: patchCtrl, decoration: const InputDecoration(labelText: "补丁源目录 (patch_dir)", hintText: "解压后取此子目录", isDense: true)),
        const SizedBox(height: 10),
        TextField(controller: targetCtrl, decoration: const InputDecoration(labelText: "目标目录 (target_dir)", hintText: "复制到游戏目录下的子路径", isDense: true)),
        const SizedBox(height: 10),
        TextField(controller: labelCtrl, decoration: const InputDecoration(labelText: "显示名称 (label)", hintText: "界面显示的补丁名", isDense: true)),
        const SizedBox(height: 10),
        DropdownButtonFormField<String>(value: ptype, items: _typeLabels.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
          onChanged: (v) => ptype = v ?? "misc", decoration: const InputDecoration(labelText: "补丁类型", isDense: true)),
      ]))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
        FilledButton(onPressed: () => Navigator.pop(ctx, {"app_id": appIdCtrl.text.trim(), "patch_dir": patchCtrl.text.trim(), "target_dir": targetCtrl.text.trim(), "label": labelCtrl.text.trim(), "type": ptype}), child: const Text("保存")),
      ],
    ));
    if (result == null || !mounted) return;
    try {
      final api = context.read<GameProvider>().api;
      await SteamService.updatePatch(api: api, appId: result["app_id"] ?? m.appId, file: m.patchFilename,
        patchDir: result["patch_dir"] ?? "", targetDir: result["target_dir"] ?? "", label: result["label"] ?? "", type: result["type"] ?? "misc");
      _loadServerPatches();
      if (_tabIndex == 0) _scanAndCheck();
    } catch (e) { _showMsg("保存失败: $e", error: true); }
  }

  // ── Keywords dialog ──

  Future<void> _showKeywordsDialog() async {
    final api = context.read<GameProvider>().api;
    Map<String, dynamic> keywords;
    try {
      keywords = await SteamService.getTypeKeywords(api);
    } catch (_) { _showMsg("加载关键词失败", error: true); return; }
    final ctrls = <String, TextEditingController>{};
    for (final entry in keywords.entries) {
      ctrls[entry.key] = TextEditingController(text: (entry.value as List).join(", "));
    }
    final confirmed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Row(children: [Icon(Icons.manage_search, size: 20), SizedBox(width: 8), Text("关键词快捷匹配")]),
      content: SizedBox(width: 500, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text("补丁文件名包含以下关键词时，自动识别为对应类型", style: AppText.bodySmall.copyWith(color: hintColor(context))),
        const SizedBox(height: 16),
        ..._typeLabels.entries.map((e) => Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(
          controller: ctrls[e.key],
          decoration: InputDecoration(labelText: "${e.value}（${e.key}）", hintText: "逗号分隔多个关键词", isDense: true, prefixIcon: _typeBadge(e.key)),
        ))),
      ]))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("保存")),
      ],
    ));
    if (confirmed != true || !mounted) return;
    final updated = <String, dynamic>{};
    for (final entry in ctrls.entries) {
      updated[entry.key] = entry.value.text.split(",").map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    }
    try {
      await SteamService.saveTypeKeywords(api, updated);
      _showMsg("关键词已保存");
    } catch (e) { _showMsg("保存失败: $e", error: true); }
  }

  // ── Badges & helpers ──

  static const _typeLabels = {"translation": "汉化", "voice": "音声", "story": "剧情", "extra": "额外", "misc": "其他"};
  static const _typeColors = {"translation": Colors.blue, "voice": Colors.purple, "story": Colors.orange, "extra": Colors.teal, "misc": Colors.grey};

  Widget _typeBadge(String? type) {
    final t = type ?? "misc";
    final label = _typeLabels[t] ?? "其他";
    final color = _typeColors[t] ?? Colors.grey;
    return Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1), decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4)),
      child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color[300])));
  }

  Widget _appIdChip(String appId) => Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
    child: Text("APP $appId", style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.blue[400])));

  Widget _buildInjectProgress(String appId, String state) {
    final parts = state.split("|");
    final progress = double.tryParse(parts[0]) ?? 0.0;
    final received = int.tryParse(parts[1]) ?? 0;
    final total = int.tryParse(parts[2]) ?? 0;
    final speed = int.tryParse(parts[3]) ?? 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(value: progress > 0 ? progress : null, minHeight: 4, backgroundColor: cardBorder(context)),
      ),
      const SizedBox(height: 4),
      Row(children: [
        Text("${(progress * 100).toStringAsFixed(0)}%", style: AppText.bodySmall.copyWith(fontWeight: FontWeight.w600)),
        if (total > 0) ...[
          const SizedBox(width: 8),
          Text("${_formatSize(received)} / ${_formatSize(total)}", style: AppText.bodySmall.copyWith(color: hintColor(context))),
        ],
        const Spacer(),
        if (speed > 0) Text("${_formatSize(speed)}/s", style: AppText.bodySmall.copyWith(color: hintColor(context))),
      ]),
    ]);
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1048576) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    if (bytes < 1073741824) return "${(bytes / 1048576).toStringAsFixed(1)} MB";
    return "${(bytes / 1073741824).toStringAsFixed(1)} GB";
  }
}
