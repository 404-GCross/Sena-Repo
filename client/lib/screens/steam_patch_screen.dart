/// Steam patch injection screen — PC-only (Windows / Linux).

import "dart:async";
import "dart:io" show Platform;

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:provider/provider.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:font_awesome_flutter/font_awesome_flutter.dart";

import "../providers/game_provider.dart";
import "../utils/theme_utils.dart";
import "../services/file_open_service.dart";
import "../services/steam_service.dart";
import "../widgets/app_shell.dart";

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
  bool _serverLoaded = false;
  bool _rescraping = false;
  String? _serverStatus;

  @override
  void initState() {
    super.initState();
    _loadSavedDir();
  }

  Future<void> _loadSavedDir() async {
    final prefs = await SharedPreferences.getInstance();
    final saved =
        prefs.getString("steamapps_dir") ?? prefs.getString("steam_common_dir");
    if (saved != null && saved.isNotEmpty && mounted) {
      setState(() {
        _commonDir = saved;
        _status = "已加载上次选择的 Steam 库，点击刷新开始扫描";
      });
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
    final games = SteamService.scanInstalledGames(_commonDir!);
    if (!mounted) return;
    try {
      final api = context.read<GameProvider>().api;
      setState(() => _status = "正在匹配补丁 (${games.length} 个游戏)...");
      final matches = await SteamService.checkPatches(api, games);
      if (!mounted) return;
      // Server returns Chinese game_name from patches.json for patched games
      matches.sort((a, b) {
        if (a.patchAvailable != b.patchAvailable)
          return a.patchAvailable ? -1 : 1;
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
                patchAvailable: false))
            .toList();
      });
    }
  }

  List<PatchMatch> get _availablePatches =>
      _matches.where((m) => m.patchAvailable).toList();
  List<PatchMatch> get _noPatchGames =>
      _matches.where((m) => !m.patchAvailable).toList();

  // ── Server tab ──

  Future<void> _loadServerPatches() async {
    setState(() {
      _serverLoading = true;
      _serverStatus = null;
    });
    try {
      final api = context.read<GameProvider>().api;
      final data = await SteamService.listPatches(api);
      final patches =
          (data["patches"] as List?)?.cast<Map<String, dynamic>>() ?? [];
      final needsScan = data["needs_scan"] == true;
      if (!mounted) return;
      setState(() {
        _serverPatches = patches;
        _serverLoading = false;
        _serverLoaded = true;
        if (patches.isEmpty && needsScan) {
          _serverStatus = "未建立补丁索引，点击“扫描补丁”生成";
        } else if (needsScan) {
          _serverStatus = "共 ${patches.length} 个补丁索引，建议手动扫描刷新大小信息";
        } else {
          _serverStatus = "共 ${patches.length} 个补丁索引";
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _serverLoading = false;
        _serverLoaded = false;
        _serverStatus = "加载失败: $e";
      });
    }
  }

  Future<void> _scanServerPatches() async {
    setState(() {
      _serverLoading = true;
      _serverStatus = "正在扫描...";
    });
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
      setState(() {
        _serverLoading = false;
        _serverStatus = "扫描失败: $e";
      });
    }
  }

  Future<void> _rescrapeOne(String lookupKey) async {
    final api = context.read<GameProvider>().api;
    setState(() => _serverStatus = "正在刮削 $lookupKey ...");
    try {
      final result = await SteamService.rescrapePatch(api, lookupKey);
      if (!mounted) return;
      final status = result["status"] ?? "";
      if (status == "updated") {
        _showMsg(
            "刮削成功\n新 AppID: ${result["new_app_id"]}${result["game_name"] != null && result["game_name"] != "" ? "\n游戏名: ${result["game_name"]}" : ""}");
        _loadServerPatches();
      } else if (status == "skipped") {
        _showMsg("已有 AppID，跳过刮削");
      } else {
        _showMsg("刮削失败: 未找到匹配的 Steam 游戏");
      }
    } catch (e) {
      if (mounted) _showMsg("刮削失败: $e", error: true);
    }
    if (mounted) setState(() => _serverStatus = null);
  }

  Future<void> _rescrapeAll() async {
    final api = context.read<GameProvider>().api;
    setState(() {
      _rescraping = true;
      _serverStatus = "正在批量刮削 AppID ...";
    });
    try {
      final result = await SteamService.rescrapeAllPatches(api);
      if (!mounted) return;
      final updated = result["updated"] ?? 0;
      final total = result["total"] ?? 0;
      _showMsg("批量刮削完成: $updated / $total 个更新");
      _loadServerPatches();
    } catch (e) {
      if (mounted) _showMsg("批量刮削失败: $e", error: true);
    }
    if (mounted)
      setState(() {
        _rescraping = false;
        _serverStatus = null;
      });
  }

  void _showMsg(String msg, {bool error = false}) {
    if (!mounted) return;
    showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
              icon: Icon(error ? Icons.error_outline : Icons.check_circle,
                  size: 28, color: error ? Colors.red[300] : Colors.green[300]),
              content: Text(msg, style: const TextStyle(fontSize: 14)),
              actions: [
                FilledButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text("确定"))
              ],
            ));
  }

  // ── Inject ──

  String _gameInstallPath(PatchMatch m) {
    if (_commonDir != null && _commonDir!.isNotEmpty) {
      return "${_commonDir!}${Platform.pathSeparator}common${Platform.pathSeparator}${m.installDir}";
    }
    return m.installDir;
  }

  Future<void> _openGameDir(PatchMatch m) async {
    final path = _gameInstallPath(m);
    try {
      final opened = await FileOpenService.openTargetFolder(path);
      if (!opened) {
        _showMsg("无法打开游戏目录\n$path", error: true);
      }
    } catch (e) {
      if (mounted) _showMsg("无法打开游戏目录: $e", error: true);
    }
  }

  Future<void> _showPatchTreeDialog(PatchMatch m, {bool allowInject = false}) async {
    final api = context.read<GameProvider>().api;
    final result = await showDialog<_PatchRuleDialogResult>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _PatchTreeDialog(
        api: api,
        match: m,
        installPath: allowInject ? _gameInstallPath(m) : null,
      ),
    );
    if (result == null || !mounted) return;
    if (result.saved) {
      _showMsg("补丁规则已保存");
      if (_serverLoaded) unawaited(_loadServerPatches());
      if (_tabIndex == 0 && _commonDir != null) unawaited(_scanAndCheck());
    }
    if (result.inject) {
      await _startInjection(
        m,
        patchDirOverride: result.patchDir,
        targetDirOverride: result.targetDir,
      );
    }
  }

  Future<void> _startInjection(
    PatchMatch m, {
    String? patchDirOverride,
    String? targetDirOverride,
  }) async {
    final api = context.read<GameProvider>().api;
    final fullPath = _gameInstallPath(m);
    setState(() =>
        _injectState[m.appId] = "0|0|0|0"); // progress|received|total|speed
    try {
      final result = await SteamService.injectPatch(
        appId: m.appId,
        downloadUrl: "${api.baseUrl}/api/steam/patches/${m.appId}/download",
        installDir: fullPath,
        patchFilename: m.patchFilename ?? "patch_${m.appId}.zip",
        patchDir: patchDirOverride ?? m.patchDir,
        targetDir: targetDirOverride ?? m.targetDir,
        onProgress: (p, r, t, s, stage) {
          if (mounted)
            setState(() => _injectState[m.appId] = "$p|$r|$t|$s|$stage");
        },
      );
      if (!mounted) return;
      if (result["error"] != null) {
        final err = result["error"] as String;
        if (err == "已暂停") {
          setState(() => _injectState[m.appId] = "paused");
          return;
        }
        if (err == "已取消") {
          setState(() => _injectState.remove(m.appId));
          return;
        }
        setState(() => _injectState[m.appId] = "error:${result["error"]}");
        _showMsg("注入失败\n${result["error"]}", error: true);
      } else {
        setState(() => _injectState.remove(m.appId));
        _showMsg("注入完成\n${result["output"] ?? fullPath}");
      }
    } catch (e) {
      if (mounted) setState(() => _injectState[m.appId] = "error:$e");
    }
  }

  void _cancelInjection(String appId) {
    SteamService.cancelInjection(appId);
    setState(() => _injectState.remove(appId));
  }

  void _pauseInjection(String appId) {
    SteamService.pauseInjection(appId);
    // State will update via onProgress callback → "paused" detected in _startInjection
  }

  void _resumeInjection(PatchMatch m) {
    _startInjection(m);
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackdrop(
        child: Column(children: [
          AppPageHeader(
            leading: FaIcon(
              FontAwesomeIcons.steam,
              size: 24,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: "Steam 补丁管理",
            subtitle: "本地补丁注入和服务端补丁索引统一管理",
            actions: [
              AppSegmentedTabs(
                selectedIndex: _tabIndex,
                tabs: const [
                  AppSegmentedTab(0, Icons.computer, "客户端"),
                  AppSegmentedTab(1, Icons.dns_outlined, "服务端"),
                ],
                onChanged: (index) {
                  setState(() => _tabIndex = index);
                  if (index == 1 && !_serverLoaded && !_serverLoading) {
                    _loadServerPatches();
                  }
                },
              ),
              AppActionButton(
                icon: Icons.manage_search,
                label: "关键词匹配",
                onPressed: _showKeywordsDialog,
              ),
            ],
          ),
          if (_tabIndex == 0)
            Expanded(child: _buildClientTab())
          else
            Expanded(child: _buildServerTab()),
        ]),
      ),
    );
  }

  // ── Client tab ──

  Widget _buildClientTab() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 860;
          final control = _buildClientControlPanel();
          final content = _buildClientResultPanel();
          if (!wide) {
            return Column(
              children: [
                control,
                const SizedBox(height: AppGap.lg),
                Expanded(child: content),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 320, child: control),
              const SizedBox(width: AppGap.lg),
              Expanded(child: content),
            ],
          );
        },
      ),
    );
  }

  Widget _buildClientControlPanel() {
    final hasDir = _commonDir != null && _commonDir!.isNotEmpty;
    return AppSurface(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.computer,
                  color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: AppGap.sm),
              Text("本地库", style: AppText.title),
            ],
          ),
          const SizedBox(height: AppGap.lg),
          _buildDirRow(),
          const SizedBox(height: AppGap.lg),
          Wrap(
            spacing: AppGap.sm,
            runSpacing: AppGap.sm,
            children: [
              AppActionButton(
                icon: Icons.folder_open,
                label: hasDir ? "更换目录" : "选择目录",
                onPressed: _pickDirectory,
                filled: true,
              ),
              AppActionButton(
                icon: Icons.refresh,
                label: "刷新扫描",
                onPressed: hasDir && !_loading ? _scanAndCheck : null,
                busy: _loading,
              ),
            ],
          ),
          const SizedBox(height: AppGap.lg),
          if (_status != null) _buildStatusBar(),
          const SizedBox(height: AppGap.lg),
          Wrap(
            spacing: AppGap.sm,
            runSpacing: AppGap.sm,
            children: [
              AppMetricCard(
                label: "已匹配游戏",
                value: "${_matches.length}",
                icon: Icons.sports_esports,
                color: Theme.of(context).colorScheme.primary,
              ),
              AppMetricCard(
                label: "可用补丁",
                value: "${_availablePatches.length}",
                icon: Icons.download_done,
                color: Colors.green,
              ),
            ],
          ),
          const Spacer(),
          Text(
            "提示：页面打开时只读取上次目录，不会自动重新扫描。需要刷新时手动点击“刷新扫描”。",
            style: AppText.caption
                .copyWith(color: hintColor(context), height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _buildClientResultPanel() {
    return AppSurface(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
            child: Row(
              children: [
                Text("补丁匹配结果", style: AppText.title),
                const Spacer(),
                if (_matches.isNotEmpty)
                  AppStatusPill(
                    icon: Icons.check_circle_outline,
                    label: "${_availablePatches.length}/${_matches.length} 可注入",
                    color: _availablePatches.isNotEmpty
                        ? Colors.green
                        : Colors.grey,
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: cardBorder(context)),
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_matches.isEmpty)
            Expanded(child: _emptyClientState())
          else
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
                children: [
                  if (_availablePatches.isNotEmpty) ...[
                    _sectionHeader("可注入 (${_availablePatches.length})",
                        Icons.download, Colors.green),
                    ..._availablePatches.map((m) => _gameCard(m)),
                  ],
                  if (_noPatchGames.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => setState(() => _showNoPatch = !_showNoPatch),
                      child: _sectionHeader(
                        "暂无补丁 (${_noPatchGames.length})",
                        _showNoPatch ? Icons.expand_less : Icons.expand_more,
                        Colors.grey,
                      ),
                    ),
                    if (_showNoPatch)
                      ..._noPatchGames.map((m) => _simpleCard(m)),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDirRow() {
    final hasDir = _commonDir != null;
    final label = hasDir ? _commonDir! : "未选择 Steam 库目录";
    final textStyle = AppText.bodySmall.copyWith(
      color: hasDir ? null : Colors.grey[500],
      fontWeight: hasDir ? FontWeight.w500 : null,
    );
    return AppSurface(
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
                color: hasDir
                    ? Colors.blue.withValues(alpha: 0.12)
                    : cardBg(context),
                borderRadius: BorderRadius.circular(10)),
            child: Icon(Icons.folder,
                size: 22, color: hasDir ? Colors.blue[300] : Colors.grey[500])),
        const SizedBox(width: 12),
        Expanded(
          child: _HoverPathText(
            path: label,
            enabled: hasDir,
            style: textStyle,
          ),
        ),
      ]),
    );
  }

  Widget _buildStatusBar() {
    final available = _availablePatches.length;
    final color = available > 0 ? Colors.green : Colors.grey;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.2))),
      child: Row(children: [
        Icon(available > 0 ? Icons.check_circle_outline : Icons.info_outline,
            size: 18, color: color[600]),
        const SizedBox(width: 8),
        Expanded(
            child: Text(_status!,
                style: AppText.bodySmall
                    .copyWith(color: color[700], fontWeight: FontWeight.w500))),
      ]),
    );
  }

  Widget _sectionHeader(String title, IconData icon, MaterialColor color) {
    return Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        child: Row(children: [
          Icon(icon, size: 16, color: color[600]),
          const SizedBox(width: 8),
          Text(title,
              style: AppText.bodySmall
                  .copyWith(color: color[700], fontWeight: FontWeight.w600)),
        ]));
  }

  Widget _gameCard(PatchMatch m) {
    final state = _injectState[m.appId];
    return AppSurface(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      radius: AppRadius.md,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8)),
              child: Icon(Icons.download, size: 18, color: Colors.green[600])),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(m.gameName,
                    style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text("AppID ${m.appId}  ·  ${m.installDir}",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.bodySmall
                        .copyWith(color: subTextColor(context), fontSize: 11)),
              ])),
          if (state == null)
            Wrap(
                spacing: 8,
                runSpacing: 6,
                alignment: WrapAlignment.end,
                children: [
                  OutlinedButton.icon(
                      onPressed: () => _openGameDir(m),
                      icon: const Icon(Icons.folder_open, size: 16),
                      label: Text("打开目录",
                          style: AppText.bodySmall
                              .copyWith(fontWeight: FontWeight.w600)),
                      style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          minimumSize: Size.zero)),
                  OutlinedButton.icon(
                      onPressed: () => _showPatchTreeDialog(m, allowInject: true),
                      icon: const Icon(Icons.account_tree_outlined, size: 16),
                      label: Text("结构",
                          style: AppText.bodySmall
                              .copyWith(fontWeight: FontWeight.w600)),
                      style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          minimumSize: Size.zero)),
                  FilledButton.tonalIcon(
                      onPressed: () => _startInjection(m),
                      icon: const Icon(Icons.auto_fix_high, size: 16),
                      label: Text("注入",
                          style: AppText.bodySmall
                              .copyWith(fontWeight: FontWeight.w600)),
                      style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          minimumSize: Size.zero)),
                ])
          else if (state == "paused")
            Row(mainAxisSize: MainAxisSize.min, children: [
              Text("已暂停",
                  style: AppText.bodySmall.copyWith(
                      color: Colors.orange[300], fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => _resumeInjection(m),
                child: const Text("继续", style: TextStyle(fontSize: 12)),
                style: FilledButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              ),
              const SizedBox(width: 4),
              TextButton(
                onPressed: () => _cancelInjection(m.appId),
                child: Text("取消",
                    style: AppText.label.copyWith(color: Colors.red)),
                style: TextButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              ),
            ])
          else if (!state.startsWith("error") &&
              state != "done" &&
              state != "paused") ...[
            Builder(builder: (_) {
              final parts = state.split("|");
              final stage = parts.length > 4 ? parts[4] : "";
              final canPause = stage != "extracting";
              return Row(mainAxisSize: MainAxisSize.min, children: [
                if (canPause)
                  TextButton(
                    onPressed: () => _pauseInjection(m.appId),
                    child: const Text("暂停", style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  ),
                TextButton(
                  onPressed: () => _cancelInjection(m.appId),
                  child: Text("取消",
                      style: AppText.label.copyWith(color: Colors.red)),
                  style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                ),
                const SizedBox(width: 4),
                SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ]);
            }),
          ] else if (state.startsWith("error"))
            Row(mainAxisSize: MainAxisSize.min, children: [
              Text(state.substring(6),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.bodySmall.copyWith(color: Colors.red[200])),
              IconButton(
                  icon: const Icon(Icons.close, size: 14),
                  onPressed: () => setState(() => _injectState.remove(m.appId)),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints()),
            ]),
        ]),
        if (m.patchFilename != null && state == null)
          Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [
                _typeBadge(m.type),
                const SizedBox(width: 6),
                Text(m.label ?? m.patchFilename ?? "",
                    style: AppText.bodySmall.copyWith(
                        color: Colors.green[700], fontWeight: FontWeight.w500)),
                const Spacer(),
                Text(_formatSize(m.patchSize),
                    style: AppText.bodySmall.copyWith(
                        color: Colors.green[700], fontWeight: FontWeight.w600)),
              ])),
        if (state != null &&
            !state.startsWith("error") &&
            state != "done" &&
            state != "paused") ...[
          const SizedBox(height: 6),
          _buildInjectProgress(m.appId, state),
        ],
      ]),
    );
  }

  Widget _simpleCard(PatchMatch m) {
    return AppSurface(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      radius: AppRadius.sm,
      child: Row(children: [
        Icon(Icons.block, size: 14, color: subTextColor(context)),
        const SizedBox(width: 10),
        Expanded(
            child: Text(m.gameName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    AppText.bodySmall.copyWith(color: subTextColor(context)))),
        IconButton(
          icon: const Icon(Icons.folder_open, size: 16),
          tooltip: "打开目录",
          onPressed: () => _openGameDir(m),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.all(6),
          constraints: const BoxConstraints(),
        ),
        const SizedBox(width: 6),
        Text("AppID ${m.appId}",
            style: AppText.bodySmall
                .copyWith(color: subTextColor(context), fontSize: 11)),
      ]),
    );
  }

  Widget _emptyClientState() => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.inventory_2_outlined,
              size: 48, color: placeholderIcon(context)),
          const SizedBox(height: 12),
          Text("选择 Steam 库目录开始扫描",
              style: AppText.bodyMedium.copyWith(color: hintColor(context))),
        ]),
      );

  // ── Server tab ──

  Widget _buildServerTab() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 860;
          final control = _buildServerControlPanel();
          final content = _buildServerResultPanel();
          if (!wide) {
            return Column(
              children: [
                control,
                const SizedBox(height: AppGap.lg),
                Expanded(child: content),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 320, child: control),
              const SizedBox(width: AppGap.lg),
              Expanded(child: content),
            ],
          );
        },
      ),
    );
  }

  Widget _buildServerControlPanel() {
    final missingAppIds = _serverPatches.where((p) {
      final appId = (p["app_id"] ?? "").toString();
      return appId.isEmpty || appId == "None" || appId == "null";
    }).length;
    return AppSurface(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.dns_outlined,
                  color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: AppGap.sm),
              Text("服务端索引", style: AppText.title),
            ],
          ),
          const SizedBox(height: AppGap.lg),
          Wrap(
            spacing: AppGap.sm,
            runSpacing: AppGap.sm,
            children: [
              AppActionButton(
                icon: Icons.refresh,
                label: "加载索引",
                onPressed: _serverLoading ? null : _loadServerPatches,
                busy: _serverLoading,
                filled: true,
              ),
              AppActionButton(
                icon: Icons.folder,
                label: "扫描补丁",
                onPressed: _serverLoading ? null : _scanServerPatches,
              ),
              AppActionButton(
                icon: Icons.search,
                label: "批量刮削 ID",
                onPressed: _serverLoading || _rescraping ? null : _rescrapeAll,
                busy: _rescraping,
              ),
            ],
          ),
          const SizedBox(height: AppGap.lg),
          if (_serverStatus != null) _buildServerStatusBar(),
          const SizedBox(height: AppGap.lg),
          Wrap(
            spacing: AppGap.sm,
            runSpacing: AppGap.sm,
            children: [
              AppMetricCard(
                label: "补丁索引",
                value: "${_serverPatches.length}",
                icon: Icons.archive_outlined,
                color: Theme.of(context).colorScheme.primary,
              ),
              AppMetricCard(
                label: "缺少 AppID",
                value: "$missingAppIds",
                icon: Icons.warning_amber,
                color: missingAppIds > 0 ? Colors.orange : Colors.green,
              ),
            ],
          ),
          const Spacer(),
          Text(
            "服务端页面只在首次切换或手动点击时加载索引，不再每次打开都触发扫描。",
            style: AppText.caption
                .copyWith(color: hintColor(context), height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _buildServerResultPanel() {
    return AppSurface(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
            child: Row(
              children: [
                Text("服务端补丁索引", style: AppText.title),
                const Spacer(),
                if (_serverLoaded)
                  AppStatusPill(
                    icon: Icons.inventory_2_outlined,
                    label: "${_serverPatches.length} 个补丁",
                    color: Theme.of(context).colorScheme.primary,
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: cardBorder(context)),
          if (_serverLoading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_serverPatches.isEmpty)
            Expanded(
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.archive_outlined,
                      size: 48, color: placeholderIcon(context)),
                  const SizedBox(height: 12),
                  Text("无补丁索引",
                      style: AppText.bodyMedium
                          .copyWith(color: hintColor(context))),
                  const SizedBox(height: 4),
                  Text("点击“扫描补丁”索引服务端补丁文件",
                      style: AppText.bodySmall
                          .copyWith(color: hintColor(context))),
                ]),
              ),
            )
          else
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
                children:
                    _serverPatches.map((p) => _serverPatchCard(p)).toList(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildServerStatusBar() {
    return AppSurface(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Text(_serverStatus!,
          style: AppText.bodySmall.copyWith(color: subTextColor(context))),
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

    return AppSurface(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      radius: AppRadius.md,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
                color: hasAppId
                    ? Colors.blue.withValues(alpha: 0.1)
                    : Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10)),
            child: Icon(hasAppId ? Icons.videogame_asset : Icons.archive,
                size: 20,
                color: hasAppId ? Colors.blue[400] : Colors.orange[400])),
        const SizedBox(width: 12),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(label.isNotEmpty ? label : file.split("/").last,
                    style: AppText.bodyMedium
                        .copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 4),
            _typeBadge(ptype),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            if (hasAppId) ...[
              _appIdChip(appId),
              const SizedBox(width: 6)
            ] else ...[
              Icon(Icons.warning_amber, size: 12, color: Colors.orange[300]),
              const SizedBox(width: 2),
              Text("无 AppID",
                  style: AppText.caption.copyWith(color: Colors.orange[300])),
              const SizedBox(width: 6)
            ],
            if (matched.isNotEmpty) ...[
              Icon(Icons.link, size: 10, color: hintColor(context)),
              const SizedBox(width: 2),
              Text(matched,
                  style: AppText.caption.copyWith(color: hintColor(context))),
              const SizedBox(width: 4)
            ],
            Expanded(
                child: Text(file,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption
                        .copyWith(color: hintColor(context), fontSize: 10))),
          ]),
          if (patchDir.isNotEmpty && targetDir.isNotEmpty)
            Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(children: [
                  Icon(Icons.folder_copy, size: 10, color: hintColor(context)),
                  const SizedBox(width: 4),
                  Expanded(
                      child: Text("$patchDir → /$targetDir",
                          style: AppText.caption
                              .copyWith(color: hintColor(context)))),
                ])),
        ])),
        const SizedBox(width: 2),
        IconButton(
            icon: const Icon(Icons.manage_search, size: 16),
            tooltip: "重新刮削 AppID",
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(6),
            constraints: const BoxConstraints(),
            onPressed: () => _rescrapeOne(hasAppId ? appId : file)),
        IconButton(
            icon: const Icon(Icons.account_tree_outlined, size: 16),
            tooltip: "结构/规则",
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(6),
            constraints: const BoxConstraints(),
            onPressed: () => _showPatchTreeDialog(PatchMatch(
                appId: appId,
                gameName: label.isNotEmpty ? label : file.split("/").last,
                installDir: "",
                patchAvailable: true,
                patchFilename: file,
                patchDir: patchDir,
                targetDir: targetDir,
                label: label,
                type: ptype))),
        IconButton(
            icon: const Icon(Icons.edit, size: 16),
            tooltip: "编辑",
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(6),
            constraints: const BoxConstraints(),
            onPressed: () => _showEditDialog(PatchMatch(
                appId: appId,
                gameName: label.isNotEmpty ? label : file.split("/").last,
                installDir: "",
                patchAvailable: true,
                patchFilename: file,
                patchDir: patchDir,
                targetDir: targetDir,
                label: label,
                type: ptype))),
      ]),
    );
  }

  // ── Edit dialog ──

  Future<void> _showEditDialog(PatchMatch m) async {
    final patchCtrl = TextEditingController(text: m.patchDir ?? "");
    final targetCtrl = TextEditingController(text: m.targetDir ?? "");
    final labelCtrl = TextEditingController(text: m.label ?? "");
    final appIdCtrl = TextEditingController(
        text: m.appId != "null" && m.appId != "None" && m.appId.isNotEmpty
            ? m.appId
            : "");
    String ptype = m.type ?? "misc";

    final result = await showDialog<Map<String, String>>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text("编辑补丁 — ${m.gameName}"),
              content: SizedBox(
                  width: 380,
                  child: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: appIdCtrl,
                        decoration: const InputDecoration(
                            labelText: "Steam App ID",
                            hintText: "Steam 商店游戏ID",
                            isDense: true),
                        keyboardType: TextInputType.number),
                    const SizedBox(height: 10),
                    TextField(
                        controller: patchCtrl,
                        decoration: const InputDecoration(
                            labelText: "补丁源目录 (patch_dir)",
                            hintText: "解压后取此子目录",
                            isDense: true)),
                    const SizedBox(height: 10),
                    TextField(
                        controller: targetCtrl,
                        decoration: const InputDecoration(
                            labelText: "目标目录 (target_dir)",
                            hintText: "复制到游戏目录下的子路径",
                            isDense: true)),
                    const SizedBox(height: 10),
                    TextField(
                        controller: labelCtrl,
                        decoration: const InputDecoration(
                            labelText: "显示名称 (label)",
                            hintText: "界面显示的补丁名",
                            isDense: true)),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                        value: ptype,
                        items: _typeLabels.entries
                            .map((e) => DropdownMenuItem(
                                value: e.key, child: Text(e.value)))
                            .toList(),
                        onChanged: (v) => ptype = v ?? "misc",
                        decoration: const InputDecoration(
                            labelText: "补丁类型", isDense: true)),
                  ]))),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text("取消")),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, {
                          "app_id": appIdCtrl.text.trim(),
                          "patch_dir": patchCtrl.text.trim(),
                          "target_dir": targetCtrl.text.trim(),
                          "label": labelCtrl.text.trim(),
                          "type": ptype
                        }),
                    child: const Text("保存")),
              ],
            ));
    if (result == null || !mounted) return;
    try {
      final api = context.read<GameProvider>().api;
      await SteamService.updatePatch(
          api: api,
          appId: result["app_id"] ?? m.appId,
          file: m.patchFilename,
          patchDir: result["patch_dir"] ?? "",
          targetDir: result["target_dir"] ?? "",
          label: result["label"] ?? "",
          type: result["type"] ?? "misc");
      _loadServerPatches();
      if (_tabIndex == 0) _scanAndCheck();
    } catch (e) {
      _showMsg("保存失败: $e", error: true);
    }
  }

  // ── Keywords dialog ──

  Future<void> _showKeywordsDialog() async {
    final api = context.read<GameProvider>().api;
    final updated = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (ctx) => _KeywordMatchDialog(
              loadKeywords: () => SteamService.getTypeKeywords(api),
            ));
    if (updated == null || !mounted) return;
    try {
      await SteamService.saveTypeKeywords(api, updated);
      _showMsg("关键词已保存");
    } catch (e) {
      _showMsg("保存失败: $e", error: true);
    }
  }

  // ── Badges & helpers ──

  static const _typeLabels = {
    "translation": "汉化",
    "voice": "音声",
    "story": "剧情",
    "extra": "额外",
    "misc": "其他"
  };
  static const _typeColors = {
    "translation": Colors.blue,
    "voice": Colors.purple,
    "story": Colors.orange,
    "extra": Colors.teal,
    "misc": Colors.grey
  };

  Widget _typeBadge(String? type) {
    final t = type ?? "misc";
    final label = _typeLabels[t] ?? "其他";
    final color = _typeColors[t] ?? Colors.grey;
    return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(4)),
        child: Text(label,
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w600, color: color[300])));
  }

  Widget _appIdChip(String appId) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
          color: Colors.blue.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(4)),
      child: Text("APP $appId",
          style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: Colors.blue[400])));

  Widget _buildInjectProgress(String appId, String state) {
    final parts = state.split("|");
    final progress = double.tryParse(parts[0]) ?? 0.0;
    final received = int.tryParse(parts[1]) ?? 0;
    final total = int.tryParse(parts[2]) ?? 0;
    final speed = int.tryParse(parts[3]) ?? 0;
    final stage = parts.length > 4 ? parts[4] : "";
    final isExtracting =
        stage == "extracting" || (progress >= 0.99 && total > 0);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
            value: isExtracting ? null : (progress > 0 ? progress : null),
            minHeight: 4,
            backgroundColor: cardBorder(context)),
      ),
      const SizedBox(height: 4),
      Row(children: [
        Text(
            isExtracting ? "解压中..." : "${(progress * 100).toStringAsFixed(0)}%",
            style: AppText.bodySmall.copyWith(fontWeight: FontWeight.w600)),
        if (!isExtracting && total > 0) ...[
          const SizedBox(width: 8),
          Text("${_formatSize(received)} / ${_formatSize(total)}",
              style: AppText.bodySmall.copyWith(color: hintColor(context))),
        ],
        const Spacer(),
        if (!isExtracting && speed > 0)
          Text("${_formatSize(speed)}/s",
              style: AppText.bodySmall.copyWith(color: hintColor(context))),
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


class _PatchRuleDialogResult {
  final bool saved;
  final bool inject;
  final String patchDir;
  final String targetDir;

  const _PatchRuleDialogResult({
    required this.saved,
    required this.inject,
    required this.patchDir,
    required this.targetDir,
  });
}

class _PatchTreeDialog extends StatefulWidget {
  final dynamic api;
  final PatchMatch match;
  final String? installPath;

  const _PatchTreeDialog({
    required this.api,
    required this.match,
    this.installPath,
  });

  @override
  State<_PatchTreeDialog> createState() => _PatchTreeDialogState();
}

class _PatchTreeDialogState extends State<_PatchTreeDialog> {
  final _patchDir = TextEditingController();
  final _targetDir = TextEditingController();
  Map<String, dynamic>? _data;
  String? _error;
  bool _loading = true;
  bool _saving = false;
  int _stripComponents = 0;
  String _targetMode = "game_root";

  @override
  void initState() {
    super.initState();
    _patchDir.text = widget.match.patchDir ?? "";
    _targetDir.text = widget.match.targetDir ?? "";
    _loadTree();
  }

  @override
  void dispose() {
    _patchDir.dispose();
    _targetDir.dispose();
    super.dispose();
  }

  Future<void> _loadTree() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await SteamService.getPatchTree(
        widget.api,
        appId: widget.match.appId,
        file: widget.match.patchFilename,
      );
      final recommended = Map<String, dynamic>.from(
        (data["recommended"] as Map?) ?? const {},
      );
      final currentPatchDir = (data["patch_dir"] ?? widget.match.patchDir ?? "").toString();
      final currentTargetDir = (data["target_dir"] ?? widget.match.targetDir ?? "").toString();
      if (_patchDir.text.trim().isEmpty) {
        _patchDir.text = currentPatchDir.isNotEmpty
            ? currentPatchDir
            : (recommended["patch_dir"] ?? "").toString();
      }
      if (_targetDir.text.trim().isEmpty) {
        _targetDir.text = currentTargetDir.isNotEmpty
            ? currentTargetDir
            : (recommended["target_dir"] ?? "").toString();
      }
      _stripComponents = int.tryParse(
            (data["strip_components"] ?? recommended["strip_components"] ?? 0).toString(),
          ) ??
          0;
      if (_stripComponents == 0 && _patchDir.text.trim().isNotEmpty) {
        _stripComponents = 1;
      }
      _targetMode = (data["target_mode"] ?? recommended["target_mode"] ?? "game_root").toString();
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = "$e";
        _loading = false;
      });
    }
  }

  Future<void> _save({required bool inject}) async {
    setState(() => _saving = true);
    try {
      final patchDir = _patchDir.text.trim().replaceAll(RegExp(r"^/+|/+$"), "");
      final targetDir = _targetDir.text.trim().replaceAll(RegExp(r"^/+|/+$"), "");
      await SteamService.updatePatchRules(
        api: widget.api,
        appId: widget.match.appId,
        file: widget.match.patchFilename,
        patchDir: patchDir,
        targetDir: targetDir,
        stripComponents: patchDir.isEmpty ? 0 : _stripComponents,
        targetMode: _targetMode,
      );
      if (!mounted) return;
      Navigator.pop(
        context,
        _PatchRuleDialogResult(
          saved: true,
          inject: inject,
          patchDir: patchDir,
          targetDir: targetDir,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = "保存失败: $e";
      });
    }
  }

  List<Map<String, dynamic>> get _tree => ((_data?["tree"] as List?) ?? const [])
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList();

  List<Map<String, dynamic>> get _risks => ((_data?["risks"] as List?) ?? const [])
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final width = size.width > 1080 ? 1020.0 : size.width - 32;
    final height = size.height > 760 ? 700.0 : size.height - 32;
    final filename = widget.match.patchFilename?.split("/").last ?? widget.match.gameName;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: SizedBox(
        width: width,
        height: height,
        child: AppSurface(
          radius: AppRadius.xl,
          blur: true,
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
                child: Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      child: Icon(Icons.account_tree_outlined, color: cs.primary),
                    ),
                    const SizedBox(width: AppGap.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("补丁结构 / 注入规则", style: AppText.headline),
                          const SizedBox(height: 4),
                          Text(
                            filename,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.bodySmall.copyWith(color: hintColor(context)),
                          ),
                        ],
                      ),
                    ),
                    if (_data != null)
                      AppStatusPill(
                        icon: Icons.inventory_2_outlined,
                        label: "${_data!["file_count"] ?? 0} 文件",
                        color: cs.primary,
                      ),
                  ],
                ),
              ),
              Divider(height: 1, color: cardBorder(context)),
              Expanded(child: _buildBody(context)),
              Divider(height: 1, color: cardBorder(context)),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    AppActionButton(
                      icon: Icons.close_rounded,
                      label: "关闭",
                      color: hintColor(context),
                      onPressed: _saving ? null : () => Navigator.pop(context),
                    ),
                    const SizedBox(width: AppGap.sm),
                    AppActionButton(
                      icon: Icons.save_outlined,
                      label: "保存规则",
                      busy: _saving,
                      onPressed: _loading || _data == null || _saving ? null : () => _save(inject: false),
                    ),
                    if (widget.installPath != null) ...[
                      const SizedBox(width: AppGap.sm),
                      AppActionButton(
                        icon: Icons.auto_fix_high,
                        label: "保存并注入",
                        filled: true,
                        busy: _saving,
                        onPressed: _loading || _data == null || _saving ? null : () => _save(inject: true),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: AppSurface(
          padding: const EdgeInsets.all(AppGap.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, color: Colors.red[400], size: 34),
              const SizedBox(height: AppGap.md),
              Text("结构扫描失败", style: AppText.title),
              const SizedBox(height: AppGap.sm),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: AppText.bodySmall.copyWith(color: hintColor(context), height: 1.4),
                ),
              ),
              const SizedBox(height: AppGap.md),
              AppActionButton(
                icon: Icons.refresh_rounded,
                label: "重试扫描",
                filled: true,
                onPressed: _loadTree,
              ),
            ],
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 860;
        final tree = _buildTreePanel(context);
        final rules = _buildRulePanel(context);
        if (!wide) {
          return ListView(
            padding: const EdgeInsets.all(18),
            children: [tree, const SizedBox(height: AppGap.md), rules],
          );
        }
        return Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: tree),
              const SizedBox(width: AppGap.md),
              SizedBox(width: 340, child: rules),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTreePanel(BuildContext context) {
    return AppSurface(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                Text("压缩包目录树", style: AppText.title),
                const Spacer(),
                AppStatusPill(
                  icon: Icons.storage_rounded,
                  label: _formatPatchBytes(int.tryParse((_data?["total_uncompressed_size"] ?? 0).toString()) ?? 0),
                  color: Theme.of(context).colorScheme.primary,
                ),
              ],
            ),
          ),
          Divider(height: 1, color: cardBorder(context)),
          Expanded(
            child: _tree.isEmpty
                ? Center(
                    child: Text(
                      "没有读取到目录项",
                      style: AppText.bodySmall.copyWith(color: hintColor(context)),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _tree.length,
                    itemBuilder: (context, index) => _PatchTreeNodeRow(node: _tree[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildRulePanel(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final recommended = Map<String, dynamic>.from((_data?["recommended"] as Map?) ?? const {});
    final recommendedPatchDir = (recommended["patch_dir"] ?? "").toString();
    return AppSurface(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          Row(
            children: [
              Icon(Icons.rule_rounded, color: cs.primary),
              const SizedBox(width: AppGap.sm),
              Text("注入规则", style: AppText.title),
            ],
          ),
          const SizedBox(height: AppGap.md),
          if (recommendedPatchDir.isNotEmpty)
            AppSurface(
              padding: const EdgeInsets.all(12),
              color: Colors.orange.withValues(alpha: 0.08),
              border: Border.all(color: Colors.orange.withValues(alpha: 0.22)),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome_rounded, size: 18, color: Colors.orange[700]),
                  const SizedBox(width: AppGap.sm),
                  Expanded(
                    child: Text(
                      "推荐剥离外层目录：$recommendedPatchDir",
                      style: AppText.bodySmall.copyWith(color: Colors.orange[800], fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: AppGap.md),
          TextField(
            controller: _patchDir,
            decoration: const InputDecoration(
              labelText: "补丁内容根目录 (patch_dir)",
              hintText: "例如 Kinkoi_R18DLC；留空则直接解压",
              isDense: true,
            ),
          ),
          const SizedBox(height: AppGap.md),
          TextField(
            controller: _targetDir,
            decoration: const InputDecoration(
              labelText: "目标子目录 (target_dir)",
              hintText: "留空表示游戏根目录",
              isDense: true,
            ),
          ),
          const SizedBox(height: AppGap.md),
          DropdownButtonFormField<int>(
            value: _stripComponents,
            decoration: const InputDecoration(labelText: "剥离层级", isDense: true),
            items: List.generate(5, (index) => DropdownMenuItem(value: index, child: Text("剥离 $index 层"))),
            onChanged: (value) => setState(() => _stripComponents = value ?? 0),
          ),
          const SizedBox(height: AppGap.md),
          DropdownButtonFormField<String>(
            value: _targetMode,
            decoration: const InputDecoration(labelText: "目标模式", isDense: true),
            items: const [
              DropdownMenuItem(value: "game_root", child: Text("游戏根目录")),
              DropdownMenuItem(value: "custom", child: Text("自定义子目录")),
            ],
            onChanged: (value) => setState(() => _targetMode = value ?? "game_root"),
          ),
          if (widget.installPath != null) ...[
            const SizedBox(height: AppGap.md),
            AppSurface(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.folder_open_rounded, size: 18, color: hintColor(context)),
                  const SizedBox(width: AppGap.sm),
                  Expanded(
                    child: Text(
                      widget.installPath!,
                      style: AppText.caption.copyWith(color: hintColor(context), height: 1.35),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_risks.isNotEmpty) ...[
            const SizedBox(height: AppGap.lg),
            Text("扫描提示", style: AppText.bodyMedium.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: AppGap.sm),
            ..._risks.map((risk) => _PatchRiskTile(risk: risk)),
          ],
        ],
      ),
    );
  }
}

class _PatchTreeNodeRow extends StatelessWidget {
  final Map<String, dynamic> node;

  const _PatchTreeNodeRow({required this.node});

  @override
  Widget build(BuildContext context) {
    final type = (node["type"] ?? "file").toString();
    final isDir = type == "dir";
    final depth = int.tryParse((node["depth"] ?? 0).toString()) ?? 0;
    final size = int.tryParse((node["size"] ?? 0).toString()) ?? 0;
    final name = (node["name"] ?? node["path"] ?? "").toString();
    return Padding(
      padding: EdgeInsets.only(left: depth * 18.0, bottom: 3),
      child: Container(
        constraints: const BoxConstraints(minHeight: 30),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: isDir
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.06)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Row(
          children: [
            Icon(
              isDir ? Icons.folder_rounded : Icons.insert_drive_file_outlined,
              size: 16,
              color: isDir ? Theme.of(context).colorScheme.primary : hintColor(context),
            ),
            const SizedBox(width: AppGap.sm),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.bodySmall.copyWith(
                  color: isDir ? sectionTextColor(context) : subTextColor(context),
                  fontWeight: isDir ? FontWeight.w800 : FontWeight.w500,
                ),
              ),
            ),
            if (!isDir && size > 0)
              Text(
                _formatPatchBytes(size),
                style: AppText.caption.copyWith(color: hintColor(context)),
              ),
          ],
        ),
      ),
    );
  }
}

class _PatchRiskTile extends StatelessWidget {
  final Map<String, dynamic> risk;

  const _PatchRiskTile({required this.risk});

  @override
  Widget build(BuildContext context) {
    final level = (risk["level"] ?? "info").toString();
    final color = level == "danger"
        ? Colors.red
        : level == "warning"
            ? Colors.orange
            : Theme.of(context).colorScheme.primary;
    return Container(
      margin: const EdgeInsets.only(bottom: AppGap.sm),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            level == "danger" ? Icons.error_outline_rounded : Icons.info_outline_rounded,
            size: 18,
            color: color,
          ),
          const SizedBox(width: AppGap.sm),
          Expanded(
            child: Text(
              (risk["message"] ?? "").toString(),
              style: AppText.bodySmall.copyWith(color: color, height: 1.35, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatPatchBytes(int bytes) {
  if (bytes < 1024) return "$bytes B";
  if (bytes < 1048576) return "${(bytes / 1024).toStringAsFixed(1)} KB";
  if (bytes < 1073741824) return "${(bytes / 1048576).toStringAsFixed(1)} MB";
  return "${(bytes / 1073741824).toStringAsFixed(1)} GB";
}

class _KeywordMatchDialog extends StatefulWidget {
  final Future<Map<String, dynamic>> Function() loadKeywords;

  const _KeywordMatchDialog({required this.loadKeywords});

  @override
  State<_KeywordMatchDialog> createState() => _KeywordMatchDialogState();
}

class _KeywordMatchDialogState extends State<_KeywordMatchDialog> {
  final Map<String, TextEditingController> _controllers = {};
  Object? _loadError;
  bool _loading = true;
  String _selectedType = _SteamPatchScreenState._typeLabels.keys.first;

  @override
  void initState() {
    super.initState();
    _loadKeywords();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller
        ..removeListener(_onKeywordsChanged)
        ..dispose();
    }
    super.dispose();
  }

  Future<void> _loadKeywords() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final keywords = await widget.loadKeywords();
      if (!mounted) return;
      _replaceControllers(keywords);
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = e;
      });
    }
  }

  void _replaceControllers(Map<String, dynamic> keywords) {
    for (final controller in _controllers.values) {
      controller
        ..removeListener(_onKeywordsChanged)
        ..dispose();
    }
    _controllers
      ..clear()
      ..addEntries(_SteamPatchScreenState._typeLabels.keys.map(
        (type) => MapEntry(
          type,
          TextEditingController(text: _initialTextFor(keywords, type))
            ..addListener(_onKeywordsChanged),
        ),
      ));
  }

  String _initialTextFor(Map<String, dynamic> keywords, String type) {
    final value = keywords[type];
    if (value is List) {
      return value.map((item) => item.toString()).join(", ");
    }
    return value?.toString() ?? "";
  }

  void _onKeywordsChanged() {
    if (mounted) setState(() {});
  }

  bool get _ready => !_loading && _loadError == null && _controllers.isNotEmpty;

  List<String> _keywordsFor(String type) => (_controllers[type]?.text ?? "")
      .split(RegExp(r"[,，\n]"))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();

  Map<String, dynamic> _collectKeywords() => {
        for (final type in _SteamPatchScreenState._typeLabels.keys)
          type: _keywordsFor(type),
      };

  int get _totalKeywords => _SteamPatchScreenState._typeLabels.keys
      .fold(0, (total, type) => total + _keywordsFor(type).length);

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final compact = size.width < 720;
    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: compact ? 16 : 28,
        vertical: compact ? 18 : 28,
      ),
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: compact ? 560 : 900,
          maxHeight: size.height * 0.88,
        ),
        child: AppSurface(
          padding: EdgeInsets.zero,
          radius: AppRadius.xl,
          blur: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeader(context, compact: compact),
              Flexible(child: _buildContent(context, compact: compact)),
              _buildFooter(context, compact: compact),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, {required bool compact}) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.fromLTRB(20, compact ? 18 : 20, 14, 16),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: cardBorder(context).withValues(alpha: 0.7)),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Icon(Icons.manage_search_rounded, color: cs.primary),
          ),
          const SizedBox(width: AppGap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("关键词快捷匹配", style: AppText.headline),
                const SizedBox(height: 3),
                Text(
                  "按补丁文件名自动归类类型，支持逗号、中文逗号或换行分隔",
                  style: AppText.bodySmall.copyWith(color: hintColor(context)),
                  maxLines: compact ? 2 : 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (!compact)
            AppStatusPill(
              icon: _loading
                  ? Icons.sync_rounded
                  : _loadError == null
                      ? Icons.sell_outlined
                      : Icons.error_outline_rounded,
              label: _loading
                  ? "加载中"
                  : _loadError == null
                      ? "$_totalKeywords 个关键词"
                      : "加载失败",
              color: _loadError == null ? cs.primary : Colors.red,
            ),
          IconButton(
            tooltip: "关闭",
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context, {required bool compact}) {
    if (_loading) {
      return _buildStatePane(
        context,
        icon: Icons.sync_rounded,
        title: "正在加载关键词规则",
        message: "弹窗已经打开，正在从服务端读取当前匹配规则。",
        progress: true,
      );
    }
    if (_loadError != null) {
      return _buildStatePane(
        context,
        icon: Icons.error_outline_rounded,
        title: "关键词规则加载失败",
        message: "$_loadError",
        action: AppActionButton(
          icon: Icons.refresh_rounded,
          label: "重试",
          onPressed: _loadKeywords,
        ),
      );
    }
    return _buildBody(context, compact: compact);
  }

  Widget _buildStatePane(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String message,
    bool progress = false,
    Widget? action,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: AppSurface(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        radius: AppRadius.lg,
        color: cs.surfaceContainerHighest.withValues(alpha: 0.42),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (progress)
              SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(
                  strokeWidth: 2.6,
                  color: cs.primary,
                ),
              )
            else
              Icon(icon, size: 34, color: Colors.red),
            const SizedBox(height: AppGap.md),
            Text(title, style: AppText.title),
            const SizedBox(height: AppGap.sm),
            Text(
              message,
              style: AppText.bodySmall.copyWith(color: hintColor(context)),
              textAlign: TextAlign.center,
            ),
            if (action != null) ...[
              const SizedBox(height: AppGap.lg),
              action,
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, {required bool compact}) {
    if (compact) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildCompactSelector(context),
            const SizedBox(height: AppGap.md),
            _buildEditorCard(context),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 238, child: _buildTypeRail(context)),
          const SizedBox(width: AppGap.lg),
          Expanded(child: _buildEditorCard(context)),
        ],
      ),
    );
  }

  Widget _buildTypeRail(BuildContext context) {
    return AppSurface(
      padding: const EdgeInsets.all(12),
      radius: AppRadius.lg,
      color: Theme.of(context)
          .colorScheme
          .surfaceContainerHighest
          .withValues(alpha: 0.42),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 2, 4, 10),
            child: Text(
              "补丁类型",
              style: AppText.bodySmall.copyWith(
                color: hintColor(context),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          ..._SteamPatchScreenState._typeLabels.entries.map(
            (entry) => Padding(
              padding: const EdgeInsets.only(bottom: AppGap.sm),
              child: _buildTypeTile(context, entry.key, entry.value),
            ),
          ),
          const Spacer(),
          Text(
            "匹配只影响服务端补丁列表里的类型识别，不会修改补丁文件本身。",
            style: AppText.caption.copyWith(color: hintColor(context)),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactSelector(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final entry in _SteamPatchScreenState._typeLabels.entries) ...[
            _buildTypeChip(context, entry.key, entry.value),
            const SizedBox(width: AppGap.sm),
          ],
        ],
      ),
    );
  }

  Widget _buildTypeTile(BuildContext context, String type, String label) {
    final selected = type == _selectedType;
    final color = _typeColor(type);
    return Material(
      color: selected ? color.withValues(alpha: 0.13) : Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () => setState(() => _selectedType = type),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: selected
                  ? color.withValues(alpha: 0.38)
                  : cardBorder(context).withValues(alpha: 0.58),
            ),
          ),
          child: Row(
            children: [
              _typeIconBox(type, compact: true),
              const SizedBox(width: AppGap.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: AppText.bodyMedium
                          .copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "${_keywordsFor(type).length} 个关键词",
                      style:
                          AppText.caption.copyWith(color: hintColor(context)),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle_rounded, size: 17, color: color),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTypeChip(BuildContext context, String type, String label) {
    final selected = type == _selectedType;
    final color = _typeColor(type);
    return ChoiceChip(
      selected: selected,
      label: Text("$label · ${_keywordsFor(type).length}"),
      avatar: Icon(_typeIcon(type), size: 16, color: selected ? color : null),
      selectedColor: color.withValues(alpha: 0.16),
      onSelected: (_) => setState(() => _selectedType = type),
      side: BorderSide(
        color: selected
            ? color.withValues(alpha: 0.36)
            : cardBorder(context).withValues(alpha: 0.72),
      ),
      labelStyle: AppText.bodySmall.copyWith(fontWeight: FontWeight.w700),
    );
  }

  Widget _buildEditorCard(BuildContext context) {
    final label = _SteamPatchScreenState._typeLabels[_selectedType] ?? "其他";
    final controller = _controllers[_selectedType];
    if (controller == null) {
      return const SizedBox.shrink();
    }
    final keywords = _keywordsFor(_selectedType);
    final color = _typeColor(_selectedType);

    return AppSurface(
      padding: const EdgeInsets.all(18),
      radius: AppRadius.lg,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _typeIconBox(_selectedType),
                const SizedBox(width: AppGap.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("$label 关键词", style: AppText.title),
                      const SizedBox(height: 2),
                      Text(
                        "文件名包含任一关键词时会自动识别为“$label”",
                        style: AppText.bodySmall
                            .copyWith(color: hintColor(context)),
                      ),
                    ],
                  ),
                ),
                AppStatusPill(
                  icon: Icons.tag_rounded,
                  label: "${keywords.length} 个",
                  color: color,
                ),
              ],
            ),
            const SizedBox(height: AppGap.lg),
            TextField(
              controller: controller,
              minLines: 7,
              maxLines: 10,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                labelText: "匹配关键词",
                hintText: "例如：汉化, 中文, zh, 简中",
                alignLabelWithHint: true,
                filled: true,
                fillColor: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: 0.36),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: BorderSide(color: cardBorder(context)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: BorderSide(color: color, width: 1.4),
                ),
              ),
            ),
            const SizedBox(height: AppGap.md),
            Text(
              "预览",
              style: AppText.bodySmall.copyWith(
                color: hintColor(context),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: AppGap.sm),
            if (keywords.isEmpty)
              _buildEmptyPreview(context, color)
            else
              Wrap(
                spacing: AppGap.sm,
                runSpacing: AppGap.sm,
                children: [
                  for (final keyword in keywords)
                    _KeywordPreviewChip(label: keyword, color: color),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyPreview(BuildContext context, Color color) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Text(
        "当前类型还没有关键词，保存后不会自动匹配到这个类型。",
        style: AppText.bodySmall.copyWith(color: hintColor(context)),
      ),
    );
  }

  Widget _buildFooter(BuildContext context, {required bool compact}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: cardBorder(context).withValues(alpha: 0.7)),
        ),
      ),
      child: Row(
        children: [
          if (!compact)
            Expanded(
              child: Text(
                "保存后服务端补丁列表会按这些关键词重新识别类型。",
                style: AppText.caption.copyWith(color: hintColor(context)),
              ),
            )
          else
            const Spacer(),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("取消"),
          ),
          const SizedBox(width: AppGap.sm),
          AppActionButton(
            icon: Icons.save_rounded,
            label: "保存规则",
            filled: true,
            onPressed: _ready
                ? () => Navigator.pop(context, _collectKeywords())
                : null,
          ),
        ],
      ),
    );
  }

  Widget _typeIconBox(String type, {bool compact = false}) {
    final color = _typeColor(type);
    return Container(
      width: compact ? 34 : 42,
      height: compact ? 34 : 42,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius:
            BorderRadius.circular(compact ? AppRadius.sm : AppRadius.md),
      ),
      child: Icon(_typeIcon(type), size: compact ? 18 : 21, color: color),
    );
  }

  Color _typeColor(String type) =>
      _SteamPatchScreenState._typeColors[type] ?? Colors.grey;

  IconData _typeIcon(String type) => switch (type) {
        "translation" => Icons.translate_rounded,
        "voice" => Icons.record_voice_over_rounded,
        "story" => Icons.menu_book_rounded,
        "extra" => Icons.extension_rounded,
        _ => Icons.more_horiz_rounded,
      };
}

