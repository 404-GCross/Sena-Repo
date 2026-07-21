/// Multi-step setup wizard for first-time server initialization.

import "dart:convert";

import "package:flutter/material.dart";
import "package:http/http.dart" as http;
import "package:shared_preferences/shared_preferences.dart";

import "../services/api_client.dart";
import "../utils/theme_utils.dart";

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

  final _userCtrl = TextEditingController(text: "admin");
  final _passCtrl = TextEditingController();
  final _passConfirmCtrl = TextEditingController();

  final List<Map<String, dynamic>> _gameLibraries = [
    {"source_type": "local", "path": "/games"},
  ];
  final List<Map<String, dynamic>> _patchLibraries = [
    {"source_type": "local", "path": "/steam_patch"},
  ];

  String _structure = "company_game";
  bool _autoScan = false;
  int _scanInterval = 24;

  bool _useBangumi = true;
  bool _useVndbKana = true;
  bool _useSteam = true;
  bool _useYmgal = true;
  final _vndbCtrl = TextEditingController();

  static const _titles = ["创建管理员", "目录与扫描", "刮削源"];

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    _passConfirmCtrl.dispose();
    _vndbCtrl.dispose();
    super.dispose();
  }

  void _next() {
    if (_step == 0 && _passCtrl.text != _passConfirmCtrl.text) {
      setState(() => _error = "两次密码不一致");
      return;
    }
    setState(() {
      _step++;
      _error = null;
    });
  }

  void _prev() => setState(() {
    _step--;
    _error = null;
  });

  Future<void> _addDirectory(
    List<Map<String, dynamic>> target,
    String label,
  ) async {
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _SetupDirectoryDialog(label: label),
    );
    if (payload == null) return;
    setState(() => target.add(payload));
  }

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final resp = await http.post(
        Uri.parse("${widget.api.baseUrl}/api/setup/initialize"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "admin_username": _userCtrl.text.trim(),
          "admin_password": _passCtrl.text,
          "game_libraries": _gameLibraries,
          "steam_patch_libraries": _patchLibraries,
          "auto_scan": _autoScan,
          "scan_interval": _scanInterval,
          "scan_structure": _structure,
        }),
      );
      if (resp.statusCode != 200) {
        final body = jsonDecode(resp.body);
        setState(() {
          _error = body["detail"]?.toString() ?? "初始化失败";
          _loading = false;
        });
        return;
      }

      await _saveScraperPrefs();
      if (mounted) {
        Navigator.pop(context, {
          "username": _userCtrl.text.trim(),
          "password": _passCtrl.text,
        });
      }
    } catch (e) {
      setState(() {
        _error = "$e";
        _loading = false;
      });
    }
  }

  Future<void> _saveScraperPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool("scrape_src_vndb_kana", _useVndbKana);
    await prefs.setBool("scrape_src_bangumi", _useBangumi);
    await prefs.setBool("scrape_src_steam", _useSteam);
    await prefs.setBool("scrape_src_ymgal", _useYmgal);
    await prefs.setString("scan_structure", _structure);
    await prefs.setBool("auto_scan", _autoScan);
    if (_autoScan) await prefs.setInt("scan_interval", _scanInterval);

    if (_vndbCtrl.text.trim().isNotEmpty) {
      await http.put(
        Uri.parse("${widget.api.baseUrl}/api/settings/scraper"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"vndb_token": _vndbCtrl.text.trim()}),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("初始设置 (${_step + 1}/3)")),
      body: Center(
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.all(24),
          child: SizedBox(
            width: 520,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: List.generate(
                        3,
                        (i) => Expanded(
                          child: Container(
                            height: 4,
                            margin: const EdgeInsets.symmetric(horizontal: 2),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(2),
                              color: i <= _step
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.grey[700],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _titles[_step],
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (_step == 0) ..._buildAdminStep(),
                    if (_step == 1) ..._buildDirectoryStep(),
                    if (_step == 2) ..._buildScraperStep(),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        if (_step > 0)
                          OutlinedButton(
                            onPressed: _prev,
                            child: const Text("上一步"),
                          ),
                        const Spacer(),
                        if (_step < 2)
                          FilledButton(
                            onPressed: _next,
                            child: const Text("下一步"),
                          ),
                        if (_step == 2)
                          FilledButton(
                            onPressed: _loading ? null : _submit,
                            child: _loading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text("完成"),
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

  List<Widget> _buildAdminStep() => [
    TextField(
      controller: _userCtrl,
      decoration: const InputDecoration(
        labelText: "用户名",
        prefixIcon: Icon(Icons.person),
      ),
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _passCtrl,
      decoration: const InputDecoration(
        labelText: "密码",
        prefixIcon: Icon(Icons.lock),
      ),
      obscureText: true,
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _passConfirmCtrl,
      decoration: const InputDecoration(
        labelText: "确认密码",
        prefixIcon: Icon(Icons.lock),
      ),
      obscureText: true,
    ),
  ];

  List<Widget> _buildDirectoryStep() => [
    _librarySection(
      "游戏库",
      _gameLibraries,
      () => _addDirectory(_gameLibraries, "游戏库"),
    ),
    const SizedBox(height: 16),
    _librarySection(
      "Steam 补丁库",
      _patchLibraries,
      () => _addDirectory(_patchLibraries, "Steam 补丁库"),
    ),
    const SizedBox(height: 16),
    const Text("扫描选项", style: TextStyle(fontWeight: FontWeight.bold)),
    const SizedBox(height: 8),
    DropdownButtonFormField<String>(
      value: _structure,
      decoration: const InputDecoration(labelText: "目录结构"),
      items: const [
        DropdownMenuItem(value: "company_game", child: Text("会社 / 游戏")),
        DropdownMenuItem(value: "game_only", child: Text("仅游戏")),
        DropdownMenuItem(value: "flat", child: Text("扁平")),
      ],
      onChanged: (v) => setState(() => _structure = v ?? "company_game"),
    ),
    SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text("自动扫描"),
      subtitle: Text(_autoScan ? "每 $_scanInterval 小时" : "关闭"),
      value: _autoScan,
      onChanged: (v) => setState(() => _autoScan = v),
    ),
    if (_autoScan)
      TextField(
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(labelText: "扫描间隔（小时）"),
        onChanged: (v) {
          final n = int.tryParse(v);
          if (n != null && n > 0) setState(() => _scanInterval = n);
        },
      ),
  ];

  Widget _librarySection(
    String title,
    List<Map<String, dynamic>> items,
    VoidCallback onAdd,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            TextButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text("添加目录"),
            ),
          ],
        ),
        if (items.isEmpty)
          Text(
            "暂无目录",
            style: AppText.label.copyWith(color: hintColor(context)),
          )
        else
          ...items.asMap().entries.map(
            (entry) => ListTile(
              dense: true,
              leading: Icon(
                entry.value["source_type"] == "openlist"
                    ? Icons.cloud_outlined
                    : Icons.folder_outlined,
              ),
              title: Text(
                entry.value["source_type"] == "openlist" ? "OpenList 源" : "本地文件源",
              ),
              subtitle: Text(
                entry.value["path"]?.toString() ?? "",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => setState(() => items.removeAt(entry.key)),
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _buildScraperStep() => [
    _scraperSwitch(
      "VNDB Kana v2",
      _useVndbKana,
      (v) => setState(() => _useVndbKana = v),
    ),
    _scraperSwitch(
      "Bangumi",
      _useBangumi,
      (v) => setState(() => _useBangumi = v),
    ),
    _scraperSwitch("Steam", _useSteam, (v) => setState(() => _useSteam = v)),
    _scraperSwitch("YMGal", _useYmgal, (v) => setState(() => _useYmgal = v)),
    const SizedBox(height: 12),
    TextField(
      controller: _vndbCtrl,
      decoration: const InputDecoration(labelText: "VNDB Token（可选）"),
    ),
  ];

  Widget _scraperSwitch(
    String title,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      value: value,
      onChanged: onChanged,
    );
  }
}

class _SetupDirectoryDialog extends StatefulWidget {
  final String label;
  const _SetupDirectoryDialog({required this.label});

  @override
  State<_SetupDirectoryDialog> createState() => _SetupDirectoryDialogState();
}

class _SetupDirectoryDialogState extends State<_SetupDirectoryDialog> {
  String _sourceType = "local";
  final _pathCtrl = TextEditingController();
  final _nameCtrl = TextEditingController(text: "OpenList");
  final _baseUrlCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  @override
  void dispose() {
    _pathCtrl.dispose();
    _nameCtrl.dispose();
    _baseUrlCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text("添加${widget.label}目录"),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: "local",
                  icon: Icon(Icons.folder_outlined),
                  label: Text("本地文件源"),
                ),
                ButtonSegment(
                  value: "openlist",
                  icon: Icon(Icons.cloud_outlined),
                  label: Text("OpenList"),
                ),
              ],
              selected: {_sourceType},
              onSelectionChanged: (v) => setState(() => _sourceType = v.first),
            ),
            const SizedBox(height: 16),
            if (_sourceType == "openlist") ...[
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(labelText: "名称"),
              ),
              TextField(
                controller: _baseUrlCtrl,
                decoration: const InputDecoration(labelText: "OpenList 地址"),
              ),
              TextField(
                controller: _usernameCtrl,
                decoration: const InputDecoration(labelText: "用户名"),
              ),
              TextField(
                controller: _passwordCtrl,
                decoration: const InputDecoration(labelText: "密码"),
                obscureText: true,
              ),
            ],
            TextField(
              controller: _pathCtrl,
              decoration: InputDecoration(
                labelText: _sourceType == "openlist"
                    ? "远程目录"
                    : "服务端本地目录",
                hintText: _sourceType == "openlist" ? "/Games" : "/data/games",
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("取消"),
        ),
        FilledButton(
          onPressed: () {
            final path = _pathCtrl.text.trim();
            if (path.isEmpty) return;
            final payload = <String, dynamic>{
              "source_type": _sourceType,
              "path": path,
            };
            if (_sourceType == "openlist") {
              payload["source_name"] = _nameCtrl.text.trim();
              payload["base_url"] = _baseUrlCtrl.text.trim();
              payload["username"] = _usernameCtrl.text.trim();
              payload["password"] = _passwordCtrl.text;
            }
            Navigator.pop(context, payload);
          },
          child: const Text("保存"),
        ),
      ],
    );
  }
}
