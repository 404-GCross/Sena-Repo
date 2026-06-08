/// Setup wizard — runs when server hasn't been initialized.

import "package:flutter/material.dart";
import "package:http/http.dart" as http;
import "dart:convert";

import "../services/api_client.dart";

class SetupWizardScreen extends StatefulWidget {
  final ApiClient api;
  const SetupWizardScreen({super.key, required this.api});

  @override
  State<SetupWizardScreen> createState() => _SetupWizardScreenState();
}

class _SetupWizardScreenState extends State<SetupWizardScreen> {
  final _usernameCtrl = TextEditingController(text: "admin");
  final _passwordCtrl = TextEditingController();
  final _dirsCtrl = TextEditingController(text: "/games");
  bool _loading = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final dirs = _dirsCtrl.text
          .split("\n")
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();

      final resp = await http.post(
        Uri.parse("${widget.api.baseUrl}/api/setup/initialize"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "admin_username": _usernameCtrl.text.trim(),
          "admin_password": _passwordCtrl.text,
          "game_dirs": dirs,
        }),
      );

      if (resp.statusCode == 200) {
        // Trigger scan
        await http.post(
          Uri.parse("${widget.api.baseUrl}/api/roots/refresh-all"),
        );
        if (mounted) Navigator.pop(context, true);
      } else {
        final body = jsonDecode(resp.body);
        setState(() => _error = body["detail"] ?? "设置失败");
      }
    } catch (e) {
      setState(() => _error = "$e");
    }
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("初次设置")),
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
                    const Icon(Icons.tune, size: 48, color: Colors.deepPurple),
                    const SizedBox(height: 16),
                    const Text(
                      "欢迎使用 Sena Repo",
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "检测到服务端尚未初始化，请完成基础设置",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[500]),
                    ),
                    const SizedBox(height: 24),

                    // Admin account
                    const Text("管理员账户", style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _usernameCtrl,
                      decoration: const InputDecoration(
                        labelText: "用户名",
                        prefixIcon: Icon(Icons.person),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _passwordCtrl,
                      decoration: const InputDecoration(
                        labelText: "密码",
                        prefixIcon: Icon(Icons.lock),
                      ),
                      obscureText: true,
                    ),
                    const SizedBox(height: 20),

                    // Game directories
                    const Text("游戏目录", style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(
                      "每行一个路径，服务端将扫描这些目录下的游戏",
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _dirsCtrl,
                      decoration: const InputDecoration(
                        hintText: "/games\n/nas/galgame",
                        prefixIcon: Icon(Icons.folder),
                      ),
                      maxLines: 4,
                    ),
                    const SizedBox(height: 24),

                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Text(_error!, style: const TextStyle(color: Colors.red)),
                      ),

                    FilledButton(
                      onPressed: _loading ? null : _submit,
                      child: _loading
                          ? const SizedBox(
                              width: 20, height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text("完成设置并开始扫描"),
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
}
