/// Full-screen flow for adding a new server and logging in.

import "dart:convert";
import "dart:io" show Platform;

import "package:flutter/material.dart";
import "package:provider/provider.dart";
import "package:http/http.dart" as http;
import "package:shared_preferences/shared_preferences.dart";
import "package:file_picker/file_picker.dart";

import "../providers/settings_provider.dart";
import "../providers/game_provider.dart";
import "../utils/theme_utils.dart";
import "../services/api_client.dart";
import "../services/profile_service.dart";
import "home_screen.dart";
import "setup_wizard_screen.dart";

class AddServerScreen extends StatefulWidget {
  const AddServerScreen({super.key});

  @override
  State<AddServerScreen> createState() => _AddServerScreenState();
}

class _AddServerScreenState extends State<AddServerScreen> {
  final _hostCtrl = TextEditingController(text: "192.168.1.100");
  final _portCtrl = TextEditingController(text: "11451");
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _passConfirmCtrl = TextEditingController();

  bool _useHttps = false;
  bool _showRegister = false;
  bool _connecting = false;
  bool _isLoggingIn = false;
  String? _error;
  String? _loginError;
  int _step = 0;  // 0 = connect, 1 = login
  ApiClient? _api;

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _passConfirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final host = _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim()) ?? 11451;
    if (host.isEmpty) { setState(() => _error = "请输入服务器地址"); return; }
    setState(() { _connecting = true; _error = null; });

    final settings = context.read<SettingsProvider>();
    final ok = await settings.connect(host, port, useHttps: _useHttps);
    if (!ok) {
      if (mounted) setState(() { _connecting = false; _error = settings.errorMessage ?? "连接失败"; });
      return;
    }

    final api = ApiClient();
    api.connect(host, port: port, useHttps: _useHttps);
    _api = api;

    final needsSetup = await api.checkSetupNeeded();
    if (needsSetup && mounted) {
      // Server needs initialization — redirect to setup wizard
      final setupResult = await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => SetupWizardScreen(api: api)),
      );
      if (setupResult != null && mounted) {
        final creds = setupResult as Map;
        final loginResult = await api.login(
          creds["username"]?.toString() ?? "",
          creds["password"]?.toString() ?? "",
        );
        if (loginResult != null) {
          final uname = loginResult["username"]?.toString() ?? "";
          await ProfileService().saveCurrentAsProfile(uname);
          await _goHome();
          return;
        }
      }
      if (!mounted) return;
    }

    // First-run client setup dialog
    final prefs = await SharedPreferences.getInstance();
    final clientSetupDone = prefs.getBool("client_setup_done") ?? false;
    if (!clientSetupDone && mounted) {
      await showDialog(
        context: context, barrierDismissible: false,
        builder: (ctx) => _ClientSetupDialog(onDone: () => Navigator.pop(ctx)),
      );
      await prefs.setBool("client_setup_done", true);
    }

    if (mounted) setState(() { _connecting = false; _step = 1; });
  }

  Future<void> _login() async {
    if (_userCtrl.text.trim().isEmpty || _passCtrl.text.isEmpty) {
      setState(() => _loginError = "请输入用户名和密码"); return;
    }
    setState(() { _isLoggingIn = true; _loginError = null; });

    try {
      final data = await _api!.login(_userCtrl.text.trim(), _passCtrl.text);
      if (data != null) {
        final uname = data["username"]?.toString() ?? _userCtrl.text.trim();
        await ProfileService().saveCurrentAsProfile(uname);
        if (mounted) await _goHome();
      } else {
        setState(() => _loginError = "登录失败，请检查用户名和密码");
      }
    } catch (e) {
      setState(() => _loginError = "登录失败: $e");
    }
    if (mounted) setState(() => _isLoggingIn = false);
  }

  Future<void> _register() async {
    if (_userCtrl.text.trim().isEmpty) { setState(() => _loginError = "请输入用户名"); return; }
    if (_passCtrl.text.length < 4) { setState(() => _loginError = "密码至少4位"); return; }
    if (_passCtrl.text != _passConfirmCtrl.text) { setState(() => _loginError = "两次密码不一致"); return; }
    setState(() { _isLoggingIn = true; _loginError = null; });

    try {
      final resp = await http.post(
        Uri.parse("${_api!.baseUrl}/api/auth/register"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"username": _userCtrl.text.trim(), "password": _passCtrl.text, "is_admin": false}),
      );
      final body = jsonDecode(resp.body);
      if (resp.statusCode == 200) {
        if (body["auto_approved"] == true) {
          final data = await _api!.login(_userCtrl.text.trim(), _passCtrl.text);
          if (data != null) {
            await ProfileService().saveCurrentAsProfile(_userCtrl.text.trim());
            if (mounted) await _goHome();
            return;
          }
        }
        setState(() {
          _showRegister = false;
          _loginError = "注册成功！${body["auto_approved"] == true ? "已自动激活，请登录" : "请等待管理员审批后登录"}";
        });
      } else {
        setState(() => _loginError = body["detail"] ?? "注册失败");
      }
    } catch (e) {
      setState(() => _loginError = "连接失败: $e");
    }
    setState(() => _isLoggingIn = false);
  }

  Future<void> _goHome() async {
    if (!mounted) return;
    final games = context.read<GameProvider>();
    final settings = context.read<SettingsProvider>();
    games.connect(settings.serverHost, settings.serverPort, useHttps: settings.useHttps);
    try {
      await games.loadGames();
    } catch (e) {
      if (mounted) {
        setState(() => _loginError = "加载游戏库失败: $e");
      }
      return;
    }
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
        (_) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_step == 0 ? "添加服务器" : (_showRegister ? "注册账户" : "登录")),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // App icon
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.asset("assets/icon.png", width: 64, height: 64, fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Icon(Icons.dns, size: 56,
                      color: Theme.of(context).colorScheme.primary)),
              ),
              const SizedBox(height: 24),

              // Step 0: Connection form
              if (_step == 0) ...[
                TextField(controller: _hostCtrl, autofocus: true,
                    decoration: const InputDecoration(labelText: "服务器地址", prefixIcon: Icon(Icons.computer))),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: TextField(controller: _portCtrl,
                        decoration: const InputDecoration(labelText: "端口", prefixIcon: Icon(Icons.settings_ethernet)),
                        keyboardType: TextInputType.number),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    height: 56,
                    child: FilledButton.tonal(
                      onPressed: _connecting ? null : _connect,
                      style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 24)),
                      child: _connecting
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text("连接"),
                    ),
                  ),
                ]),
                const SizedBox(height: 4),
                Row(children: [
                  SizedBox(height: 32, child: Switch(value: _useHttps, onChanged: (v) => setState(() => _useHttps = v))),
                  Text("HTTPS", style: TextStyle(fontSize: 13, color: Colors.grey[600])),
                ]),
                if (_error != null)
                  Padding(padding: const EdgeInsets.only(top: 8),
                      child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13))),
              ],

              // Step 1: Login/Register form
              if (_step == 1) ...[
                TextField(controller: _userCtrl, autofocus: true,
                    decoration: const InputDecoration(labelText: "用户名", prefixIcon: Icon(Icons.person))),
                const SizedBox(height: 12),
                TextField(controller: _passCtrl,
                    decoration: const InputDecoration(labelText: "密码", prefixIcon: Icon(Icons.lock)),
                    obscureText: true),
                if (_showRegister) ...[
                  const SizedBox(height: 12),
                  TextField(controller: _passConfirmCtrl,
                      decoration: const InputDecoration(labelText: "确认密码", prefixIcon: Icon(Icons.lock)),
                      obscureText: true),
                ],

                if (_loginError != null)
                  Padding(padding: const EdgeInsets.only(top: 8),
                      child: Text(_loginError!,
                          style: TextStyle(
                            color: _loginError!.contains("成功") ? Colors.green : Colors.red,
                            fontSize: 13,
                          ))),

                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _isLoggingIn ? null : (_showRegister ? _register : _login),
                    child: _isLoggingIn
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(_showRegister ? "注册" : "登录"),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => setState(() { _showRegister = !_showRegister; _loginError = null; }),
                  child: Text(_showRegister ? "已有账户？登录" : "没有账户？注册"),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

// First-run client setup dialog

class _ClientSetupDialog extends StatefulWidget {
  final VoidCallback onDone;
  const _ClientSetupDialog({required this.onDone});

  @override
  State<_ClientSetupDialog> createState() => _ClientSetupDialogState();
}

class _ClientSetupDialogState extends State<_ClientSetupDialog> {
  String _downloadDir = "";
  String _steamDir = "";
  String _steamUserId = "";
  final _steamIdCtrl = TextEditingController();

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final dd = prefs.getString("local_download_dir") ?? "";
    final sd = prefs.getString("steamapps_dir") ?? prefs.getString("steam_common_dir") ?? "";
    final uid = prefs.getString("steam_user_id") ?? "";
    _steamIdCtrl.text = uid;
    setState(() { _downloadDir = dd; _steamDir = sd; _steamUserId = uid; });
  }

  Future<void> _pickDownloadDir() async {
    final result = await FilePicker.platform.getDirectoryPath(dialogTitle: "选择游戏下载目录");
    if (result != null) {
      setState(() => _downloadDir = result);
      (await SharedPreferences.getInstance()).setString("local_download_dir", result);
    }
  }

  Future<void> _pickSteamDir() async {
    final result = await FilePicker.platform.getDirectoryPath(dialogTitle: "选择 Steam steamapps 目录");
    if (result != null) {
      setState(() => _steamDir = result);
      (await SharedPreferences.getInstance()).setString("steamapps_dir", result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text("初始设置", textAlign: TextAlign.center),
      content: SizedBox(width: 400, child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text("首次使用需要设置以下目录，稍后可在设置中修改",
            style: AppText.bodySmall.copyWith(color: Colors.grey)),
        const SizedBox(height: 20),
        _dirCard(Icons.download, "游戏下载目录", _downloadDir, _pickDownloadDir),
        if (!Platform.isAndroid) ...[
          const SizedBox(height: 12),
          _dirCard(Icons.gamepad, "Steam 库目录 (steamapps)", _steamDir, _pickSteamDir),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: cardBg(context), borderRadius: BorderRadius.circular(12),
              border: Border.all(color: cardBorder(context)),
            ),
            child: Row(children: [
              Icon(Icons.person, size: 20, color: sectionIconColor(context)),
              const SizedBox(width: 8),
              Expanded(child: TextField(
                controller: _steamIdCtrl,
                decoration: const InputDecoration(
                  hintText: "Steam 用户 ID — 就是Steam好友代码，一串纯数字",
                  isDense: true, border: InputBorder.none,
                ),
                keyboardType: TextInputType.number,
                onChanged: (v) async {
                  _steamUserId = v.trim();
                  final prefs = await SharedPreferences.getInstance();
                  if (v.trim().isNotEmpty) await prefs.setString("steam_user_id", v.trim());
                  else await prefs.remove("steam_user_id");
                },
                style: const TextStyle(fontSize: 13),
              )),
            ]),
          ),
        ],
      ])),
      actions: [FilledButton(onPressed: widget.onDone, child: const Text("完成"))],
    );
  }

  Widget _dirCard(IconData icon, String label, String path, VoidCallback onPick) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3)),
      ),
      child: Row(children: [
        Icon(icon, size: 22, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: AppText.bodySmall.copyWith(fontWeight: FontWeight.w500)),
          const SizedBox(height: 2),
          Text(path.isEmpty ? "未设置" : path,
              style: AppText.label.copyWith(color: path.isEmpty ? Colors.red[300] : Colors.grey[600])),
        ])),
        TextButton(onPressed: onPick, child: Text(path.isEmpty ? "选择" : "更换", style: const TextStyle(fontSize: 12))),
      ]),
    );
  }
}
