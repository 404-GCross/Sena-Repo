/// Settings screen with menu-like sub-pages.

import "package:flutter/material.dart";
import "package:provider/provider.dart";
import "package:http/http.dart" as http;
import "package:shared_preferences/shared_preferences.dart";
import "dart:convert";

import "../providers/game_provider.dart";
import "../services/api_client.dart";
import "beautify_screen.dart";

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
          _section("服务端"),
          _menuItem(Icons.manage_search, "扫描设置", "根目录、扫描选项",
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => _ScanSettingsPage(api: _api)))),
          _menuItem(Icons.image_search, "刮削源", "元数据来源与代理",
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => _ScraperPage(api: _api)))),
          if (_isAdmin)
            _menuItem(Icons.people, "用户管理", "审批注册申请",
              () => Navigator.push(context, MaterialPageRoute(builder: (_) => _UserManagePage(api: _api)))),
          const SizedBox(height: 24),
          _section("客户端"),
          _menuItem(Icons.grid_view, "显示", "封面大小调整",
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => const _DisplayPage()))),
          _menuItem(Icons.palette, "美化", "背景图片与主题色",
            () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BeautifyScreen()))),
          const SizedBox(height: 32),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              Icon(Icons.info_outline, size: 18, color: Colors.grey[500]),
              const SizedBox(width: 8),
              Text("Sena Repo v0.1.0", style: TextStyle(color: Colors.grey[500], fontSize: 14)),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _section(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
    child: Text(t, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey[500])),
  );

  Widget _menuItem(IconData icon, String title, String subtitle, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title, style: const TextStyle(fontSize: 15)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: onTap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
  }
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

  @override
  void initState() { super.initState(); _loadRoots(); }

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

  Future<void> _scrapeNow() async {
    await http.post(Uri.parse("${widget.api.baseUrl}/api/scrape/batch"),
        headers: {"Content-Type": "application/json"}, body: jsonEncode({}));
    if (mounted) _toast(context, "刮削已触发");
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
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: Row(children: [
              Icon(Icons.folder, size: 20, color: Colors.grey[500]),
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
                  borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
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
        const SizedBox(height: 24),

        // ── Options ──
        _sectionHeader("选项", Icons.tune),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: Column(children: [
            ListTile(
              title: const Text("目录结构", style: TextStyle(fontSize: 14)),
              subtitle: Text(
                _structure == "company_game" ? "会社 / 游戏" : _structure == "game_only" ? "仅游戏" : "扁平",
                style: TextStyle(fontSize: 13, color: Colors.grey[500]),
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
                  style: TextStyle(fontSize: 13, color: Colors.grey[500])),
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
      ],
    ),
  );

  Widget _sectionHeader(String title, IconData icon) => Row(children: [
    Icon(icon, size: 18, color: Colors.white60),
    const SizedBox(width: 6),
    Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white70)),
  ]);

  Widget _hintCard(String text) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.03),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
    ),
    child: Row(children: [
      Icon(Icons.info_outline, size: 18, color: Colors.grey[500]),
      const SizedBox(width: 8),
      Text(text, style: TextStyle(fontSize: 14, color: Colors.grey[500])),
    ]),
  );

  Widget _divider() => Divider(height: 1, thickness: 0.5, color: Colors.white.withValues(alpha: 0.06));
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
    appBar: AppBar(title: const Text("刮削源"), actions: [IconButton(icon: const Icon(Icons.save), onPressed: _save)]),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      _row("VNDB Kana v2（免认证）", "vndb_kana", false),
      _row("Bangumi（免认证）", "bangumi", false),
      _row("Steam（免认证）", "steam", false),
      _row("DLsite（免认证）", "dlsite", false),
      _row("IGDB（需要 Client ID/Secret）", "igdb", true, key1: "igdb_client_id", key2: "igdb_client_secret"),
      const SizedBox(height: 24),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _keys["proxy"],
              decoration: const InputDecoration(
                labelText: "HTTP 代理",
                hintText: "http://127.0.0.1:7890",
                helperText: "刮削源走代理访问（如日本代理）",
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: _testProxy,
            child: const Text("测试"),
          ),
        ]),
      ),
    ]));

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

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _coverSize = prefs.getDouble("cover_size") ?? 200);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text("显示")),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      ListTile(
        title: Text("封面大小: ${_coverSize.round()}px"),
        subtitle: Slider(
          value: _coverSize, min: 100, max: 300, divisions: 20,
          onChanged: (v) async {
            setState(() => _coverSize = v);
            await SharedPreferences.getInstance().then((p) => p.setDouble("cover_size", v));
          },
        ),
      ),
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
  List<Map<String, dynamic>> _pending = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _loadPending(); }

  Future<void> _loadPending() async {
    setState(() => _loading = true);
    try {
      final resp = await http.get(Uri.parse("${widget.api.baseUrl}/api/auth/pending"));
      if (resp.statusCode == 200) {
        _pending = (jsonDecode(resp.body) as List).cast<Map<String, dynamic>>();
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
      _loadPending();
      if (mounted) _toast(context, approve ? "已通过" : "已拒绝");
    } catch (_) {
      if (mounted) _toast(context, "操作失败");
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text("用户管理")),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _pending.isEmpty
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.people_outline, size: 64, color: Colors.grey[600]),
                  const SizedBox(height: 12),
                  Text("暂无待审批用户", style: TextStyle(fontSize: 16, color: Colors.grey[500])),
                ]))
            : ListView(padding: const EdgeInsets.all(16), children: [
                Text("待审批 (${_pending.length})", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                ..._pending.map((u) => Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                  ),
                  child: Row(children: [
                    CircleAvatar(
                      radius: 20,
                      child: Text((u["username"]?.toString() ?? "?")[0].toUpperCase()),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(u["username"] ?? "?", style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                        Text(u["is_admin"] == true ? "申请管理员" : "普通用户",
                            style: TextStyle(fontSize: 13, color: Colors.grey[500])),
                      ]),
                    ),
                    TextButton(
                      onPressed: () => _approve(u["id"] as int, false),
                      child: const Text("拒绝", style: TextStyle(color: Colors.red)),
                    ),
                    const SizedBox(width: 4),
                    FilledButton(
                      onPressed: () => _approve(u["id"] as int, true),
                      child: const Text("通过"),
                    ),
                  ]),
                )),
              ]),
  );
}

void _toast(BuildContext ctx, String msg) {
  showDialog(context: ctx, builder: (c) => AlertDialog(content: Text(msg), actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text("确定"))]));
}
