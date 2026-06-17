/// Multi-step setup wizard for first-time server initialization.

import "package:flutter/material.dart";
import "package:http/http.dart" as http;
import "package:file_picker/file_picker.dart";
import "package:shared_preferences/shared_preferences.dart";
import "dart:convert";

import "../utils/theme_utils.dart";
import "../services/api_client.dart";
import "../services/notification_service.dart";

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
  String _structure = "company_game";
  bool _autoScan = false;
  int _scanInterval = 24;
  bool _notifGranted = false;
  bool _notifAsked = false;
  bool _downloadExtract = true; // true=extract, false=download only

  // Step 3: Steam
  final _patchDirCtrl = TextEditingController(text: "/steam_patch");
  final _steamCommonCtrl = TextEditingController();
  final _steamIdCtrl = TextEditingController();

  // Step 4: Scrapers
  final _proxyCtrl = TextEditingController();
  bool _useBangumi = true;
  bool _useVndbKana = true;
  bool _useSteam = true;
  bool _useDlsite = true;
  bool _useYmgal = true;
  bool _useIGDB = false;
  final _vndbCtrl = TextEditingController();
  final _igdbIdCtrl = TextEditingController();
  final _igdbSecretCtrl = TextEditingController();

  Future<void> _requestNotification() async {
    final granted = await NotificationService().requestPermission();
    if (!mounted) return;
    setState(() {
      _notifAsked = true;
      _notifGranted = granted;
    });
  }

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
      // Persist scraper source toggles
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool("scrape_src_vndb_kana", _useVndbKana);
      await prefs.setBool("scrape_src_bangumi", _useBangumi);
      await prefs.setBool("scrape_src_steam", _useSteam);
      await prefs.setBool("scrape_src_dlsite", _useDlsite);
      await prefs.setBool("scrape_src_ymgal", _useYmgal);
      await prefs.setBool("scrape_src_igdb", _useIGDB);
      await prefs.setString("scan_structure", _structure);
      await prefs.setBool("auto_scan", _autoScan);
      if (_autoScan) await prefs.setInt("scan_interval", _scanInterval);
      // Persist Steam common dir and local download dir
      if (_steamCommonCtrl.text.trim().isNotEmpty) {
        await prefs.setString("steamapps_dir", _steamCommonCtrl.text.trim());
      }
      if (_steamIdCtrl.text.trim().isNotEmpty) {
        await prefs.setString("steam_user_id", _steamIdCtrl.text.trim());
      }
      if (_localDirCtrl.text.trim().isNotEmpty) {
        await prefs.setString("local_download_dir", _localDirCtrl.text.trim());
      }
      await prefs.setString("download_mode", _downloadExtract ? "extract" : "download_only");
      // Trigger scan
      await http.post(Uri.parse("${widget.api.baseUrl}/api/roots/refresh-all"));
      // Request Android notification permission
      await NotificationService().init();
      await NotificationService().requestPermission();
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
    const Text("本机下载目录", style: TextStyle(fontWeight: FontWeight.bold)),
    Text("客户端下载游戏保存的位置", style: AppText.label.copyWith( color: hintColor(context))),
    const SizedBox(height: 8),
    Row(children: [
      Expanded(child: TextField(controller: _localDirCtrl, decoration: const InputDecoration(hintText: "选择本机目录...", isDense: true))),
      const SizedBox(width: 4),
      IconButton.filled(icon: const Icon(Icons.folder_open, size: 20), onPressed: _pickLocalDir),
    ]),
    const SizedBox(height: 12),
    // ── Download mode ──
    Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cardBg(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cardBorder(context)),
      ),
      child: Row(children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: _downloadExtract ? Colors.blue.withValues(alpha: 0.12) : Colors.orange.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            _downloadExtract ? Icons.unarchive : Icons.download,
            size: 20,
            color: _downloadExtract ? Colors.blue[300] : Colors.orange[300],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text("下载模式", style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(
              _downloadExtract ? "下载并自动解压" : "仅下载（不解压）",
              style: AppText.bodySmall.copyWith(color: hintColor(context)),
            ),
          ]),
        ),
        const SizedBox(width: 8),
        Switch(
          value: _downloadExtract,
          onChanged: (v) => setState(() => _downloadExtract = v),
        ),
      ]),
    ),
    const SizedBox(height: 20),
    // ── Notification permission ──
    Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardBg(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cardBorder(context)),
      ),
      child: Row(children: [
        Container(
          width: 40, height: 40,
          decoration: BoxDecoration(
            color: _notifGranted
                ? Colors.green.withValues(alpha: 0.12)
                : Colors.orange.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            _notifGranted ? Icons.notifications_active : Icons.notifications_off,
            size: 20,
            color: _notifGranted ? Colors.green[300] : Colors.orange[300],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text("通知权限", style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(
              _notifGranted
                  ? "已授权 — 后台下载通知正常"
                  : "用于显示下载进度和完成提醒",
              style: AppText.bodySmall.copyWith(color: hintColor(context)),
            ),
          ]),
        ),
        const SizedBox(width: 8),
        _notifGranted
            ? Icon(Icons.check_circle, size: 20, color: Colors.green[300])
            : Material(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: _notifAsked ? null : _requestNotification,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    child: Text(
                      _notifAsked ? "已拒绝" : "开启",
                      style: AppText.bodySmall.copyWith(
                        color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
      ]),
    ),
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
    Text("PC 端专属，可稍后在设置中配置", style: AppText.label.copyWith( color: hintColor(context))),
    const SizedBox(height: 12),
    TextField(
      controller: _steamIdCtrl,
      decoration: const InputDecoration(
        labelText: "Steam 用户 ID（可选）",
        hintText: "Steam好友代码，一串纯数字",
        prefixIcon: Icon(Icons.person),
      ),
      keyboardType: TextInputType.number,
    ),
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
    _buildScraperRow("DLsite（免认证）", _useDlsite, false,
        () => setState(() => _useDlsite = !_useDlsite)),
    _buildScraperRow("月幕GalGame（免认证）", _useYmgal, false,
        () => setState(() => _useYmgal = !_useYmgal)),
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