class _KeywordPreviewChip extends StatelessWidget {
  final String label;
  final Color color;

  const _KeywordPreviewChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Text(
        label,
        style: AppText.bodySmall.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _HoverPathText extends StatefulWidget {
  final String path;
  final bool enabled;
  final TextStyle? style;

  const _HoverPathText({
    required this.path,
    required this.enabled,
    this.style,
  });

  @override
  State<_HoverPathText> createState() => _HoverPathTextState();
}

class _HoverPathTextState extends State<_HoverPathText> {
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _entry;
  Timer? _hideTimer;
  bool _targetHovered = false;
  bool _overlayHovered = false;

  @override
  void didUpdateWidget(covariant _HoverPathText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled || widget.path != oldWidget.path) {
      _hideOverlay();
    } else {
      _entry?.markNeedsBuild();
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _hideOverlay();
    super.dispose();
  }

  void _showOverlay() {
    if (!widget.enabled || _entry != null) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    _entry = OverlayEntry(
      builder: (overlayContext) => Positioned.fill(
        child: Stack(
          children: [
            CompositedTransformFollower(
              link: _layerLink,
              showWhenUnlinked: false,
              targetAnchor: Alignment.bottomLeft,
              followerAnchor: Alignment.topLeft,
              offset: const Offset(0, 8),
              child: MouseRegion(
                onEnter: (_) {
                  _overlayHovered = true;
                  _hideTimer?.cancel();
                },
                onExit: (_) {
                  _overlayHovered = false;
                  _scheduleHide();
                },
                child: Material(
                  color: Colors.transparent,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minWidth: 320,
                      maxWidth: 560,
                    ),
                    child: AppSurface(
                      radius: AppRadius.lg,
                      padding: const EdgeInsets.all(14),
                      color: Theme.of(overlayContext)
                          .colorScheme
                          .surface
                          .withValues(alpha: 0.96),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.folder_open_rounded,
                            size: 18,
                            color: Theme.of(overlayContext).colorScheme.primary,
                          ),
                          const SizedBox(width: AppGap.sm),
                          Expanded(
                            child: SelectableText(
                              widget.path,
                              style: AppText.bodySmall.copyWith(
                                color: sectionTextColor(overlayContext),
                                height: 1.35,
                              ),
                            ),
                          ),
                          const SizedBox(width: AppGap.sm),
                          IconButton.filledTonal(
                            tooltip: "复制路径",
                            icon: const Icon(Icons.copy_rounded, size: 17),
                            onPressed: _copyPath,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    overlay.insert(_entry!);
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 160), () {
      if (!_targetHovered && !_overlayHovered) {
        _hideOverlay();
      }
    });
  }

  void _hideOverlay() {
    _hideTimer?.cancel();
    _hideTimer = null;
    _entry?.remove();
    _entry = null;
  }

  Future<void> _copyPath() async {
    await Clipboard.setData(ClipboardData(text: widget.path));
    _hideOverlay();
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text("路径已复制")),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: MouseRegion(
        cursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) {
          _targetHovered = true;
          _hideTimer?.cancel();
          _showOverlay();
        },
        onExit: (_) {
          _targetHovered = false;
          _scheduleHide();
        },
        child: Text(
          widget.path,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: widget.style,
        ),
      ),
    );
  }
}
