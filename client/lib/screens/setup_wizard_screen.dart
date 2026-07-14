/// Multi-step setup wizard for first-time server initialization.

import "package:flutter/material.dart";
import "package:http/http.dart" as http;
import "package:shared_preferences/shared_preferences.dart";
import "dart:convert";

import "../utils/theme_utils.dart";
import "../services/api_client.dart";

class SetupWizardScreen extends StatefulWidget {
  final ApiClient api;
  const SetupWizardScreen({super.key, required this.api});

  @override
  State<SetupWizardScreen> createState() => _SetupWizardScreenState();
}

class _SetupWizardScreenState extends State<SetupWizardScreen> {
  int _step = 0;
  bool _loading = false;
  String? _error;

  // Step 1: Admin
  final _userCtrl = TextEditingController(text: "admin");
  final _passCtrl = TextEditingController();
  final _passConfirmCtrl = TextEditingController();

  // Step 2: Game dirs
  final _dirCtrls = <TextEditingController>[TextEditingController(text: "/games")];
  String _structure = "company_game";
  bool _autoScan = false;
  int _scanInterval = 24;

  // Step 3: Server-side Steam / patch paths
  final _patchDirCtrl = TextEditingController(text: "/steam_patch");
  final _serverSteamDirCtrl = TextEditingController();

  // Step 4: Scrapers
  final _proxyCtrl = TextEditingController();
  bool _useBangumi = true;
  bool _useVndbKana = true;
  bool _useSteam = true;
  bool _useYmgal = true;
  final _vndbCtrl = TextEditingController();

  void _next() {
    // Validate password match on step 0
    if (_step == 0 && _passCtrl.text != _passConfirmCtrl.text) {
      setState(() => _error = "两次密码不一致");
      return;
    }
    setState(() { _step++; _error = null; });
  }
  void _prev() => setState(() { _step--; _error = null; });

  void _addDir() => setState(() => _dirCtrls.add(TextEditingController()));
  void _removeDir(int i) {
    if (_dirCtrls.length > 1) setState(() => _dirCtrls.removeAt(i));
  }

