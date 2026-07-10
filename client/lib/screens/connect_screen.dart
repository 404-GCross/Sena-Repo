/// Combined connection / login / profile switch screen.

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
import "../services/notification_service.dart";
import "home_screen.dart";
import "setup_wizard_screen.dart";
import "add_server_screen.dart";
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  List<UserProfile> _profiles = [];
  int _activeIndex = 0;
  bool _loading = true;

  final _hostCtrl = TextEditingController(text: "192.168.1.100");
  final _portCtrl = TextEditingController(text: "11451");
  bool _useHttps = false;

  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _passConfirmCtrl = TextEditingController();

  bool _showAddServer = false;  // user tapped "add server" button
  bool _connecting = false;
  bool _isLoggingIn = false;
  bool _showRegister = false;
  String? _error;
  String? _loginError;

  ApiClient? _newApi;

  @override
  void initState() { super.initState(); _loadAndAutoConnect(); }

  @override
  void dispose() {
    _hostCtrl.dispose(); _portCtrl.dispose();
    _userCtrl.dispose(); _passCtrl.dispose(); _passConfirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAndAutoConnect() async {
    final ps = ProfileService();
    final profiles = await ps.loadProfiles();
    final idx = await ps.getActiveIndex();
    if (!mounted) return;

    if (profiles.isNotEmpty && idx < profiles.length) {
      final profile = profiles[idx];
      if (profile.authToken.isNotEmpty) {
        await ps.applyProfile(profile);
        await ApiClient.restoreToken();

        // Proactively refresh token before verifying
        final checkApi = ApiClient();
        checkApi.connect(profile.host, port: profile.port, useHttps: profile.useHttps);
      // await checkApi.tryRefresh(); — removed

        try {
          final effectiveToken = checkApi.accessToken ?? profile.authToken;
          final resp = await http.get(
            Uri.parse("${profile.scheme}://${profile.host}:${profile.port}/api/auth/profile/me"),
            headers: {"Authorization": "Bearer $effectiveToken"},
          ).timeout(const Duration(seconds: 5));
          if (resp.statusCode == 200) {
            final settings = context.read<SettingsProvider>();
            final games = context.read<GameProvider>();
            await settings.connect(profile.host, profile.port, useHttps: profile.useHttps);
            games.connect(profile.host, profile.port, useHttps: profile.useHttps);
            await games.loadGames();
            if (mounted) {
              Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const HomeScreen()));
            }
            return;
          }
        } catch (_) {}
      }
    }

    if (mounted) setState(() {
      _profiles = profiles; _activeIndex = idx; _loading = false;
    });
    if (profiles.isEmpty && mounted) {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => const AddServerScreen()));
      if (mounted) setState(() { _profiles = profiles; _loading = false; });
    }
  }

  Future<void> _connectToProfile(UserProfile profile, int index) async {
    setState(() => _error = null);
    await ProfileService().applyProfile(profile);
    await ApiClient.clearTokens();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("auth_token", profile.authToken);
    // final rt = profile.refreshToken; — removed
      // await prefs.setString("refresh_token", result["refresh_token"]?.toString() ?? "");
    await prefs.setString("username", profile.username);
    await prefs.setBool("is_admin", profile.isAdmin);
    await ApiClient.restoreToken();

    final settings = context.read<SettingsProvider>();
    final games = context.read<GameProvider>();
    final success = await settings.connect(profile.host, profile.port, useHttps: profile.useHttps);

    if (success && mounted) {
      games.connect(profile.host, profile.port, useHttps: profile.useHttps);
      await ProfileService().setActiveIndex(index);

      // Proactively refresh token now so the user doesn't hit a stale 401
      // while editing metadata 15+ minutes later.
      // await games.api.tryRefresh(); — removed

      try {
        await games.loadGames();
        if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const HomeScreen()));
      } catch (e) {
        if (mounted) {
          setState(() => _error = "连接失败: ${e.toString().substring(0, e.toString().length.clamp(0, 80))}");
        }
      }
    } else if (mounted) {
      if (mounted) {
        _showToast(settings.errorMessage ?? "连接服务器失败");
        setState(() => _error = settings.errorMessage ?? "连接服务器失败");
      }
  void _showToast(String msg) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(msg, maxLines: 3, overflow: TextOverflow.ellipsis),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("确定"))],
      ),
    );
  }

  Future<void> _showReAuthDialog(UserProfile profile, int index, GameProvider games) async {
    final passCtrl = TextEditingController();
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text("重新登录"),
        content: SizedBox(width: 280, child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text("服务器 ${profile.host}:${profile.port} 已重建或会话已过期", style: TextStyle(fontSize: 13, color: Colors.grey[600])),
          const SizedBox(height: 8),
          Text("用户: ${profile.username}", style: const TextStyle(fontWeight: FontWeight.w500)),
          const SizedBox(height: 12),
          TextField(controller: passCtrl, decoration: const InputDecoration(labelText: "密码"), obscureText: true, autofocus: true),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
          FilledButton(onPressed: () async {
            final scheme = profile.useHttps ? "https" : "http";
            try {
              final resp = await http.post(
                Uri.parse("$scheme://${profile.host}:${profile.port}/api/auth/login"),
                headers: {"Content-Type": "application/json"},
                body: jsonEncode({"username": profile.username, "password": passCtrl.text}),
              );
              if (resp.statusCode == 200) {
                final data = jsonDecode(resp.body) as Map<String, dynamic>;
                Navigator.pop(ctx, data);
              } else {
                final body = jsonDecode(resp.body);
                _toast("登录失败: ${body["detail"]}");
              }
            } catch (e) {
              _toast("连接失败: $e");
              Navigator.pop(ctx);
            }
          }, child: const Text("登录")),
        ],
      ),
    );

    if (result != null && mounted) {
      profile.authToken = result["token"]?.toString() ?? "";
      profile.username = result["username"]?.toString() ?? profile.username;
      profile.isAdmin = result["is_admin"] == true;
      // profile.refreshToken = result["refresh_token"]?.toString() ?? "";

      final ps = ProfileService();
      final profiles = await ps.loadProfiles();
      if (index < profiles.length) {
        profiles[index] = profile;
        await ps.saveProfiles(profiles);
        await ps.applyProfile(profile);
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("auth_token", profile.authToken);
      await ApiClient.restoreToken();

      try {
        await games.loadGames();
        if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const HomeScreen()));
      } catch (e) {
        if (mounted) setState(() => _error = "连接失败: $e");
      }
    }
  }

  Future<void> _connectNewServer() async {
    final host = _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim()) ?? 11451;
    if (host.isEmpty) { setState(() => _error = "请输入服务器地址"); return; }
    setState(() { _connecting = true; _error = null; _loginError = null; });

    final settings = context.read<SettingsProvider>();
    final success = await settings.connect(host, port, useHttps: _useHttps);

    if (success && mounted) {
      final api = ApiClient();
      api.connect(host, port: port, useHttps: _useHttps);

      final needsSetup = await api.checkSetupNeeded();
      if (needsSetup && mounted) {
        final setupResult = await Navigator.push(
          context, MaterialPageRoute(builder: (_) => SetupWizardScreen(api: api)),
        );
        if (setupResult != null && mounted) {
          final creds = setupResult as Map;
          final loginResult = await api.login(creds["username"]?.toString() ?? "", creds["password"]?.toString() ?? "");
          if (loginResult != null && mounted) {
            await ProfileService().saveCurrentAsProfile(loginResult["username"]?.toString() ?? "");
            await _goHome(games: context.read<GameProvider>());
            return;
          }
        }
        if (!mounted) return;
      }

      _newApi = api;

      final prefs = await SharedPreferences.getInstance();
      final clientSetupDone = prefs.getBool("client_setup_done") ?? false;
      if (!clientSetupDone && mounted) {
        await showDialog(context: context, barrierDismissible: false,
          builder: (ctx) => _ClientSetupDialog(onDone: () => Navigator.pop(ctx)));
        await prefs.setBool("client_setup_done", true);
      }

      if (mounted) setState(() { _connecting = false; _showAddServer = true; });
    } else {
      if (mounted) setState(() { _connecting = false; if (settings.errorMessage != null) _error = settings.errorMessage; });
    }
  }

  Future<void> _login() async {
    if (_newApi == null) return;
    if (_userCtrl.text.trim().isEmpty || _passCtrl.text.isEmpty) { setState(() => _loginError = "请输入用户名和密码"); return; }
    setState(() { _isLoggingIn = true; _loginError = null; });
    try {
      final data = await _newApi!.login(_userCtrl.text.trim(), _passCtrl.text);
      if (data != null) {
        final username = data["username"]?.toString() ?? _userCtrl.text.trim();
        final profileName = await _promptProfileName(username);
        if (profileName == null) { setState(() => _isLoggingIn = false); return; }
        await ProfileService().saveCurrentAsProfile(profileName);
        if (mounted) await _goHome(games: context.read<GameProvider>());
      } else { setState(() => _loginError = "登录失败"); }
    } catch (e) { setState(() => _loginError = "登录失败: $e"); }
    setState(() => _isLoggingIn = false);
  }

  Future<void> _register() async {
    if (_newApi == null) return;
    if (_userCtrl.text.trim().isEmpty) { setState(() => _loginError = "请输入用户名"); return; }
    if (_passCtrl.text.length < 4) { setState(() => _loginError = "密码至少4位"); return; }
    if (_passCtrl.text != _passConfirmCtrl.text) { setState(() => _loginError = "两次密码不一致"); return; }
    setState(() { _isLoggingIn = true; _loginError = null; });
    try {
      final resp = await http.post(
        Uri.parse("${_newApi!.baseUrl}/api/auth/register"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"username": _userCtrl.text.trim(), "password": _passCtrl.text, "is_admin": false}),
      );
      final body = jsonDecode(resp.body);
      if (resp.statusCode == 200) {
        if (body["auto_approved"] == true) {
          final data = await _newApi!.login(_userCtrl.text.trim(), _passCtrl.text);
          if (data != null) {
            await ProfileService().saveCurrentAsProfile(_userCtrl.text.trim());
            if (mounted) await _goHome(games: context.read<GameProvider>()); return;
          }
        }
        setState(() { _showRegister = false; _loginError = "注册成功！" + (body["auto_approved"] == true ? "已自动激活，请登录" : "请等待管理员审批后登录"); });
      } else { setState(() => _loginError = body["detail"] ?? "注册失败"); }
    } catch (e) { setState(() => _loginError = "连接失败: $e"); }
    setState(() => _isLoggingIn = false);
  }

  void _toast(String msg) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(msg),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("确定"))],
      ),
    );
  }
  // Helpers

  Future<String?> _promptProfileName(String defaultName) async {
    final ctrl = TextEditingController(text: defaultName);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text("保存配置"),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: "配置名称", hintText: "如 家里NAS"),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text("保存")),
        ],
      ),
    );
  }

  Future<void> _goHome({required GameProvider games}) async {
    if (!mounted) return;
    try { await games.loadGames(); } catch (_) {}
    if (mounted) {
      // ignore: use_build_context_synchronously
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const HomeScreen()));
    }
  }

  Future<void> _editProfile(UserProfile profile) async {
    final nameCtrl = TextEditingController(text: profile.name);
    final hostCtrl = TextEditingController(text: profile.host);
    final portCtrl = TextEditingController(text: profile.port.toString());
    final userCtrl = TextEditingController(text: profile.username);
    final passCtrl = TextEditingController();
    var useHttps = profile.useHttps;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text("编辑配置"),
        content: SizedBox(width: 300, child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: "配置名称")),
          const SizedBox(height: 8),
          TextField(controller: hostCtrl, decoration: const InputDecoration(labelText: "服务器IP")),
          const SizedBox(height: 8),
          TextField(controller: portCtrl, decoration: const InputDecoration(labelText: "端口"), keyboardType: TextInputType.number),
          const SizedBox(height: 4),
          SwitchListTile(title: const Text("HTTPS", style: TextStyle(fontSize: 14)), value: useHttps,
            onChanged: (v) => setD(() => useHttps = v), dense: true, contentPadding: EdgeInsets.zero),
          TextField(controller: userCtrl, decoration: const InputDecoration(labelText: "用户名（留空不修改）")),
          const SizedBox(height: 8),
          TextField(controller: passCtrl, decoration: const InputDecoration(labelText: "密码（留空不修改）"), obscureText: true),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
          FilledButton(onPressed: () async {
            if (nameCtrl.text.trim().isEmpty || hostCtrl.text.trim().isEmpty) return;
            final port = int.tryParse(portCtrl.text.trim()) ?? 11451;
            final newProfile = UserProfile(
              name: nameCtrl.text.trim(),
              host: hostCtrl.text.trim(), port: port,
              authToken: passCtrl.text.isNotEmpty ? "" : profile.authToken,
              username: userCtrl.text.trim().isEmpty ? profile.username : userCtrl.text.trim(),
              isAdmin: profile.isAdmin, useHttps: useHttps,
            );
            final ps = ProfileService();
            final profiles = await ps.loadProfiles();
            final idx = profiles.indexWhere((p) => p.name == profile.name);
            if (idx >= 0) profiles[idx] = newProfile; else profiles.add(newProfile);
            await ps.saveProfiles(profiles);

            if (passCtrl.text.isNotEmpty) {
              final scheme = useHttps ? "https" : "http";
              try {
                final resp = await http.post(
                  Uri.parse("$scheme://${hostCtrl.text.trim()}:$port/api/auth/login"),
                  headers: {"Content-Type": "application/json"},
                  body: jsonEncode({"username": userCtrl.text.trim(), "password": passCtrl.text}),
                );
                if (resp.statusCode == 200) {
                  final data = jsonDecode(resp.body);
                  newProfile.authToken = data["token"]?.toString() ?? "";
                  newProfile.username = data["username"]?.toString() ?? userCtrl.text.trim();
                  newProfile.isAdmin = data["is_admin"] == true;
      // newProfile.refreshToken = data["refresh_token"]?.toString() ?? "";
                  profiles[idx] = newProfile;
                  await ps.saveProfiles(profiles);
                  await ps.applyProfile(newProfile);
                }
              } catch (_) {}
            }
            Navigator.pop(ctx, true);
            _reloadProfiles();
          }, child: const Text("保存")),
        ],
      )),
    );
    if (result == true) _reloadProfiles();
  }

  Future<void> _deleteProfile(int index) async {
    final ps = ProfileService();
    _profiles.removeAt(index);
    await ps.saveProfiles(_profiles);
    if (_profiles.isEmpty) setState(() => _showAddServer = true);
    _reloadProfiles();
  }

  Future<void> _reloadProfiles() async {
    final ps = ProfileService();
    final profiles = await ps.loadProfiles();
    final idx = await ps.getActiveIndex();
    if (mounted) setState(() { _profiles = profiles; _activeIndex = idx; });
  }
  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        title: const Text("Sena Repo"),
        centerTitle: true,
        actions: [
          if (_profiles.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: "管理配置",
              onPressed: () => _showProfileManager(),
            ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.asset("assets/icon.png", width: 64, height: 64, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Icon(Icons.dns, size: 56,
                        color: Theme.of(context).colorScheme.primary),
                  ),
                ),
                const SizedBox(height: 8),
                Text("Sena Repo",
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 24),

                if (_profiles.isNotEmpty) ...[
                  _buildProfilesSection(),
                  const SizedBox(height: 16),
                ],

                _buildAddServerButton(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProfilesSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text("已保存的服务器",
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Colors.grey[600], fontWeight: FontWeight.w600)),
      ),
      ...List.generate(_profiles.length, (i) {
        final p = _profiles[i];
        final isActive = i == _activeIndex;
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.15),
            ),
          ),
          child: ListTile(
            leading: CircleAvatar(
              radius: 18,
              backgroundColor: isActive
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Text(p.name[0].toUpperCase(),
                  style: TextStyle(fontWeight: FontWeight.w600,
                      color: isActive ? Theme.of(context).colorScheme.primary : Colors.grey)),
            ),
            title: Row(children: [
              Flexible(child: Text(p.name, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w500))),
              if (p.isAdmin) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.tertiary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text("Admin", style: TextStyle(fontSize: 10,
                      color: Theme.of(context).colorScheme.tertiary, fontWeight: FontWeight.w600)),
                ),
              ],
            ]),
            subtitle: Text("${p.username}@${p.host}:${p.port}",
                style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            trailing: PopupMenuButton<String>(
              onSelected: (action) {
                if (action == "delete") _deleteProfile(i);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: "delete", child: Text("删除", style: TextStyle(color: Colors.red))),
              ],
            ),
            onTap: () => _connectToProfile(p, i),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
        );
      }),
    ]);
  }

  Widget _buildConnectionSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const SizedBox.shrink(),
            Text("添加服务器", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onSurface)),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              tooltip: "收起",
              onPressed: () => setState(() => _showAddServer = false),
              visualDensity: VisualDensity.compact,
            ),
          ]),
          const SizedBox(height: 16),
          TextField(
            controller: _hostCtrl,
            decoration: const InputDecoration(labelText: "服务器地址", prefixIcon: Icon(Icons.computer)),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _portCtrl,
                decoration: const InputDecoration(labelText: "端口", prefixIcon: Icon(Icons.settings_ethernet)),
                keyboardType: TextInputType.number,
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              height: 56,
              child: FilledButton.tonal(
                onPressed: _connecting ? null : _connectNewServer,
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
            const Spacer(),
          ]),

          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
            ),

          if (_newApi != null) ...[
            const Divider(height: 32),
            Text(_showRegister ? "注册账户" : "登录到服务器",
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
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
            if (_showRegister) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _passConfirmCtrl,
                decoration: const InputDecoration(labelText: "确认密码", prefixIcon: Icon(Icons.lock)),
                obscureText: true,
              ),
            ],
            if (_loginError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_loginError!,
                    style: TextStyle(
                      color: _loginError!.contains("成功") ? Colors.green : Colors.red,
                      fontSize: 13,
                    )),
              ),
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
    );
  }

  Future<void> _showAddServerDialog() async {
    final hostCtrl = TextEditingController(text: "192.168.1.100");
    final portCtrl = TextEditingController(text: "11451");
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final passConfirmCtrl = TextEditingController();
    var useHttps = false;
    var step = 0;  // 0 = connect, 1 = login
    var showRegister = false;
    var loading = false;
    var error = "";
    var loginError = "";
    ApiClient? api;

    await showDialog(
      context: context,
      barrierDismissible: !loading,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(step == 0 ? "添加服务器" : (showRegister ? "注册账户" : "登录到服务器"),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          content: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (step == 0) ...[
                  TextField(controller: hostCtrl, autofocus: true,
                      decoration: const InputDecoration(labelText: "服务器地址", prefixIcon: Icon(Icons.computer))),
                  const SizedBox(height: 8),
                  TextField(controller: portCtrl,
                      decoration: const InputDecoration(labelText: "端口"), keyboardType: TextInputType.number),
                  const SizedBox(height: 4),
                  Row(children: [
                    SizedBox(height: 32, child: Switch(value: useHttps, onChanged: (v) => setD(() => useHttps = v))),
                    Text("HTTPS", style: TextStyle(fontSize: 13, color: Colors.grey[600])),
                  ]),
                ],
                if (step == 1) ...[
                  TextField(controller: userCtrl, autofocus: true,
                      decoration: const InputDecoration(labelText: "用户名", prefixIcon: Icon(Icons.person))),
                  const SizedBox(height: 8),
                  TextField(controller: passCtrl,
                      decoration: const InputDecoration(labelText: "密码"), obscureText: true),
                  if (showRegister) ...[
                    const SizedBox(height: 8),
                    TextField(controller: passConfirmCtrl,
                        decoration: const InputDecoration(labelText: "确认密码"), obscureText: true),
                  ],
                ],
                if (error.isNotEmpty)
                  Padding(padding: const EdgeInsets.only(top: 8),
                      child: Text(error, style: const TextStyle(color: Colors.red, fontSize: 13))),
                if (loginError.isNotEmpty)
                  Padding(padding: const EdgeInsets.only(top: 8),
                      child: Text(loginError,
                          style: TextStyle(color: loginError.contains("成功") ? Colors.green : Colors.red, fontSize: 13))),
                if (step == 1)
                  Padding(padding: const EdgeInsets.only(top: 4),
                      child: TextButton(
                        onPressed: () => setD(() { showRegister = !showRegister; loginError = ""; }),
                        child: Text(showRegister ? "已有账户？登录" : "没有账户？注册", style: const TextStyle(fontSize: 13)),
                      )),
              ]),
            ),
          ),
          actions: [
            if (!loading) TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("取消"),
            ),
            FilledButton(
              onPressed: loading ? null : () async {
                if (step == 0) {
                  // Connect to server
                  final host = hostCtrl.text.trim();
                  final port = int.tryParse(portCtrl.text.trim()) ?? 11451;
                  if (host.isEmpty) { setD(() => error = "请输入服务器地址"); return; }
                  setD(() { loading = true; error = ""; });

                  final settings = context.read<SettingsProvider>();
                  final ok = await settings.connect(host, port, useHttps: useHttps);
                  if (!ok) { setD(() { loading = false; error = settings.errorMessage ?? "连接失败"; }); return; }

                  api = ApiClient();
                  api!.connect(host, port: port, useHttps: useHttps);

                  final needsSetup = await api!.checkSetupNeeded();
                  if (needsSetup) {
                    Navigator.pop(ctx);
                    final setupResult = await Navigator.push(
                      context, MaterialPageRoute(builder: (_) => SetupWizardScreen(api: api!)),
                    );
                    if (setupResult != null && mounted) {
                      final creds = setupResult as Map;
                      final loginResult = await api!.login(
                          creds["username"]?.toString() ?? "", creds["password"]?.toString() ?? "");
                      if (loginResult != null) {
                        final uname = loginResult["username"]?.toString() ?? "";
                        await ProfileService().saveCurrentAsProfile(uname);
                        await _goHome(games: context.read<GameProvider>());
                      }
                    }
                    return;
                  }

                  setD(() { step = 1; loading = false; error = ""; });
                } else if (showRegister) {
                  // Register
                  if (userCtrl.text.trim().isEmpty) { setD(() => loginError = "请输入用户名"); return; }
                  if (passCtrl.text.length < 4) { setD(() => loginError = "密码至少4位"); return; }
                  if (passCtrl.text != passConfirmCtrl.text) { setD(() => loginError = "两次密码不一致"); return; }
                  setD(() { loading = true; loginError = ""; });
                  try {
                    final resp = await http.post(
                      Uri.parse("${api!.baseUrl}/api/auth/register"),
                      headers: {"Content-Type": "application/json"},
                      body: jsonEncode({"username": userCtrl.text.trim(), "password": passCtrl.text, "is_admin": false}),
                    );
                    final body = jsonDecode(resp.body);
                    if (resp.statusCode == 200) {
                      if (body["auto_approved"] == true) {
                        final data = await api!.login(userCtrl.text.trim(), passCtrl.text);
                        if (data != null) {
                          Navigator.pop(ctx);
                          await ProfileService().saveCurrentAsProfile(userCtrl.text.trim());
                          await _goHome(games: context.read<GameProvider>());
                          return;
                        }
                      }
                      setD(() { showRegister = false; loading = false; loginError = "注册成功！${body["auto_approved"] == true ? "已自动激活，请登录" : "请等待管理员审批后登录"}"; });
                    } else {
                      setD(() { loading = false; loginError = body["detail"] ?? "注册失败"; });
                    }
                  } catch (e) { setD(() { loading = false; loginError = "连接失败: $e"; }); }
                } else {
                  // Login
                  if (userCtrl.text.trim().isEmpty || passCtrl.text.isEmpty) { setD(() => loginError = "请输入用户名和密码"); return; }
                  setD(() { loading = true; loginError = ""; });
                  final data = await api!.login(userCtrl.text.trim(), passCtrl.text);
                  if (data != null) {
                    Navigator.pop(ctx);
                    final uname = data["username"]?.toString() ?? userCtrl.text.trim();
                    await ProfileService().saveCurrentAsProfile(uname);
                    await _goHome(games: context.read<GameProvider>());
                  } else {
                    setD(() { loginError = "登录失败"; loading = false; });
                  }
                }
              },
              child: loading
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(step == 0 ? "连接" : (showRegister ? "注册" : "登录")),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddServerButton() {
    return SizedBox(
      width: double.infinity,
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AddServerScreen())),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add_circle_outline, size: 22,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                Text("添加服务器",
                    style: TextStyle(fontSize: 15,
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ),
      ),
    );
  }
  void _showProfileManager() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("管理配置"),
        content: SizedBox(
          width: 320,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min,
                children: List.generate(_profiles.length, (i) {
              final p = _profiles[i];
              return ListTile(
                title: Text(p.name),
                subtitle: Text("${p.username}@${p.host}:${p.port}",
                    style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(icon: const Icon(Icons.edit, size: 20), tooltip: "编辑", onPressed: () {
                    Navigator.pop(ctx);
                    _editProfile(p);
                  }),
                  IconButton(icon: const Icon(Icons.delete, size: 20, color: Colors.red), tooltip: "删除", onPressed: () {
                    Navigator.pop(ctx);
                    _deleteProfile(i);
                  }),
                ]),
              );
            })),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("关闭"))],
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