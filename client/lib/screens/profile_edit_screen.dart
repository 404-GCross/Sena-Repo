/// Profile edit screen — change username, password, avatar.

import "dart:convert";
import "dart:io";

import "package:file_picker/file_picker.dart";
import "package:flutter/material.dart";
import "package:http/http.dart" as http;
import "package:provider/provider.dart";
import "package:shared_preferences/shared_preferences.dart";

import "../providers/game_provider.dart";
import "../utils/theme_utils.dart";

class ProfileEditScreen extends StatefulWidget {
  const ProfileEditScreen({super.key});

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  final _userCtrl = TextEditingController();
  final _currentPassCtrl = TextEditingController();
  final _newPassCtrl = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _msg;
  String? _avatarPath;
  int _userId = 0;

  String get _baseUrl => context.read<GameProvider>().api.baseUrl;

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  Future<void> _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString("auth_token");
    if (token == null) return;
    _userId = int.tryParse(token) ?? 0;

    try {
      final resp = await http.get(Uri.parse("$_baseUrl/api/auth/profile/$_userId"));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        if (mounted) setState(() {
          _userCtrl.text = data["username"] ?? "";
          _avatarPath = data["avatar_path"];
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; _msg = null; });

    try {
      final body = <String, dynamic>{};
      final newName = _userCtrl.text.trim();
      if (newName.isNotEmpty) body["username"] = newName;
      if (_newPassCtrl.text.isNotEmpty) {
        body["current_password"] = _currentPassCtrl.text;
        body["new_password"] = _newPassCtrl.text;
      }

      if (body.isNotEmpty) {
        final resp = await http.put(
          Uri.parse("$_baseUrl/api/auth/profile/$_userId"),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode(body),
        );
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        if (resp.statusCode == 200) {
          // Update saved username
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString("username", data["username"] ?? newName);
          _msg = "个人信息更新成功";
          _currentPassCtrl.clear();
          _newPassCtrl.clear();
        } else {
          _error = data["detail"] ?? "更新失败";
        }
      } else {
        _msg = "无变更";
      }
    } catch (e) {
      _error = "$e";
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _pickAvatar() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result == null || result.files.single.path == null) return;

    setState(() { _saving = true; _error = null; });
    try {
      final uri = Uri.parse("$_baseUrl/api/auth/profile/$_userId/avatar");
      final request = http.MultipartRequest("POST", uri);
      request.files.add(await http.MultipartFile.fromPath("file", result.files.single.path!));
      final resp = await request.send();
      if (resp.statusCode == 200) {
        final data = jsonDecode(await resp.stream.bytesToString()) as Map<String, dynamic>;
        setState(() { _avatarPath = data["avatar_path"]; _msg = "头像更新成功"; });
      } else {
        setState(() => _error = "头像上传失败");
      }
    } catch (e) {
      setState(() => _error = "$e");
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final hasAvatar = _avatarPath != null && _avatarPath!.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text("个人信息")),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // ── Avatar ──
                Center(
                  child: Stack(children: [
                    Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4),
                          width: 3,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                            blurRadius: 24,
                          ),
                        ],
                      ),
                      child: CircleAvatar(
                        radius: 52,
                        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                        backgroundImage: hasAvatar
                            ? (_avatarPath!.startsWith("/")
                                ? FileImage(File(_avatarPath!))
                                : NetworkImage("$_baseUrl/api/files/avatars/${_avatarPath!.split("/").last}") as ImageProvider)
                            : null,
                        child: hasAvatar ? null : Text(
                          _userCtrl.text.isNotEmpty ? _userCtrl.text[0].toUpperCase() : "?",
                          style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.primary),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 0, right: 0,
                      child: Material(
                        color: Theme.of(context).colorScheme.primary,
                        shape: const CircleBorder(),
                        child: InkWell(
                          onTap: _pickAvatar,
                          customBorder: const CircleBorder(),
                          child: const Padding(
                            padding: EdgeInsets.all(8),
                            child: Icon(Icons.camera_alt, size: 20, color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 24),

                // ── Messages ──
                if (_error != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.red.withValues(alpha: 0.2)),
                    ),
                    child: Row(children: [
                      const Icon(Icons.error_outline, size: 18, color: Colors.red),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13))),
                    ]),
                  ),
                if (_msg != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.green.withValues(alpha: 0.2)),
                    ),
                    child: Row(children: [
                      const Icon(Icons.check_circle, size: 18, color: Colors.green),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_msg!, style: const TextStyle(color: Colors.green, fontSize: 13))),
                    ]),
                  ),

                // ── Username ──
                _section("用户名"),
                const SizedBox(height: 6),
                TextField(
                  controller: _userCtrl,
                  decoration: _dec("用户名"),
                  style: const TextStyle(fontSize: 15),
                ),
                const SizedBox(height: 20),

                // ── Password ──
                _section("修改密码"),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: cardBg(context),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: cardBorder(context)),
                  ),
                  child: Column(children: [
                    TextField(
                      controller: _currentPassCtrl,
                      decoration: _dec("当前密码"),
                      obscureText: true,
                      style: const TextStyle(fontSize: 14),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _newPassCtrl,
                      decoration: _dec("新密码（留空不修改）"),
                      obscureText: true,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ]),
                ),
                const SizedBox(height: 32),

                // ── Save ──
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.save, size: 18),
                  label: Text(_saving ? "保存中..." : "保存修改"),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _section(String t) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 4),
    child: Text(t, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: subTextColor(context))),
  );

  InputDecoration _dec(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(fontSize: 14, color: Colors.grey[600]),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: cardBorder(context)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: cardBorder(context)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)),
    ),
  );

  @override
  void dispose() {
    _userCtrl.dispose();
    _currentPassCtrl.dispose();
    _newPassCtrl.dispose();
    super.dispose();
  }
}
