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

  @override
  void initState() {
    super.initState();
    _api = context.read<GameProvider>().api;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("设置")),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _menuItem(Icons.manage_search, "扫描设置", () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => _ScanSettingsPage(api: _api)))),
          _menuItem(Icons.image_search, "刮削源", () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => _ScraperPage(api: _api)))),
          _menuItem(Icons.grid_view, "显示", () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const _DisplayPage()))),
          _menuItem(Icons.palette, "美化", () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const BeautifyScreen()))),
          const Divider(),
          const ListTile(title: Text("Sena Repo"), subtitle: Text("v0.1.0"), leading: Icon(Icons.info_outline)),
        ],
      ),
    );
  }

  Widget _menuItem(IconData icon, String title, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon), title: Text(title),
      trailing: const Icon(Icons.chevron_right), onTap: onTap,
    );
  }
}

// ── Scan Settings Sub-Page (includes root dirs) ──
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
        const Text("根目录", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        ..._roots.map((r) => ListTile(
          dense: true, title: Text(r["path"] ?? "", style: const TextStyle(fontSize: 13)),
          trailing: IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20), onPressed: () => _delRoot(r["id"] as int)),
        )),
        Row(children: [
          Expanded(child: TextField(controller: _dirCtrl, decoration: const InputDecoration(hintText: "/games", isDense: true))),
          const SizedBox(width: 8),
          IconButton.filled(icon: const Icon(Icons.add, size: 18), onPressed: _addRoot),
        ]),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(onPressed: _scanNow, icon: const Icon(Icons.refresh), label: const Text("开始扫描")),
        const SizedBox(height: 8),
        OutlinedButton.icon(onPressed: _scrapeNow, icon: const Icon(Icons.image_search), label: const Text("批量刮削")),
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 8),
        const Text("扫描选项", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        ListTile(
          title: const Text("目录结构"),
          subtitle: Text(_structure == "company_game" ? "会社 / 游戏" : _structure == "game_only" ? "仅游戏" : "扁平"),
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
        SwitchListTile(title: const Text("自动扫描"), subtitle: Text(_autoScan ? "每 $_interval 小时" : "关闭"),
            value: _autoScan, onChanged: (v) => setState(() => _autoScan = v)),
        if (_autoScan)
          ListTile(
            title: const Text("扫描间隔（小时）"),
            trailing: SizedBox(width: 80, child: TextField(
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(isDense: true),
              onSubmitted: (v) { final n = int.tryParse(v); if (n != null && n > 0) setState(() => _interval = n); },
            )),
          ),
      ],
    ),
  );
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
    // Load API keys from server
    try {
      final resp = await http.get(Uri.parse("${widget.api.baseUrl}/api/settings/scraper"));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        for (final k in _keys.keys) { _keys[k]?.text = data[k] ?? ""; }
      }
    } catch (_) {}

    // Load source toggles from SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    for (final src in _sources.keys) {
      final v = prefs.getBool("scrape_src_$src");
      if (v != null) _sources[src] = v;
    }
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    // Save API keys to server
    final body = <String, String>{};
    for (final k in _keys.keys) { body[k] = _keys[k]!.text; }
    await http.put(Uri.parse("${widget.api.baseUrl}/api/settings/scraper"),
        headers: {"Content-Type": "application/json"}, body: jsonEncode(body));

    // Save source toggles locally
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

void _toast(BuildContext ctx, String msg) {
  showDialog(context: ctx, builder: (c) => AlertDialog(content: Text(msg), actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text("确定"))]));
}

