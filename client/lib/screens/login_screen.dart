/// Login screen with registration option.

import "package:flutter/material.dart";
import "package:http/http.dart" as http;
import "dart:convert";

import "../services/api_client.dart";

class LoginScreen extends StatefulWidget {
  final ApiClient api;
  const LoginScreen({super.key, required this.api});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _passConfirmCtrl = TextEditingController();
  bool _loading = false;
  String? _error;
  bool _showRegister = false;
  bool _regAsAdmin = false;

  Future<void> _login() async {
    if (_userCtrl.text.trim().isEmpty || _passCtrl.text.isEmpty) {
      setState(() => _error = "请输入用户名和密码");
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final resp = await http.post(
        Uri.parse("${widget.api.baseUrl}/api/auth/login"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "username": _userCtrl.text.trim(),
          "password": _passCtrl.text,
        }),
      );
      if (resp.statusCode == 200) {
        if (mounted) Navigator.pop(context, jsonDecode(resp.body));
      } else {
        final body = jsonDecode(resp.body);
        setState(() => _error = body["detail"] ?? "登录失败");
      }
    } catch (e) {
      setState(() => _error = "连接失败: $e");
    }
    setState(() => _loading = false);
  }

  Future<void> _register() async {
    if (_userCtrl.text.trim().isEmpty) {
      setState(() => _error = "请输入用户名");
      return;
    }
    if (_passCtrl.text.isEmpty || _passCtrl.text.length < 4) {
      setState(() => _error = "密码至少4位");
      return;
    }
    if (_passCtrl.text != _passConfirmCtrl.text) {
      setState(() => _error = "两次密码不一致");
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final resp = await http.post(
        Uri.parse("${widget.api.baseUrl}/api/auth/register"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "username": _userCtrl.text.trim(),
          "password": _passCtrl.text,
          "is_admin": _regAsAdmin,
        }),
      );
      final body = jsonDecode(resp.body);
      if (resp.statusCode == 200) {
        setState(() {
          _error = body["auto_approved"] == true
              ? "注册成功！首个账户已自动激活，请登录"
              : "注册成功！请等待管理员审批后登录";
          _showRegister = false;
        });
      } else {
        setState(() => _error = body["detail"] ?? "注册失败");
      }
    } catch (e) {
      setState(() => _error = "连接失败: $e");
    }
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: Center(
        child: SizedBox(
          width: 400,
          child: Stack(children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock, size: 48,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    _showRegister ? "注册账户" : "登录",
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _userCtrl,
                    decoration: const InputDecoration(
                        labelText: "用户名", prefixIcon: Icon(Icons.person)),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _passCtrl,
                    decoration: const InputDecoration(
                        labelText: "密码", prefixIcon: Icon(Icons.lock)),
                    obscureText: true,
                  ),
                  if (_showRegister) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _passConfirmCtrl,
                      decoration: const InputDecoration(
                          labelText: "确认密码", prefixIcon: Icon(Icons.lock)),
                      obscureText: true,
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      title: const Text("注册为管理员"),
                      value: _regAsAdmin,
                      onChanged: (v) => setState(() => _regAsAdmin = v),
                      dense: true,
                    ),
                  ],
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(_error!,
                          style: TextStyle(
                              color: _error!.contains("成功")
                                  ? Colors.green
                                  : Colors.red)),
                    ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _loading ? null : (_showRegister ? _register : _login),
                      child: _loading
                          ? const SizedBox(width: 20, height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(_showRegister ? "注册" : "登录"),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => setState(() {
                      _showRegister = !_showRegister;
                      _error = null;
                    }),
                    child: Text(_showRegister ? "已有账户？登录" : "没有账户？注册"),
                  ),
                ],
              ),
            ),
          ),
            // Back button — top left of card
            Positioned(
              left: 0, top: 0,
              child: IconButton(
                icon: const Icon(Icons.arrow_back, size: 20),
                tooltip: "返回",
                onPressed: () => Navigator.pop(context),
                style: IconButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.8),
                ),
              ),
            ),
          ]),
        ),
      ),
    ),
    );
  }
}
