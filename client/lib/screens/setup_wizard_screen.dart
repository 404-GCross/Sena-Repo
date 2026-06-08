/// Multi-step setup wizard for first-time server initialization.

import "package:flutter/material.dart";
import "package:http/http.dart" as http;
import "package:file_picker/file_picker.dart";
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

  // Step 2: Game dirs
  final _dirCtrls = <TextEditingController>[TextEditingController(text: "/games")];

  // Step 3: Steam
  final _patchDirCtrl = TextEditingController(text: "/steam_patch");
  final _steamCommonCtrl = TextEditingController();

  // Step 4: Scrapers
  final _bangumiCtrl = TextEditingController();
  final _vndbCtrl = TextEditingController();
  final _steamGridDBCtrl = TextEditingController();
  final _igdbIdCtrl = TextEditingController();
  final _igdbSecretCtrl = TextEditingController();

  void _next() => setState(() => _step++);
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
      // Trigger scan
      await http.post(Uri.parse("${widget.api.baseUrl}/api/roots/refresh-all"));
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() { _error = "$e"; _loading = false; });
    }
  }

  Future<void> _saveScraperKeys() async {
    final body = <String, String>{};
    if (_bangumiCtrl.text.isNotEmpty) body["bangumi_token"] = _bangumiCtrl.text;
    if (_vndbCtrl.text.isNotEmpty) body["vndb_token"] = _vndbCtrl.text;
    if (_steamGridDBCtrl.text.isNotEmpty) body["steamgriddb_key"] = _steamGridDBCtrl.text;
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
  ];

  List<Widget> _buildStep2() => [
    Text("每行一个路径，服务端将扫描这些目录下的游戏",
      style: TextStyle(fontSize: 12, color: Colors.grey[500])),
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
        labelText: "本机 Steam common 目录",
        hintText: "C:/Steam/steamapps/common",
        prefixIcon: const Icon(Icons.computer),
        suffixIcon: IconButton(
          icon: const Icon(Icons.folder_open),
          onPressed: _pickSteamDir,
          tooltip: "选择文件夹",
        ),
      ),
    ),
    const SizedBox(height: 8),
    Text("PC 端专属，可稍后在设置中配置", style: TextStyle(fontSize: 12, color: Colors.grey[500])),
  ];

  List<Widget> _buildStep4() => [
    Text("选择刮削源并填写 API Key（可选）",
      style: TextStyle(fontSize: 12, color: Colors.grey[500])),
    const SizedBox(height: 12),
    TextField(controller: _bangumiCtrl, decoration: const InputDecoration(labelText: "Bangumi Token", hintText: "https://bgm.tv/dev/app")),
    const SizedBox(height: 8),
    TextField(controller: _vndbCtrl, decoration: const InputDecoration(labelText: "VNDB Token", hintText: "https://vndb.org/u/tokens")),
    const SizedBox(height: 8),
    TextField(controller: _steamGridDBCtrl, decoration: const InputDecoration(labelText: "SteamGridDB Key", hintText: "steamgriddb.com/profile/preferences/api")),
    const SizedBox(height: 8),
    TextField(controller: _igdbIdCtrl, decoration: const InputDecoration(labelText: "IGDB Client ID")),
    const SizedBox(height: 8),
    TextField(controller: _igdbSecretCtrl, decoration: const InputDecoration(labelText: "IGDB Client Secret")),
    const SizedBox(height: 8),
    Text("留空则跳过对应源，可稍后在设置中配置", style: TextStyle(fontSize: 12, color: Colors.grey[500])),
  ];
}
