/// Settings screen with menu-like sub-pages.

import "package:flutter/material.dart";
import "package:provider/provider.dart";
import "package:http/http.dart" as http;
import "package:shared_preferences/shared_preferences.dart";
import "dart:convert";

import "../providers/game_provider.dart";
import "../providers/theme_provider.dart";
import "../utils/theme_utils.dart";
import "../services/api_client.dart";
import "beautify_screen.dart";
import "log_screen.dart";
import "profile_edit_screen.dart";

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late ApiClient _api;
  bool _isAdmin = false;

  @override
  void initState() {
    super.initState();
    _api = context.read<GameProvider>().api;
    _loadIsAdmin();
  }

  Future<void> _loadIsAdmin() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _isAdmin = prefs.getBool("is_admin") ?? false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("设置")),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionHeader("客户端", Icons.phone_android_outlined),
          const SizedBox(height: 8),
          _menuCard([
            _menuItem(Icons.person, Colors.indigo, "个人信息", "修改用户名、密码、头像",
              () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfileEditScreen()))),
            _menuItem(Icons.grid_view, Colors.teal, "显示", "封面大小、托盘设置",
              () => Navigator.push(context, MaterialPageRoute(builder: (_) => const _DisplayPage()))),
            _menuItem(Icons.palette, Colors.pink, "美化", "背景图片与主题色",
              () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BeautifyScreen()))),
            _menuItem(Icons.bug_report, Colors.grey, "日志", "查看客户端运行日志",
              () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LogScreen()))),
          ]),
          const SizedBox(height: 24),
          _sectionHeader("服务端", Icons.dns_outlined),
          const SizedBox(height: 8),
          _menuCard([
            _menuItem(Icons.manage_search, Colors.blue, "扫描设置", "根目录、刮削源、扫描选项",
              () => Navigator.push(context, MaterialPageRoute(builder: (_) => _ScanSettingsPage(api: _api)))),
            _menuItem(Icons.people, Colors.purple, "用户管理", "管理全部用户",
              () {
                if (!_isAdmin) {
                  showDialog(context: context, builder: (c) => AlertDialog(
                    title: const Text("权限不足"),
                    content: const Text("用户管理仅限管理员使用"),
                    actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text("确定"))],
                  ));
                  return;
                }
                Navigator.push(context, MaterialPageRoute(builder: (_) => _UserManagePage(api: _api)));
              }),
          ]),
          const SizedBox(height: 32),
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: cardBg(context),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.info_outline, size: 16, color: Colors.grey[600]),
                const SizedBox(width: 6),
                Text("Sena Repo v0.1.0", style: TextStyle(color: Colors.grey[600], fontSize: 13)),
              ]),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  static Color _dimColor(BuildContext c) => Colors.black54;
  static Color _boldColor(BuildContext c) => Colors.black87;

  Widget _sectionHeader(String title, IconData icon) => Row(children: [
    Icon(icon, size: 18, color: _dimColor(context)),
    const SizedBox(width: 6),
    Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _boldColor(context))),
  ]);

  Widget _menuCard(List<Widget> children) => Container(
    decoration: BoxDecoration(
      color: cardBg(context),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: cardBorder(context)),
    ),
    child: Column(
      children: children.asMap().entries.map((e) {
        final isLast = e.key == children.length - 1;
        return Column(children: [
          e.value,
          if (!isLast) Divider(height: 1, indent: 60, color: cardBorder(context)),
        ]);
      }).toList(),
    ),
  );

  Widget _menuItem(IconData icon, Color color, String title, String subtitle, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 20, color: color.withValues(alpha: 0.9)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(fontSize: 12, color: hintColor(context))),
            ]),
          ),
          Icon(Icons.chevron_right, color: Colors.grey[600], size: 20),
        ]),
      ),
    );
  }
}

// ── Batch scrape config dialog ──
class _BatchScrapeDialog extends StatefulWidget {
  @override State<_BatchScrapeDialog> createState() => _BatchScrapeDialogState();
}

class _BatchScrapeDialogState extends State<_BatchScrapeDialog> {
  String _scope = "missing"; // missing, all, filtered
  final _sources = {"vndb_kana": true, "bangumi": true, "steam": true, "dlsite": true};

