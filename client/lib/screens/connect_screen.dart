/// Initial screen: connect to Sena Repo server.

import "dart:io" show Platform;
import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../providers/settings_provider.dart";
import "../providers/game_provider.dart";
import "../utils/theme_utils.dart";
import "../services/profile_service.dart";
import "home_screen.dart";
import "profile_switch_screen.dart";
import "package:file_picker/file_picker.dart";
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

      // Check if we have a saved token → skip login, otherwise show login
      final api = games.api;
      final prefs = await SharedPreferences.getInstance();
      final savedToken = prefs.getString("auth_token");
      if (savedToken != null && savedToken.isNotEmpty) {
        api.setToken(savedToken);
      } else {
        final loginResult = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => LoginScreen(api: api)),
        );
        if (loginResult == null) return;
        if (loginResult is Map) {
          final token = loginResult["token"]?.toString() ?? "";
          await prefs.setString("auth_token", token);
          await prefs.setString("username", loginResult["username"]?.toString() ?? "");
          await prefs.setBool("is_admin", loginResult["is_admin"] == true);
          api.setToken(token);
          await ProfileService().saveCurrentAsProfile(loginResult["username"]?.toString() ?? "默认");
        }
      }

      if (!mounted) return;

      // ── Client first-run setup: choose download + Steam directories ──
      final clientSetupDone = prefs.getBool("client_setup_done") ?? false;
      if (!clientSetupDone) {
        if (mounted) {
          await showDialog(context: context, barrierDismissible: false,
            builder: (ctx) => _ClientSetupDialog(onDone: () => Navigator.pop(ctx)),
          );
          await prefs.setBool("client_setup_done", true);
        }
        if (!mounted) return;
      }

      // Always check if setup is needed (new server or no roots configured)
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

// ── First-run client setup dialog ──
class _ClientSetupDialog extends StatefulWidget {
  final VoidCallback onDone;
  const _ClientSetupDialog({required this.onDone});

  @override
  State<_ClientSetupDialog> createState() => _ClientSetupDialogState();
}

class _ClientSetupDialogState extends State<_ClientSetupDialog> {
  String _downloadDir = "";
  String _steamDir = "";

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final dd = prefs.getString("local_download_dir") ?? "";
    final sd = prefs.getString("steam_common_dir") ?? "";
    setState(() { _downloadDir = dd; _steamDir = sd; });
  }

  Future<void> _pickDownloadDir() async {
    final result = await FilePicker.platform.getDirectoryPath(dialogTitle: "选择游戏下载目录");
    if (result != null) {
      setState(() => _downloadDir = result);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("local_download_dir", result);
    }
  }

  Future<void> _pickSteamDir() async {
    final result = await FilePicker.platform.getDirectoryPath(dialogTitle: "选择 Steam common 目录");
    if (result != null) {
      setState(() => _steamDir = result);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString("steam_common_dir", result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text("初始设置", textAlign: TextAlign.center),
      content: SizedBox(width: 400, child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text("首次使用需要设置以下目录，稍后可在设置中修改",
              style: AppText.bodySmall.copyWith(color: Colors.grey)),
          const SizedBox(height: 20),
          _dirCard(Icons.download, "游戏下载目录", _downloadDir, _pickDownloadDir),
          if (!Platform.isAndroid) ...[
            const SizedBox(height: 12),
            _dirCard(Icons.gamepad, "Steam 库目录 (steamapps/common)", _steamDir, _pickSteamDir),
          ],
        ],
      )),
      actions: [
        FilledButton(
          onPressed: widget.onDone,
          child: const Text("完成"),
        ),
      ],
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
          Text(label, style: AppText.bodySmall.copyWith( fontWeight: FontWeight.w500)),
          const SizedBox(height: 2),
          Text(path.isEmpty ? "未设置" : path,
              style: AppText.label.copyWith( color: path.isEmpty ? Colors.red[300] : Colors.grey[600])),
        ])),
        TextButton(onPressed: onPick, child: Text(path.isEmpty ? "选择" : "更换", style: const TextStyle(fontSize: 12))),
      ]),
    );
  }
}
