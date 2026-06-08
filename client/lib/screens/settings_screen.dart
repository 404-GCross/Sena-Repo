/// Settings screen: root dirs, scraper config, preferences.

import "package:flutter/material.dart";
import "package:provider/provider.dart";
import "package:http/http.dart" as http;
import "package:shared_preferences/shared_preferences.dart";
import "dart:convert";

import "../providers/game_provider.dart";
import "../services/api_client.dart";

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _loading = false;
  String? _status;

  late ApiClient _api;
  List<Map<String, dynamic>> _roots = [];
  final _newRootCtrl = TextEditingController();

  // Scraper
  Map<String, bool> _sources = {
    "vndb_kana": true, "bangumi": true, "steam": true,
    "dlsite": true, "muyue": true, "steamgriddb": false, "igdb": false,
  };
  Map<String, TextEditingController> _keyCtrls = {
    "bangumi_token": TextEditingController(),
    "vndb_token": TextEditingController(),
    "steamgriddb_key": TextEditingController(),
    "igdb_client_id": TextEditingController(),
    "igdb_client_secret": TextEditingController(),
  };

  // Scan settings
  String _scanStructure = "company_game"; // company_game | game_only | flat
  bool _autoScan = false;
  int _scanInterval = 24; // hours

  // Cover size
  double _coverSize = 200; // maxCrossAxisExtent, default 200

  @override
  void initState() {
    super.initState();
    _api = context.read<GameProvider>().api;
    _keyCtrls = {
      "bangumi_token": TextEditingController(),
      "vndb_token": TextEditingController(),
      "steamgriddb_key": TextEditingController(),
      "igdb_client_id": TextEditingController(),
      "igdb_client_secret": TextEditingController(),
    };
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAll());
  }

  Future<void> _loadAll() async {
    setState(() => _loading = true);
    final prefs = await SharedPreferences.getInstance();
    _coverSize = prefs.getDouble("cover_size") ?? 200;
    await Future.wait([_loadRoots(), _loadScraperConfig()]);
    setState(() => _loading = false);
  }

  Future<void> _loadRoots() async {
    try {
      final resp = await http.get(Uri.parse("${_api.baseUrl}/api/roots"));
      if (resp.statusCode == 200) {
        final List<dynamic> data = jsonDecode(resp.body);
        _roots = data.cast<Map<String, dynamic>>();
      }
    } catch (_) {}
  }

  Future<void> _loadScraperConfig() async {
    try {
      final resp = await http.get(Uri.parse("${_api.baseUrl}/api/settings/scraper"));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        for (final key in _keyCtrls.keys) {
          _keyCtrls[key]!.text = data[key] ?? "";
        }
      }
    } catch (_) {}
  }

  Future<void> _addRoot() async {
    final path = _newRootCtrl.text.trim();
    if (path.isEmpty) return;
    try {
      final resp = await http.post(
        Uri.parse("${_api.baseUrl}/api/roots"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"path": path}),
      );
      if (resp.statusCode == 201) {
        _newRootCtrl.clear();
        await _loadRoots();
        _showStatus("已添加");
      }
    } catch (e) {
      _showStatus("添加失败: $e");
    }
  }

  Future<void> _deleteRoot(int id) async {
    try {
      await http.delete(Uri.parse("${_api.baseUrl}/api/roots/$id"));
      await _loadRoots();
      _showStatus("已删除");
    } catch (e) {
      _showStatus("删除失败: $e");
    }
  }

  Future<void> _scanAll() async {
    setState(() => _loading = true);
    try {
      await http.post(Uri.parse("${_api.baseUrl}/api/roots/refresh-all"));
      _showStatus("扫描完成");
    } catch (e) {
      _showStatus("扫描失败: $e");
    }
    setState(() => _loading = false);
  }

  Future<void> _saveScraperConfig() async {
    final body = <String, String>{};
    for (final key in _keyCtrls.keys) {
      body[key] = _keyCtrls[key]!.text;
    }
    try {
      await http.put(
        Uri.parse("${_api.baseUrl}/api/settings/scraper"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(body),
      );
      _showStatus("刮削配置已保存");
    } catch (e) {
      _showStatus("保存失败: $e");
    }
  }

  void _showStatus(String msg) {
    if (mounted) {
      setState(() => _status = msg);
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) setState(() => _status = null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("设置")),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Status
                if (_status != null)
                  Card(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_status!),
                    ),
                  ),

                // ── Root Directories ──
                _sectionHeader("根目录管理"),
                ..._roots.map((r) => ListTile(
                      title: Text(r["path"] ?? "", style: const TextStyle(fontSize: 14)),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.red),
                        onPressed: () => _deleteRoot(r["id"] as int),
                      ),
                    )),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _newRootCtrl,
                        decoration: const InputDecoration(hintText: "/games", isDense: true),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(icon: const Icon(Icons.add), onPressed: _addRoot),
                  ]),
                ),
                FilledButton.tonalIcon(
                  onPressed: _scanAll,
                  icon: const Icon(Icons.refresh),
                  label: const Text("扫描全部根目录"),
                ),
                const SizedBox(height: 24),

                // ── Scan Settings ──
                _sectionHeader("扫描设置"),
                ListTile(
                  title: const Text("目录结构"),
                  subtitle: Text(_scanStructure == "company_game"
                      ? "会社 / 游戏"
                      : _scanStructure == "game_only"
                          ? "仅游戏"
                          : "扁平（无结构）"),
                  trailing: DropdownButton<String>(
                    value: _scanStructure,
                    underline: const SizedBox(),
                    items: const [
                      DropdownMenuItem(value: "company_game", child: Text("会社 / 游戏")),
                      DropdownMenuItem(value: "game_only", child: Text("仅游戏")),
                      DropdownMenuItem(value: "flat", child: Text("扁平")),
                    ],
                    onChanged: (v) {
                      setState(() => _scanStructure = v!);
                      // TODO: save to server
                    },
                  ),
                ),
                SwitchListTile(
                  title: const Text("自动扫描"),
                  subtitle: Text(_autoScan ? "每 $_scanInterval 小时" : "关闭"),
                  value: _autoScan,
                  onChanged: (v) => setState(() => _autoScan = v),
                ),
                if (_autoScan)
                  ListTile(
                    title: const Text("扫描间隔（小时）"),
                    trailing: SizedBox(
                      width: 100,
                      child: TextField(
                        keyboardType: TextInputType.number,
                        controller: TextEditingController(text: "$_scanInterval"),
                        onSubmitted: (v) {
                          final n = int.tryParse(v);
                          if (n != null && n > 0) setState(() => _scanInterval = n);
                        },
                        decoration: const InputDecoration(isDense: true),
                      ),
                    ),
                  ),
                const SizedBox(height: 24),

                // ── Display ──
                _sectionHeader("显示"),
                ListTile(
                  title: const Text("封面大小"),
                  subtitle: Slider(
                    value: _coverSize,
                    min: 100,
                    max: 300,
                    divisions: 20,
                    label: "${_coverSize.round()}px",
                    onChanged: (v) async {
                      setState(() => _coverSize = v);
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setDouble("cover_size", v);
                    },
                  ),
                ),
                const SizedBox(height: 24),

                // ── Scraper Config ──
                _sectionHeader("刮削源"),
                _srcRow("VNDB Kana v2（免认证）", "vndb_kana", false),
                _srcRow("Bangumi", "bangumi", true,
                    keyName: "bangumi_token", hint: "https://bgm.tv/dev/app"),
                _srcRow("Steam（免认证）", "steam", false),
                _srcRow("DLsite（免认证）", "dlsite", false),
                _srcRow("muyueGalgame（免认证）", "muyue", false),
                _srcRow("SteamGridDB（需要 Key）", "steamgriddb", true,
                    keyName: "steamgriddb_key"),
                _srcRow("IGDB（需要 Client ID/Secret）", "igdb", true,
                    keyName: "igdb_client_id", keyName2: "igdb_client_secret"),
                FilledButton.tonalIcon(
                  onPressed: _saveScraperConfig,
                  icon: const Icon(Icons.save),
                  label: const Text("保存刮削配置"),
                ),
                const SizedBox(height: 32),

                // ── About ──
                _sectionHeader("关于"),
                const ListTile(
                  title: Text("Sena Repo"),
                  subtitle: Text("v0.1.0"),
                  leading: Icon(Icons.info_outline),
                ),
              ],
            ),
    );
  }

  Widget _srcRow(String label, String srcKey, bool needsApi,
      {String? keyName, String? keyName2, String hint = ""}) {
    return Column(
      children: [
        SwitchListTile(
          title: Text(label, style: const TextStyle(fontSize: 14)),
          value: _sources[srcKey] ?? false,
          onChanged: (v) => setState(() => _sources[srcKey] = v),
          dense: true,
        ),
        if (_sources[srcKey] == true && needsApi) ...[
          if (keyName != null)
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, bottom: 4),
              child: TextField(
                controller: _keyCtrls[keyName],
                decoration: InputDecoration(labelText: _keyLabel(keyName), hintText: hint, isDense: true),
              ),
            ),
          if (keyName2 != null)
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
              child: TextField(
                controller: _keyCtrls[keyName2],
                decoration: InputDecoration(labelText: _keyLabel(keyName2), isDense: true),
              ),
            ),
        ],
      ],
    );
  }

  String _keyLabel(String key) {
    const labels = {
      "bangumi_token": "Bangumi Token",
      "vndb_token": "VNDB Token",
      "steamgriddb_key": "SteamGridDB Key",
      "igdb_client_id": "IGDB Client ID",
      "igdb_client_secret": "IGDB Client Secret",
    };
    return labels[key] ?? key;
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
    );
  }

  @override
  void dispose() {
    _newRootCtrl.dispose();
    for (final c in _keyCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }
}