  static const _sourceLabels = {
    "vndb_kana": "VNDB Kana v2", "bangumi": "Bangumi",
    "steam": "Steam", "dlsite": "DLsite",
  };

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Row(children: [
        Icon(Icons.image_search, color: Colors.orange, size: 22),
        SizedBox(width: 8),
        Text("批量刮削"),
      ]),
      content: SizedBox(width: 380, child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Scope selection
          _sectionTitle("刮削范围"),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: cardBg(context),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: cardBorder(context)),
            ),
            child: Column(children: [
              _radioTile("missing", "缺失封面的游戏", Icons.broken_image_outlined, "只刮削没有封面的游戏"),
              _divider(),
              _radioTile("all", "全部游戏", Icons.select_all, "重刮所有游戏，覆盖已有封面"),
              _divider(),
              _radioTile("filtered", "当前筛选结果", Icons.filter_list, "只刮当前筛选出的游戏"),
            ]),
          ),
          const SizedBox(height: 16),
          // Source selection
          _sectionTitle("刮削来源"),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: cardBg(context),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: cardBorder(context)),
            ),
            child: Column(children:
              _sources.keys.map((src) {
                final isLast = src == _sources.keys.last;
                return Column(children: [
                  CheckboxListTile(
                    title: Text(_sourceLabels[src] ?? src, style: const TextStyle(fontSize: 14)),
                    value: _sources[src],
                    onChanged: (v) => setState(() => _sources[src] = v ?? false),
                    dense: true,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  if (!isLast) _divider(),
                ]);
              }).toList(),
            ),
          ),
        ]),
      )),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("取消")),
        FilledButton.icon(
          onPressed: () {
            Navigator.pop(context, {
              "scope": _scope,
              "sources": _sources.entries.where((e) => e.value).map((e) => e.key).toList(),
            });
          },
          icon: const Icon(Icons.play_arrow, size: 18),
          label: const Text("开始刮削"),
        ),
      ],
    );
  }

  Widget _radioTile(String value, String title, IconData icon, String subtitle) {
    final active = _scope == value;
    return InkWell(
      onTap: () => setState(() => _scope = value),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: active ? Colors.orange.withValues(alpha: 0.15) : cardBg(context),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 20, color: active ? Colors.orange[300] : Colors.grey[500]),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontSize: 14, fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
            Text(subtitle, style: TextStyle(fontSize: 12, color: hintColor(context))),
          ])),
          Radio<String>(value: value, groupValue: _scope, onChanged: (v) => setState(() => _scope = v!)),
        ]),
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 4, left: 4),
    child: Text(t, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: subTextColor(context))),
  );

  Widget _divider() => Divider(height: 1, indent: 48, color: cardBorder(context));
}

// ── Scan Settings Sub-Page ──
class _ScanSettingsPage extends StatefulWidget {
  final ApiClient api;
  const _ScanSettingsPage({required this.api});
  @override State<_ScanSettingsPage> createState() => _ScanSettingsPageState();
}

class _ScanSettingsPageState extends State<_ScanSettingsPage> {
  List<Map<String, dynamic>> _roots = [];
  final _dirCtrl = TextEditingController();
  String _structure = "company_game";
  bool _autoScan = false;
  int _interval = 24;
  bool _loading = false;
  Map<String, dynamic>? _scrapeJob;
  bool _scraping = false;
  // Scraper sources
  final _sources = {"vndb_kana": true, "bangumi": true, "steam": true, "dlsite": true, "igdb": false};
  final _keys = {"vndb_token": TextEditingController(), "igdb_client_id": TextEditingController(), "igdb_client_secret": TextEditingController(), "proxy": TextEditingController()};

  @override
  void initState() { super.initState(); _loadRoots(); _loadScraperSettings(); _checkActiveJob(); }

  Future<void> _loadRoots() async {
    setState(() => _loading = true);
    try {
      final resp = await http.get(Uri.parse("${widget.api.baseUrl}/api/roots"));
      if (resp.statusCode == 200) {
        _roots = (jsonDecode(resp.body) as List).cast<Map<String, dynamic>>();
      }
    } catch (_) {}
    setState(() => _loading = false);
  }

  Future<void> _addRoot() async {
    final p = _dirCtrl.text.trim(); if (p.isEmpty) return;
    await http.post(Uri.parse("${widget.api.baseUrl}/api/roots"),
        headers: {"Content-Type": "application/json"}, body: jsonEncode({"path": p}));
    _dirCtrl.clear(); _loadRoots();
  }

  Future<void> _delRoot(int id) async {
    await http.delete(Uri.parse("${widget.api.baseUrl}/api/roots/$id"));
    _loadRoots();
  }

  Future<void> _scanNow() async {
    setState(() => _loading = true);
    await http.post(Uri.parse("${widget.api.baseUrl}/api/roots/refresh-all"));
    _loadRoots();
    if (mounted) _toast(context, "扫描已触发");
  }

  Future<void> _checkActiveJob() async {
    try {
      final resp = await http.get(Uri.parse("${widget.api.baseUrl}/api/scrape/jobs"));
      if (resp.statusCode == 200) {
        final jobs = (jsonDecode(resp.body) as List).cast<Map<String, dynamic>>();
        final running = jobs.cast<Map<String, dynamic>?>().firstWhere(
          (j) => j?["status"] == "running" || j?["status"] == "pending",
          orElse: () => null,
        );
        if (running != null && mounted) {
          setState(() { _scrapeJob = running; _scraping = true; });
          _pollJob(running["id"] as int);
        }
      }
    } catch (_) {}
  }

