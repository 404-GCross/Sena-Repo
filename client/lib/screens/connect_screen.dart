/// Initial screen: connect to Sena Repo server.

import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../providers/settings_provider.dart";
import "../providers/game_provider.dart";
import "../services/profile_service.dart";
import "home_screen.dart";
import "profile_switch_screen.dart";
import "setup_wizard_screen.dart";
import "package:shared_preferences/shared_preferences.dart";
import "login_screen.dart";

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _hostController = TextEditingController(text: "192.168.1.100");
  final _portController = TextEditingController(text: "11451");
  bool _useHttps = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final settings = context.read<SettingsProvider>();
      settings.loadSettings().then((_) {
        if (settings.serverHost.isNotEmpty) {
          _hostController.text = settings.serverHost;
          _portController.text = settings.serverPort.toString();
          _useHttps = settings.useHttps;
          _tryAutoConnect();
        }
      });
    });
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _tryAutoConnect() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString("auth_token")?.isNotEmpty == true) _connect();
  }

  Future<void> _connect() async {
    final settings = context.read<SettingsProvider>();
    final games = context.read<GameProvider>();

    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 11451;

    final success = await settings.connect(host, port, useHttps: _useHttps);
    if (success && mounted) {
      games.connect(host, port, useHttps: _useHttps);

      // Check if server needs setup
      final api = games.api;
      final needsSetup = await api.checkSetupNeeded();
      if (needsSetup && mounted) {
        final result = await Navigator.push<bool>(
          context,
          MaterialPageRoute(builder: (_) => SetupWizardScreen(api: api)),
        );
        if (result == true) {
          await games.loadGames();
        }
        if (!mounted) return;
      } else if (mounted) {
        // Check if we have a saved token → skip login
        final prefs = await SharedPreferences.getInstance();
        final savedToken = prefs.getString("auth_token");
        if (savedToken != null && savedToken.isNotEmpty) {
          // Token exists, skip login
          api.setToken(savedToken);
        } else {
          // No token → show login
          final loginResult = await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => LoginScreen(api: api)),
          );
          if (loginResult == null) return; // user went back
          // Save token for auto-login
          if (loginResult is Map) {
            final token = loginResult["token"]?.toString() ?? "";
            await prefs.setString("auth_token", token);
            await prefs.setString("username", loginResult["username"]?.toString() ?? "");
            await prefs.setBool("is_admin", loginResult["is_admin"] == true);
            api.setToken(token);
            // Auto-save as profile
            await ProfileService().saveCurrentAsProfile(loginResult["username"]?.toString() ?? "默认");
          }
        }
      }

      if (!mounted) return;
      await games.loadGames();

      // If no games, ask whether to scan
      if (games.games.isEmpty) {
        final shouldScan = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text("游戏库为空"),
            content: const Text("服务端尚未扫描，是否立即扫描？"),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text("稍后"),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text("开始扫描"),
              ),
            ],
          ),
        );

        if (shouldScan == true && mounted) {
          try {
            await games.api.refreshAllRoots();
            await games.loadGames();
          } catch (_) {
            // Scan failed, continue to home anyway
          }
        }
      }

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();

    return Scaffold(
      body: Center(
        child: SizedBox(
          width: 400,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.dns, size: 64, color: Colors.deepPurple),
                  const SizedBox(height: 16),
                  const Text(
                    "Sena Repo",
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text("连接到仓库"),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _hostController,
                    decoration: const InputDecoration(
                      labelText: "服务器地址",
                      hintText: "192.168.1.100",
                      prefixIcon: Icon(Icons.computer),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _portController,
                    decoration: const InputDecoration(
                      labelText: "端口",
                      prefixIcon: Icon(Icons.settings_ethernet),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  SwitchListTile(
                    title: const Text("使用 HTTPS", style: TextStyle(fontSize: 14)),
                    value: _useHttps,
                    onChanged: (v) => setState(() => _useHttps = v),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  if (settings.errorMessage != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      settings.errorMessage!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton(
                      onPressed: settings.isLoading ? null : _connect,
                      child: settings.isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text("连接"),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