  Future<void> _submit() async {
    setState(() { _loading = true; _error = null; });
    try {
      final dirs = _dirCtrls.map((c) => c.text.trim()).where((s) => s.isNotEmpty).toList();
      final resp = await http.post(
        Uri.parse("${widget.api.baseUrl}/api/setup/initialize"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "admin_username": _userCtrl.text.trim(),
          "admin_password": _passCtrl.text,
          "game_dirs": dirs,
          "steam_dir": _serverSteamDirCtrl.text.trim(),
          "patch_dir": _patchDirCtrl.text.trim(),
        }),
      );
      if (resp.statusCode != 200) {
        final body = jsonDecode(resp.body);
        setState(() { _error = body["detail"] ?? "设置失败"; _loading = false; });
        return;
      }
      // Save scraper keys
      await _saveScraperKeys();
      // Persist scraper source toggles
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool("scrape_src_vndb_kana", _useVndbKana);
      await prefs.setBool("scrape_src_bangumi", _useBangumi);
      await prefs.setBool("scrape_src_steam", _useSteam);
      await prefs.setBool("scrape_src_ymgal", _useYmgal);
      await prefs.setString("scan_structure", _structure);
      await prefs.setBool("auto_scan", _autoScan);
      if (_autoScan) await prefs.setInt("scan_interval", _scanInterval);
      // Save auto-scan settings to server (SharedPreferences is client-only, server reads scan_settings.json)
      try {
        await http.put(
          Uri.parse("${widget.api.baseUrl}/api/settings/scan"),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({"auto_scan": _autoScan, "scan_interval": _scanInterval, "scan_structure": _structure}),
        );
      } catch (_) {}
      // Scan runs in background on server — no need to wait
      if (mounted) Navigator.pop(context, {
        "username": _userCtrl.text.trim(),
        "password": _passCtrl.text,
      });
    } catch (e) {
      setState(() { _error = "$e"; _loading = false; });
    }
  }

  Future<void> _saveScraperKeys() async {
    final body = <String, String>{};
    if (_vndbCtrl.text.isNotEmpty) body["vndb_token"] = _vndbCtrl.text;
    if (body.isNotEmpty) {
      await http.put(
        Uri.parse("${widget.api.baseUrl}/api/settings/scraper"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(body),
      );
    }
  }

  static const _titles = ["创建管理员", "服务端目录", "刮削源"];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("初次设置 (${_step + 1}/3)")),
      body: Center(
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.all(24),
          child: SizedBox(
            width: 480,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Step indicator
                    Row(
                      children: List.generate(3, (i) => Expanded(child: Container(
                        height: 4,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(2),
                          color: i <= _step ? Theme.of(context).colorScheme.primary : Colors.grey[700],
                        ),
                      ))),
                    ),
                    const SizedBox(height: 16),
                    Text(_titles[_step],
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 24),

                    // ── Step content ──
                    if (_step == 0) ..._buildStep1(),
                    if (_step == 1) ..._buildStep2(),
                    if (_step == 2) ..._buildStep4(),

                    // ── Error ──
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(_error!, style: const TextStyle(color: Colors.red)),
                      ),

                    // ── Buttons ──
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        if (_step > 0)
                          OutlinedButton(onPressed: _prev, child: const Text("上一步")),
                        const Spacer(),
                        if (_step < 2)
                          FilledButton(onPressed: _next, child: const Text("下一步")),
                        if (_step == 2)
                          FilledButton(
                            onPressed: _loading ? null : _submit,
                            child: _loading
                                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Text("完成并开始扫描"),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildStep1() => [
    TextField(
      controller: _userCtrl,
      decoration: const InputDecoration(labelText: "用户名", prefixIcon: Icon(Icons.person)),
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _passCtrl,
      decoration: const InputDecoration(labelText: "密码", prefixIcon: Icon(Icons.lock)),
      obscureText: true,
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _passConfirmCtrl,
      decoration: const InputDecoration(labelText: "确认密码", prefixIcon: Icon(Icons.lock)),
      obscureText: true,
    ),
  ];

  List<Widget> _buildStep2() => [
    const Text("服务端扫描目录", style: TextStyle(fontWeight: FontWeight.bold)),
    Text("每行一个服务端路径，服务端将扫描这些目录下的游戏",
      style: AppText.label.copyWith( color: hintColor(context))),
    const SizedBox(height: 8),
    ..._dirCtrls.asMap().entries.map((e) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Expanded(child: TextField(
          controller: e.value,
          decoration: InputDecoration(
            hintText: "/games",
            prefixIcon: const Icon(Icons.folder),
            suffixIcon: _dirCtrls.length > 1
                ? IconButton(icon: const Icon(Icons.remove_circle_outline, color: Colors.red), onPressed: () => _removeDir(e.key))
                : null,
          ),
        )),
        const SizedBox(width: 4),
        IconButton.filled(icon: const Icon(Icons.add, size: 20), onPressed: _addDir),
      ]),
    )),
    const SizedBox(height: 16),
    const Text("目录结构", style: TextStyle(fontWeight: FontWeight.bold)),
    Text("游戏文件的组织方式", style: AppText.label.copyWith( color: hintColor(context))),
    const SizedBox(height: 8),
    Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cardBorder(context)),
      ),
      child: ListTile(
        title: const Text("结构"),
        trailing: DropdownButton<String>(
          value: _structure,
          underline: const SizedBox(),
          items: const [
            DropdownMenuItem(value: "company_game", child: Text("会社 / 游戏")),
            DropdownMenuItem(value: "game_only", child: Text("仅游戏")),
            DropdownMenuItem(value: "flat", child: Text("扁平")),
          ],
          onChanged: (v) => setState(() => _structure = v!),
        ),
      ),
    ),
    const SizedBox(height: 12),
    SwitchListTile(
      title: const Text("自动扫描", style: TextStyle(fontSize: 14)),
      subtitle: Text(_autoScan ? "每 $_scanInterval 小时" : "关闭",
          style: AppText.bodySmall.copyWith( color: hintColor(context))),
      value: _autoScan,
      onChanged: (v) => setState(() => _autoScan = v),
      dense: true,
    ),
    if (_autoScan) ...[
      const SizedBox(height: 4),
      TextField(
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: "扫描间隔（小时）",
          isDense: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onChanged: (v) {
          final n = int.tryParse(v);
          if (n != null && n > 0) setState(() => _scanInterval = n);
        },
      ),
    ],
    const SizedBox(height: 16),
    const Text("服务端补丁目录", style: TextStyle(fontWeight: FontWeight.bold)),
    const SizedBox(height: 8),
    TextField(
      controller: _patchDirCtrl,
      decoration: const InputDecoration(labelText: "服务端补丁存放目录", hintText: "/data/steam_patches", prefixIcon: Icon(Icons.dns)),
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _serverSteamDirCtrl,
      decoration: const InputDecoration(
        labelText: "服务端 Steam 库目录（可选）",
        hintText: "/data/Steam/steamapps",
        prefixIcon: Icon(Icons.storage),
      ),
    ),
    const SizedBox(height: 8),
    Text("这里填写的是服务端机器上的路径，不是当前客户端本机路径",
        style: AppText.label.copyWith( color: hintColor(context))),
  ];

  Widget _buildScraperRow(String label, bool enabled, bool needsApi, VoidCallback onToggle, {Widget? apiFields}) {
    return Column(
      children: [
        CheckboxListTile(
          value: enabled,
          onChanged: (_) => onToggle(),
          title: Text(label, style: const TextStyle(fontSize: 14)),
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
        ),
        if (enabled && needsApi && apiFields != null) apiFields,
      ],
    );
  }

  List<Widget> _buildStep4() => [
    Text("选择刮削源，勾选后可用", style: AppText.label.copyWith( color: hintColor(context))),
    const SizedBox(height: 8),
    _buildScraperRow("VNDB Kana v2（免认证）", _useVndbKana, false,
        () => setState(() => _useVndbKana = !_useVndbKana)),
    _buildScraperRow("Bangumi（免认证）", _useBangumi, false,
        () => setState(() => _useBangumi = !_useBangumi)),
    _buildScraperRow("Steam（免认证）", _useSteam, false,
        () => setState(() => _useSteam = !_useSteam)),
    _buildScraperRow("月幕GalGame（免认证）", _useYmgal, false,
        () => setState(() => _useYmgal = !_useYmgal)),
    const SizedBox(height: 16),
    const Text("代理服务器", style: TextStyle(fontWeight: FontWeight.bold)),
    const SizedBox(height: 4),
    Text("刮削源走代理访问，如 http://127.0.0.1:7890", style: AppText.label.copyWith( color: hintColor(context))),
    const SizedBox(height: 8),
    TextField(
      controller: _proxyCtrl,
      decoration: const InputDecoration(labelText: "HTTP 代理", hintText: "http://127.0.0.1:7890", isDense: true),
    ),
    const SizedBox(height: 8),
    Text("可稍后在设置中修改", style: AppText.label.copyWith( color: hintColor(context))),
  ];
}