  Future<void> _scrapeNow() async {
    // Show batch scrape config dialog
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _BatchScrapeDialog(),
    );
    if (result == null || !mounted) return;
    setState(() => _scraping = true);
    try {
      final resp = await http.post(Uri.parse("${widget.api.baseUrl}/api/scrape/batch"),
          headers: {"Content-Type": "application/json"}, body: jsonEncode(result));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final jobId = data["job_id"] as int;
        if (mounted) _pollJob(jobId);
      }
    } catch (_) {
      if (mounted) _toast(context, "刮削启动失败");
      setState(() => _scraping = false);
    }
  }

  Future<void> _pollJob(int jobId) async {
    while (mounted) {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      try {
        final resp = await http.get(Uri.parse("${widget.api.baseUrl}/api/scrape/jobs/$jobId"));
        if (resp.statusCode == 200) {
          final job = jsonDecode(resp.body) as Map<String, dynamic>;
          if (mounted) setState(() => _scrapeJob = job);
          if (job["status"] == "completed" || job["status"] == "failed") {
            if (mounted) _scraping = false;
            return;
          }
        }
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text("扫描设置")),
    body: _loading ? const Center(child: CircularProgressIndicator()) : ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── Root directories ──
        _sectionHeader("根目录", Icons.folder_outlined),
        const SizedBox(height: 8),
        if (_roots.isEmpty)
          _hintCard("暂无根目录，请在下方添加")
        else
          ..._roots.map((r) => Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: cardBg(context),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: cardBorder(context)),
            ),
            child: Row(children: [
              Icon(Icons.folder, size: 20, color: hintColor(context)),
              const SizedBox(width: 10),
              Expanded(child: Text(r["path"] ?? "", style: const TextStyle(fontSize: 14))),
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                onPressed: () => _delRoot(r["id"] as int),
                tooltip: "删除",
              ),
            ]),
          )),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _dirCtrl,
              decoration: InputDecoration(
                hintText: "添加路径，如 /mnt/nas/games",
                hintStyle: TextStyle(fontSize: 13, color: Colors.grey[600]),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: cardBorder(context)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: cardBorder(context)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _addRoot,
            icon: const Icon(Icons.add, size: 18),
            label: const Text("添加"),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ]),
        const SizedBox(height: 24),

        // ── Actions ──
        _sectionHeader("操作", Icons.play_arrow_outlined),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: FilledButton.tonalIcon(
              onPressed: _scanNow,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text("开始扫描"),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _scrapeNow,
              icon: const Icon(Icons.image_search, size: 18),
              label: const Text("批量刮削"),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ]),

        // ── Scrape job progress ──
        if (_scrapeJob != null) ...[
          const SizedBox(height: 20),
          _sectionHeader("刮削进度", Icons.cloud_sync),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cardBg(context),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: cardBorder(context)),
            ),
            child: Column(children: [
              Row(children: [
                _jobStatusIcon(_scrapeJob!["status"]),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_jobStatusLabel(_scrapeJob!["status"]),
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    if (_scrapeJob!["current_game"] != null)
                      Text("正在处理: ${_scrapeJob!["current_game"]}",
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: hintColor(context))),
                  ]),
                ),
                if (_scrapeJob!["status"] == "running" || _scrapeJob!["status"] == "pending")
                  TextButton(
                    onPressed: () => _cancelJob(_scrapeJob!["id"] as int),
                    child: const Text("取消", style: TextStyle(fontSize: 12, color: Colors.red)),
                  ),
              ]),
              if (_scrapeJob!["total_games"] != null && (_scrapeJob!["total_games"] as int) > 0) ...[
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: ((_scrapeJob!["completed_games"] ?? 0) as int) /
                        ((_scrapeJob!["total_games"] as int)).clamp(1, 99999),
                    minHeight: 6,
                    backgroundColor: cardBorder(context),
                  ),
                ),
                const SizedBox(height: 6),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text("${_scrapeJob!["completed_games"]} / ${_scrapeJob!["total_games"]}",
                      style: TextStyle(fontSize: 12, color: hintColor(context))),
                  if (_scrapeJob!["failed_games"] != null && (_scrapeJob!["failed_games"] as int) > 0)
                    Text("失败: ${_scrapeJob!["failed_games"]}",
                        style: TextStyle(fontSize: 12, color: Colors.red[300])),
                ]),
              ],
              // Completed summary
              if (_scrapeJob!["status"] == "completed")
                _buildCompletedSummary(),
            ]),
          ),
        ],

        const SizedBox(height: 24),

        // ── Options ──
        _sectionHeader("选项", Icons.tune),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: cardBg(context),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cardBorder(context)),
          ),
          child: Column(children: [
            ListTile(
              title: const Text("目录结构", style: TextStyle(fontSize: 14)),
              subtitle: Text(
                _structure == "company_game" ? "会社 / 游戏" : _structure == "game_only" ? "仅游戏" : "扁平",
                style: TextStyle(fontSize: 13, color: hintColor(context)),
              ),
              trailing: DropdownButton<String>(
                value: _structure, underline: const SizedBox(),
                items: const [
                  DropdownMenuItem(value: "company_game", child: Text("会社 / 游戏")),
                  DropdownMenuItem(value: "game_only", child: Text("仅游戏")),
                  DropdownMenuItem(value: "flat", child: Text("扁平")),
                ],
                onChanged: (v) => setState(() => _structure = v!),
              ),
            ),
            _divider(),
            SwitchListTile(
              title: const Text("自动扫描", style: TextStyle(fontSize: 14)),
              subtitle: Text(_autoScan ? "每 $_interval 小时" : "关闭",
                  style: TextStyle(fontSize: 13, color: hintColor(context))),
              value: _autoScan,
              onChanged: (v) => setState(() => _autoScan = v),
              dense: true,
            ),
            if (_autoScan) ...[
              _divider(),
              ListTile(
                title: const Text("扫描间隔（小时）", style: TextStyle(fontSize: 14)),
                trailing: SizedBox(
                  width: 80,
                  child: TextField(
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: "$_interval",
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onChanged: (v) {
                      final n = int.tryParse(v);
                      if (n != null && n > 0) setState(() => _interval = n);
                    },
                  ),
                ),
              ),
            ],
          ]),
        ),

        // ── Scraper sources ──
        const SizedBox(height: 24),
        _sectionHeader("刮削源", Icons.image_search),
        const SizedBox(height: 8),
        _srcCard("VNDB Kana v2", "vndb_kana", "免认证，中文标题"),
        _srcCard("Bangumi", "bangumi", "免认证，填 Token 提速率"),
        _srcCard("Steam", "steam", "免认证"),
        _srcCard("DLsite", "dlsite", "免认证，建议配日本代理"),
        _srcCard("IGDB", "igdb", "需要 Client ID / Secret", needsApi: true, key1: "igdb_client_id", key2: "igdb_client_secret"),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: cardBg(context),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cardBorder(context)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text("HTTP 代理", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: subTextColor(context))),
            Text("刮削源通过代理访问，如日本代理", style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(controller: _keys["proxy"],
                  decoration: InputDecoration(hintText: "http://127.0.0.1:7890", isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: _testProxy, child: const Text("测试"),
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              ),
            ]),
          ]),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _saveScraperConfig,
          icon: const Icon(Icons.save, size: 18),
          label: const Text("保存刮削配置"),
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      ],
    ),
  );

  Widget _sectionHeader(String title, IconData icon) => Row(children: [
    Icon(icon, size: 18, color: sectionIconColor(context)),
    const SizedBox(width: 6),
    Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: sectionTextColor(context))),
  ]);

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
      Text(text, style: TextStyle(fontSize: 14, color: hintColor(context))),
    ]),
  );

  Widget _divider() => Divider(height: 1, thickness: 0.5, color: cardBorder(context));

  Widget _jobStatusIcon(String? status) {
    switch (status) {
      case "running": return Icon(Icons.sync, size: 24, color: Colors.blue[300]);
      case "completed": return Icon(Icons.check_circle, size: 24, color: Colors.green[300]);
      case "failed": return Icon(Icons.error, size: 24, color: Colors.red[300]);
      default: return Icon(Icons.schedule, size: 24, color: subTextColor(context));
    }
  }

  Future<void> _cancelJob(int jobId) async {
    try {
      await http.post(Uri.parse("${widget.api.baseUrl}/api/scrape/jobs/$jobId/cancel"));
      setState(() => _scraping = false);
    } catch (_) {}
  }

  Widget _buildCompletedSummary() {
    final failed = (_scrapeJob!["failed_games"] ?? 0) as int;
    final total = (_scrapeJob!["total_games"] ?? 0) as int;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        Icon(Icons.check_circle, size: 16, color: Colors.green[300]),
        const SizedBox(width: 6),
        Text("${total - failed} 成功, $failed 失败",
            style: TextStyle(fontSize: 12, color: subTextColor(context))),
      ]),
    );
  }

  String _jobStatusLabel(String? status) {
    switch (status) {
      case "pending": return "等待开始...";
      case "running": return "正在刮削...";
      case "completed": return "刮削完成";
      case "failed": return "刮削失败";
      default: return status ?? "未知";
    }
  }

  // ── Scraper settings ──

  Future<void> _loadScraperSettings() async {
    try {
      final resp = await http.get(Uri.parse("${widget.api.baseUrl}/api/settings/scraper"));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        for (final k in _keys.keys) { _keys[k]?.text = data[k] ?? ""; }
      }
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    for (final src in _sources.keys) {
      final v = prefs.getBool("scrape_src_$src");
      if (v != null) _sources[src] = v;
    }
    if (mounted) setState(() {});
  }

  Future<void> _saveScraperConfig() async {
    final body = <String, String>{};
    for (final k in _keys.keys) { body[k] = _keys[k]!.text; }
    await http.put(Uri.parse("${widget.api.baseUrl}/api/settings/scraper"),
        headers: {"Content-Type": "application/json"}, body: jsonEncode(body));
    final prefs = await SharedPreferences.getInstance();
    for (final src in _sources.keys) {
      await prefs.setBool("scrape_src_$src", _sources[src] ?? false);
    }
    if (mounted) _toast(context, "刮削源配置已保存");
  }

  Future<void> _testProxy() async {
    try {
      final resp = await http.post(Uri.parse("${widget.api.baseUrl}/api/settings/proxy-test"));
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (mounted) _toast(context, data["ok"] == true
          ? "连接成功: ${data["latency_ms"]}ms"
          : "连接失败: ${data["error"]}");
    } catch (e) { if (mounted) _toast(context, "$e"); }
  }

  Widget _srcCard(String label, String src, String hint, {bool needsApi = false, String? key1, String? key2}) {
    final enabled = _sources[src] ?? false;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: cardBg(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: enabled ? Colors.green.withValues(alpha: 0.15) : cardBorder(context)),
      ),
      child: Column(children: [
        SwitchListTile(
          title: Text(label, style: const TextStyle(fontSize: 14)),
          subtitle: Text(hint, style: TextStyle(fontSize: 12, color: hintColor(context))),
          value: enabled,
          onChanged: (v) => setState(() => _sources[src] = v),
          dense: true,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        if (enabled && needsApi) ...[
          Divider(height: 1, indent: 56, color: cardBorder(context)),
          Padding(
            padding: const EdgeInsets.fromLTRB(56, 8, 16, 12),
            child: Column(children: [
              if (key1 != null)
                Padding(padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(controller: _keys[key1], decoration: InputDecoration(labelText: _kl(key1), isDense: true)),
                ),
              if (key2 != null)
                TextField(controller: _keys[key2], decoration: InputDecoration(labelText: _kl(key2), isDense: true)),
            ]),
          ),
        ],
      ]),
    );
  }

  static const _keyLabels = {"igdb_client_id": "IGDB Client ID", "igdb_client_secret": "IGDB Client Secret"};
  String _kl(String k) => _keyLabels[k] ?? k;

  @override
  void dispose() {
    _dirCtrl.dispose();
    for (final c in _keys.values) { c.dispose(); }
    super.dispose();
  }
}

