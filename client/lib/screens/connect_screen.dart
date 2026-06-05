/// Initial screen: connect to Sena Repo server.

import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../providers/settings_provider.dart";
import "../providers/game_provider.dart";
import "home_screen.dart";

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _hostController = TextEditingController(text: "192.168.1.100");
  final _portController = TextEditingController(text: "11451");

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final settings = context.read<SettingsProvider>();
      settings.loadSettings().then((_) {
        if (settings.serverHost.isNotEmpty) {
          _hostController.text = settings.serverHost;
          _portController.text = settings.serverPort.toString();
        }
      });
    });
  }

  Future<void> _connect() async {
    final settings = context.read<SettingsProvider>();
    final games = context.read<GameProvider>();

    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 11451;

    final success = await settings.connect(host, port);
    if (success && mounted) {
      games.connect(host, port);
      await games.loadGames();
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
                  const Text("连接到游戏服务器"),
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
