/// Multi-step setup wizard for first-time server initialization.

import "package:flutter/material.dart";
import "package:http/http.dart" as http;
import "package:file_picker/file_picker.dart";
import "package:shared_preferences/shared_preferences.dart";
import "dart:convert";

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
  final _localDirCtrl = TextEditingController();

  // Step 3: Steam
  final _patchDirCtrl = TextEditingController(text: "/steam_patch");
  final _steamCommonCtrl = TextEditingController();

  // Step 4: Scrapers
  final _proxyCtrl = TextEditingController();
  bool _useBangumi = true;
  bool _useVndbKana = true;
  bool _useSteam = true;
  bool _useDlsite = true;
  bool _useIGDB = false;
  final _vndbCtrl = TextEditingController();
  final _igdbIdCtrl = TextEditingController();
  final _igdbSecretCtrl = TextEditingController();

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
          "steam_dir": _steamCommonCtrl.text.trim(),
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
      // Persist Steam common dir and local download dir
      final prefs = await SharedPreferences.getInstance();
      if (_steamCommonCtrl.text.trim().isNotEmpty) {
        await prefs.setString("steam_common_dir", _steamCommonCtrl.text.trim());
      }
      if (_localDirCtrl.text.trim().isNotEmpty) {
        await prefs.setString("local_download_dir", _localDirCtrl.text.trim());
      }
      // Trigger scan
      await http.post(Uri.parse("${widget.api.baseUrl}/api/roots/refresh-all"));
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() { _error = "$e"; _loading = false; });
    }
  }

  Future<void> _saveScraperKeys() async {
    final body = <String, String>{};
    if (_vndbCtrl.text.isNotEmpty) body["vndb_token"] = _vndbCtrl.text;
    if (_igdbIdCtrl.text.isNotEmpty) body["igdb_client_id"] = _igdbIdCtrl.text;
    if (_igdbSecretCtrl.text.isNotEmpty) body["igdb_client_secret"] = _igdbSecretCtrl.text;
    if (body.isNotEmpty) {
      await http.put(
        Uri.parse("${widget.api.baseUrl}/api/settings/scraper"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(body),
      );
    }
  }

  static const _titles = ["创建管理员", "添加游戏库", "Steam 补丁", "刮削源"];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("初次设置 (${_step + 1}/4)")),
      body: Center(
        child: SingleChildScrollView(
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
                      children: List.generate(4, (i) => Expanded(child: Container(
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
                    if (_step == 2) ..._buildStep3(),
                    if (_step == 3) ..._buildStep4(),

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
                        if (_step < 3)
                          FilledButton(onPressed: _next, child: const Text("下一步")),
                        if (_step == 3)
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

  Future<void> _pickLocalDir() async {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir != null) _localDirCtrl.text = dir;
  }

  List<Widget> _buildStep2() => [
    const Text("服务端扫描目录", style: TextStyle(fontWeight: FontWeight.bold)),
    Text("每行一个路径，服务端将扫描这些目录下的游戏",
      style: TextStyle(fontSize: 12, color: hintColor(context))),
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
    const Text("本机下载目录", style: TextStyle(fontWeight: FontWeight.bold)),
    Text("客户端下载游戏保存的位置", style: TextStyle(fontSize: 12, color: hintColor(context))),
    const SizedBox(height: 8),
    Row(children: [
      Expanded(child: TextField(controller: _localDirCtrl, decoration: const InputDecoration(hintText: "选择本机目录...", isDense: true))),
      const SizedBox(width: 4),
      IconButton.filled(icon: const Icon(Icons.folder_open, size: 20), onPressed: _pickLocalDir),
    ]),
  ];

  Future<void> _pickSteamDir() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      _steamCommonCtrl.text = result;
    }
  }

  List<Widget> _buildStep3() => [
    TextField(
      controller: _patchDirCtrl,
      decoration: const InputDecoration(labelText: "服务端补丁存放目录", hintText: "/data/steam_patches", prefixIcon: Icon(Icons.dns)),
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _steamCommonCtrl,
      decoration: InputDecoration(
        labelText: "本机 Steam 库目录",
        hintText: "C:/Steam/steamapps",
        prefixIcon: const Icon(Icons.computer),
        suffixIcon: IconButton(
          icon: const Icon(Icons.folder_open),
          onPressed: _pickSteamDir,
          tooltip: "选择文件夹",
        ),
      ),
    ),
    const SizedBox(height: 8),
    Text("PC 端专属，可稍后在设置中配置", style: TextStyle(fontSize: 12, color: hintColor(context))),
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
    Text("选择刮削源，勾选后可用", style: TextStyle(fontSize: 12, color: hintColor(context))),
    const SizedBox(height: 8),
    _buildScraperRow("VNDB Kana v2（免认证）", _useVndbKana, false,
        () => setState(() => _useVndbKana = !_useVndbKana)),
    _buildScraperRow("Bangumi（免认证）", _useBangumi, false,
        () => setState(() => _useBangumi = !_useBangumi)),
    _buildScraperRow("Steam（免认证）", _useSteam, false,
        () => setState(() => _useSteam = !_useSteam)),
    _buildScraperRow("DLsite（免认证）", _useDlsite, false,
        () => setState(() => _useDlsite = !_useDlsite)),
    _buildScraperRow("IGDB（需要 Client ID/Secret）", _useIGDB, true,
        () => setState(() => _useIGDB = !_useIGDB),
        apiFields: Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 8),
          child: Column(children: [
            TextField(controller: _igdbIdCtrl,
              decoration: const InputDecoration(labelText: "Client ID", isDense: true)),
            const SizedBox(height: 8),
            TextField(controller: _igdbSecretCtrl,
              decoration: const InputDecoration(labelText: "Client Secret", isDense: true)),
          ]),
        )),
    const SizedBox(height: 16),
    const Text("代理服务器", style: TextStyle(fontWeight: FontWeight.bold)),
    const SizedBox(height: 4),
    Text("刮削源走代理访问，如 http://127.0.0.1:7890", style: TextStyle(fontSize: 12, color: hintColor(context))),
    const SizedBox(height: 8),
    TextField(
      controller: _proxyCtrl,
      decoration: const InputDecoration(labelText: "HTTP 代理", hintText: "http://127.0.0.1:7890", isDense: true),
    ),
    const SizedBox(height: 8),
    Text("可稍后在设置中修改", style: TextStyle(fontSize: 12, color: hintColor(context))),
  ];
}