// ── Scraper Sub-Page ──
class _ScraperPage extends StatefulWidget {
  final ApiClient api;
  const _ScraperPage({required this.api});
  @override State<_ScraperPage> createState() => _ScraperPageState();
}

class _ScraperPageState extends State<_ScraperPage> {
  final _sources = {"vndb_kana": true, "bangumi": true, "steam": true, "dlsite": true, "igdb": false};
  final _keys = {"vndb_token": TextEditingController(), "igdb_client_id": TextEditingController(), "igdb_client_secret": TextEditingController(), "proxy": TextEditingController()};

  @override
  void initState() { super.initState(); _loadSettings(); }

  Future<void> _loadSettings() async {
    try {
      final resp = await http.get(Uri.parse("${widget.api.baseUrl}/api/settings/scraper"));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        for (final k in _keys.keys) { _keys[k]?.text = data[k] ?? ""; }
      }
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    for (final src in _sources.keys) {
      final v = prefs.getBool("scrape_src_$src");
      if (v != null) _sources[src] = v;
    }
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    final body = <String, String>{};
    for (final k in _keys.keys) { body[k] = _keys[k]!.text; }
    await http.put(Uri.parse("${widget.api.baseUrl}/api/settings/scraper"),
        headers: {"Content-Type": "application/json"}, body: jsonEncode(body));

    final prefs = await SharedPreferences.getInstance();
    for (final src in _sources.keys) {
      await prefs.setBool("scrape_src_$src", _sources[src] ?? false);
    }

    if (mounted) _toast(context, "已保存");
  }

  Widget _row(String label, String src, bool needsApi, {String? key1, String? key2, String hint = ""}) {
    final children = <Widget>[
      SwitchListTile(title: Text(label), value: _sources[src] ?? false, onChanged: (v) => setState(() => _sources[src] = v), dense: true),
    ];
    if (_sources[src] == true && needsApi) {
      if (key1 != null) {
        children.add(Padding(padding: const EdgeInsets.only(left: 16, right: 16, bottom: 4),
            child: TextField(controller: _keys[key1], decoration: InputDecoration(labelText: _kl(key1), hintText: hint, isDense: true))));
      }
      if (key2 != null) {
        children.add(Padding(padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
            child: TextField(controller: _keys[key2], decoration: InputDecoration(labelText: _kl(key2), isDense: true))));
      }
    }
    return Column(children: children);
  }

  static const _keyLabels = {
    "bangumi_token": "Bangumi Token", "vndb_token": "VNDB Token",
    "igdb_client_id": "IGDB Client ID",
    "igdb_client_secret": "IGDB Client Secret",
  };

  String _kl(String k) => _keyLabels[k] ?? k;

  Future<void> _testProxy() async {
    try {
      final resp = await http.post(Uri.parse("${widget.api.baseUrl}/api/settings/proxy-test"));
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (mounted) {
        _toast(context, data["ok"] == true
            ? "连接成功: ${data["latency_ms"]}ms (${data["proxy"]})"
            : "连接失败: ${data["error"]}");
      }
    } catch (e) {
      if (mounted) _toast(context, "$e");
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text("刮削源"), actions: [
      FilledButton.icon(
        onPressed: _save,
        icon: const Icon(Icons.save, size: 18),
        label: const Text("保存"),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        ),
      ),
      const SizedBox(width: 8),
    ]),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      _sectionHeader("刮削源", Icons.image_search),
      const SizedBox(height: 8),
      _srcCard("VNDB Kana v2", "vndb_kana", "免认证，中文标题"),
      _srcCard("Bangumi", "bangumi", "免认证，填 Token 提速率"),
      _srcCard("Steam", "steam", "免认证"),
      _srcCard("DLsite", "dlsite", "免认证，建议配日本代理"),
      _srcCard("IGDB", "igdb", "需要 Client ID / Secret", needsApi: true,
          key1: "igdb_client_id", key2: "igdb_client_secret"),
      const SizedBox(height: 28),
      _sectionHeader("HTTP 代理", Icons.dns_outlined),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cardBg(context),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cardBorder(context)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text("刮削源通过代理访问，如日本代理", style: TextStyle(fontSize: 12, color: hintColor(context))),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _keys["proxy"],
                decoration: InputDecoration(
                  hintText: "http://127.0.0.1:7890",
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: cardBorder(context)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: cardBorder(context)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _testProxy,
              icon: const Icon(Icons.wifi_find, size: 18),
              label: const Text("测试"),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ]),
        ]),
      ),
      const SizedBox(height: 32),
    ]));

  Widget _srcCard(String label, String src, String hint, {bool needsApi = false, String? key1, String? key2}) {
    final enabled = _sources[src] ?? false;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: cardBg(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: enabled
            ? Colors.green.withValues(alpha: 0.2)
            : cardBorder(context)),
      ),
      child: Column(children: [
        SwitchListTile(
          title: Text(label, style: const TextStyle(fontSize: 14)),
          subtitle: Text(hint, style: TextStyle(fontSize: 12, color: hintColor(context))),
          value: enabled,
          onChanged: (v) => setState(() => _sources[src] = v),
          dense: true,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        if (enabled && needsApi) ...[
          Divider(height: 1, indent: 56, color: cardBorder(context)),
          Padding(
            padding: const EdgeInsets.fromLTRB(56, 8, 16, 12),
            child: Column(children: [
              if (key1 != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    controller: _keys[key1],
                    decoration: InputDecoration(
                      labelText: _kl(key1), isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: cardBorder(context)),
                      ),
                    ),
                  ),
                ),
              if (key2 != null)
                TextField(
                  controller: _keys[key2],
                  decoration: InputDecoration(
                    labelText: _kl(key2), isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: cardBorder(context)),
                    ),
                  ),
                ),
            ]),
          ),
        ],
      ]),
    );
  }

  Widget _sectionHeader(String title, IconData icon) => Row(children: [
    Icon(icon, size: 18, color: sectionIconColor(context)),
    const SizedBox(width: 6),
    Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: sectionTextColor(context))),
  ]);

  // Remove old _row method, replaced by _srcCard

  @override
  void dispose() { for (final c in _keys.values) { c.dispose(); } super.dispose(); }
}

// ── Display Sub-Page ──
class _DisplayPage extends StatefulWidget {
  const _DisplayPage();
  @override State<_DisplayPage> createState() => _DisplayPageState();
}

class _DisplayPageState extends State<_DisplayPage> {
  double _coverSize = 200;
  bool _trayEnabled = false;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() {
      _coverSize = prefs.getDouble("cover_size") ?? 200;
      _trayEnabled = prefs.getBool("minimize_to_tray") ?? false;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text("显示")),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      _sectionTitle("封面大小"),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: cardBg(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cardBorder(context)),
        ),
        child: Column(children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.teal.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.image, size: 20, color: Colors.teal[200]),
            ),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text("${_coverSize.round()} px", style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              Text("网格封面尺寸", style: TextStyle(fontSize: 12, color: hintColor(context))),
            ])),
            Container(
              width: 32, height: 44,
              decoration: BoxDecoration(
                color: cardBorder(context),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ]),
          const SizedBox(height: 14),
          Slider(
            value: _coverSize, min: 100, max: 300, divisions: 20,
            activeColor: Theme.of(context).colorScheme.primary,
            onChanged: (v) async {
              setState(() => _coverSize = v);
              await SharedPreferences.getInstance().then((p) => p.setDouble("cover_size", v));
            },
          ),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text("100", style: TextStyle(fontSize: 11, color: Colors.grey[600])),
            Text("300", style: TextStyle(fontSize: 11, color: Colors.grey[600])),
          ]),
        ]),
      ),
      const SizedBox(height: 24),
      _sectionTitle("窗口行为"),
      const SizedBox(height: 8),
      Container(
        decoration: BoxDecoration(
          color: cardBg(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cardBorder(context)),
        ),
        child: SwitchListTile(
          title: const Text("关闭时最小化到托盘", style: TextStyle(fontSize: 14)),
          subtitle: Text(_trayEnabled ? "点击关闭按钮时隐藏到系统托盘" : "点击关闭按钮直接退出",
              style: TextStyle(fontSize: 12, color: hintColor(context))),
          value: _trayEnabled,
          onChanged: (v) async {
            setState(() => _trayEnabled = v);
            await SharedPreferences.getInstance().then((p) => p.setBool("minimize_to_tray", v));
          },
        ),
      ),
    ]),
  );

  Widget _sectionTitle(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
    child: Row(children: [
      Container(width: 3, height: 16,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 8),
      Text(t, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: sectionTextColor(context))),
    ]),
  );
}

// ── User Management Sub-Page (admin only) ──
class _UserManagePage extends StatefulWidget {
  final ApiClient api;
  const _UserManagePage({required this.api});
  @override State<_UserManagePage> createState() => _UserManagePageState();
}

class _UserManagePageState extends State<_UserManagePage> {
  List<Map<String, dynamic>> _users = [];
  bool _loading = true;
  int _currentUserId = 0;

  @override
  void initState() { super.initState(); _loadCurrentUser(); _loadUsers(); }

  Future<void> _loadCurrentUser() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString("auth_token");
    _currentUserId = int.tryParse(token ?? "") ?? 0;
  }

  Future<void> _loadUsers() async {
    setState(() => _loading = true);
    try {
      final resp = await http.get(Uri.parse("${widget.api.baseUrl}/api/auth/users"));
      if (resp.statusCode == 200) {
        _users = (jsonDecode(resp.body) as List).cast<Map<String, dynamic>>();
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _approve(int userId, bool approve) async {
    try {
      await http.post(
        Uri.parse("${widget.api.baseUrl}/api/auth/approve"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"user_id": userId, "approve": approve}),
      );
      _loadUsers();
      if (mounted) _toast(context, approve ? "已通过" : "已拒绝");
    } catch (_) {
      if (mounted) _toast(context, "操作失败");
    }
  }

  Future<void> _editUser(Map<String, dynamic> u) async {
    final nameCtrl = TextEditingController(text: u["username"] ?? "");
    final passCtrl = TextEditingController();
    bool isAdmin = u["is_admin"] == true;
    final result = await showDialog<bool>(
      context: context, builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text("编辑用户"),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: nameCtrl,
              decoration: const InputDecoration(labelText: "用户名", isDense: true)),
            const SizedBox(height: 10),
            TextField(controller: passCtrl, obscureText: true,
              decoration: const InputDecoration(labelText: "新密码（留空不修改）", isDense: true)),
            const SizedBox(height: 4),
            CheckboxListTile(
              title: const Text("管理员"),
              value: isAdmin,
              onChanged: (v) => setD(() => isAdmin = v ?? false),
              dense: true, contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
            FilledButton(onPressed: () {
              if (nameCtrl.text.trim().isEmpty) return;
              Navigator.pop(ctx, true);
            }, child: const Text("保存")),
          ],
        ),
      ),
    );
    if (result != true) return;
    try {
      final body = <String, dynamic>{"username": nameCtrl.text.trim()};
      if (passCtrl.text.isNotEmpty) body["password"] = passCtrl.text;
      body["is_admin"] = isAdmin;
      final resp = await http.put(
        Uri.parse("${widget.api.baseUrl}/api/auth/users/${u["id"]}"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(body),
      );
      if (resp.statusCode == 200) {
        _loadUsers();
        if (mounted) _toast(context, "更新成功");
      } else {
        final data = jsonDecode(resp.body);
        if (mounted) _toast(context, data["detail"] ?? "更新失败");
      }
    } catch (_) {
      if (mounted) _toast(context, "更新失败");
    }
  }

  Future<void> _deleteUser(int userId, String username) async {
    final confirmed = await showDialog<bool>(
      context: context, builder: (ctx) => AlertDialog(
        title: const Text("删除用户"),
        content: Text("确定删除用户「$username」吗？此操作不可撤销。"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("取消")),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text("删除", style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final resp = await http.delete(
        Uri.parse("${widget.api.baseUrl}/api/auth/users/$userId"),
      );
      if (resp.statusCode == 200) {
        _loadUsers();
        if (mounted) _toast(context, "已删除");
      }
    } catch (_) {
      if (mounted) _toast(context, "删除失败");
    }
  }

  String _statusLabel(String status) {
    switch (status) {
      case "active": return "已激活";
      case "pending": return "待审批";
      case "rejected": return "已拒绝";
      default: return status;
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case "active": return Colors.green;
      case "pending": return Colors.orange;
      case "rejected": return Colors.red;
      default: return Colors.grey;
    }
  }

  Future<void> _createUser() async {
    final nameCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    bool asAdmin = false;
    final result = await showDialog<bool>(
      context: context, builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text("新增用户"),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: nameCtrl, autofocus: true,
              decoration: const InputDecoration(labelText: "用户名", isDense: true)),
            const SizedBox(height: 10),
            TextField(controller: passCtrl, obscureText: true,
              decoration: const InputDecoration(labelText: "密码", isDense: true)),
            const SizedBox(height: 4),
            CheckboxListTile(
              title: const Text("设为管理员"),
              value: asAdmin,
              onChanged: (v) => setD(() => asAdmin = v ?? false),
              dense: true, contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
            FilledButton(onPressed: () {
              if (nameCtrl.text.trim().isEmpty || passCtrl.text.isEmpty) return;
              Navigator.pop(ctx, true);
            }, child: const Text("创建")),
          ],
        ),
      ),
    );
    if (result != true) return;
    try {
      final resp = await http.post(
        Uri.parse("${widget.api.baseUrl}/api/auth/users"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "username": nameCtrl.text.trim(),
          "password": passCtrl.text,
          "is_admin": asAdmin,
        }),
      );
      if (resp.statusCode == 200) {
        _loadUsers();
        if (mounted) _toast(context, "用户创建成功");
      } else {
        final data = jsonDecode(resp.body);
        if (mounted) _toast(context, data["detail"] ?? "创建失败");
      }
    } catch (_) {
      if (mounted) _toast(context, "创建失败");
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text("用户管理")),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _createUser,
      icon: const Icon(Icons.person_add),
      label: const Text("新增用户"),
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _users.isEmpty
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.people_outline, size: 64, color: Colors.grey[600]),
                  const SizedBox(height: 12),
                  Text("暂无用户", style: TextStyle(fontSize: 16, color: hintColor(context))),
                ]))
            : ListView(padding: const EdgeInsets.all(16), children: [
                Text("全部用户 (${_users.length})", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                ..._users.map((u) {
                  final username = u["username"] ?? "?";
                  final isAdmin = u["is_admin"] == true;
                  final status = u["status"] ?? "active";
                  final isPending = status == "pending";
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: cardBg(context),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: cardBorder(context)),
                    ),
                    child: Row(children: [
                      CircleAvatar(
                        radius: 20,
                        backgroundColor: _statusColor(status).withValues(alpha: 0.2),
                        child: Text(username[0].toUpperCase(),
                            style: TextStyle(color: _statusColor(status), fontWeight: FontWeight.w600)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Text(username, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                            const SizedBox(width: 8),
                            if (isAdmin)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: Colors.purple.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text("管理员", style: TextStyle(fontSize: 10, color: Colors.purple[200])),
                              ),
                          ]),
                          const SizedBox(height: 3),
                          Row(children: [
                            Container(width: 6, height: 6,
                              decoration: BoxDecoration(
                                color: _statusColor(status),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Text(_statusLabel(status), style: TextStyle(fontSize: 13, color: hintColor(context))),
                          ]),
                        ]),
                      ),
                      if (isPending) ...[
                        TextButton(
                          onPressed: () => _approve(u["id"] as int, false),
                          child: const Text("拒绝", style: TextStyle(color: Colors.red)),
                        ),
                        const SizedBox(width: 4),
                        FilledButton(
                          onPressed: () => _approve(u["id"] as int, true),
                          child: const Text("通过"),
                        ),
                      ] else
                        PopupMenuButton<String>(
                          icon: Icon(Icons.more_vert, size: 20, color: hintColor(context)),
                          onSelected: (action) {
                            if (action == "edit") _editUser(u);
                            if (action == "delete") _deleteUser(u["id"] as int, username);
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(value: "edit", child: Text("编辑")),
                            if ((u["id"] as int) != _currentUserId)
                              const PopupMenuItem(value: "delete",
                                child: Text("删除", style: TextStyle(color: Colors.red))),
                          ],
                        ),
                    ]),
                  );
                }),
              ]),
  );
}

void _toast(BuildContext ctx, String msg) {
  showDialog(context: ctx, builder: (c) => AlertDialog(content: Text(msg), actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text("确定"))]));
}
