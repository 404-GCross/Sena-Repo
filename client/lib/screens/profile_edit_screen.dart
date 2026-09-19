/// Profile edit screen — change username, password, avatar.

import "dart:convert";

import "package:file_picker/file_picker.dart";
import "package:flutter/material.dart";
import "../services/logged_http.dart" as http;
import "package:provider/provider.dart";

import "../providers/game_provider.dart";
import "../services/api_client.dart";
import "../services/secure_store.dart";
import "../utils/theme_utils.dart";
import "../widgets/app_shell.dart";

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
  bool _changed = false;

  String get _baseUrl => context.read<GameProvider>().api.baseUrl;

  /// Resolve avatar URL from any path format (server filesystem path, API path, or filename).
  int _avatarVersion = DateTime.now().millisecondsSinceEpoch;

  int _parseUserId(Object? value) {
    final id = value is int ? value : int.tryParse(value?.toString() ?? "");
    return id != null && id > 0 ? id : 0;
  }

  String? get _avatarUrl {
    if (_avatarPath == null || _avatarPath!.isEmpty) return null;
    String url;
    if (_avatarPath!.startsWith("http")) {
      url = _avatarPath!;
    } else if (_avatarPath!.contains("/api/files/avatars/")) {
      url = "$_baseUrl$_avatarPath";
    } else {
      final name = _avatarPath!.split(RegExp(r'[/\\]')).last;
      url = "$_baseUrl/api/files/avatars/$name";
    }
    return "$url?v=$_avatarVersion";
  }

  Future<Map<String, String>> get _authHeaders async {
    final token = await SecureStore.getString("auth_token") ?? "";
    return {
      "Authorization": "Bearer $token",
      "Content-Type": "application/json",
    };
  }

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  Future<void> _loadUser() async {
    try {
      final resp = await http.get(
        Uri.parse("$_baseUrl/api/auth/profile/me"),
        headers: await _authHeaders,
      );
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final userId = _parseUserId(data["id"]);
        await ApiClient.persistSessionInfo(
          userId: userId,
          username: data["username"]?.toString(),
          isAdmin: data["is_admin"] == true,
          role: data["role"]?.toString(),
        );
        if (mounted)
          setState(() {
            _userCtrl.text = data["username"] ?? "";
            _avatarPath = data["avatar_path"];
            _avatarVersion = DateTime.now().millisecondsSinceEpoch;
            _userId = userId;
            _loading = false;
          });
      } else if (mounted) {
        setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
      _msg = null;
    });

    try {
      if (_userId <= 0) {
        setState(() {
          _error = "未获取到用户 ID，请重新进入个人信息页";
          _saving = false;
        });
        return;
      }
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
          headers: await _authHeaders,
          body: jsonEncode(body),
        );
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        if (resp.statusCode == 200) {
          final newToken = data["new_token"]?.toString();
          await ApiClient.persistSessionInfo(
            accessToken: newToken,
            userId: _userId,
            username: data["username"]?.toString() ?? newName,
          );
          _changed = true;
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

    if (_userId <= 0) {
      setState(() => _error = "未获取到用户 ID，请重新进入个人信息页");
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final uri = Uri.parse("$_baseUrl/api/auth/profile/$_userId/avatar");
      final request = http.MultipartRequest("POST", uri);
      final h = await _authHeaders;
      request.headers.addAll(h);
      request.files.add(
        await http.MultipartFile.fromPath("file", result.files.single.path!),
      );
      final resp = await request.send();
      if (resp.statusCode == 200) {
        final data = jsonDecode(await resp.stream.bytesToString())
            as Map<String, dynamic>;
        // Use "url" (API path) not "avatar_path" (server filesystem path)
        final url = data["url"]?.toString() ?? "";
        setState(() {
          _avatarPath = url;
          _avatarVersion = DateTime.now().millisecondsSinceEpoch;
          _changed = true;
          _msg = "头像更新成功";
        });
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

    return AppScaffold(
      title: "个人信息",
      subtitle: "更新头像、用户名和登录密码",
      leading: const Icon(Icons.account_circle_outlined, size: 24),
      scrollable: false,
      maxWidth: 760,
      onBack: () => Navigator.pop(context, _changed),
      child: _loading
          ? const AppStateView.loading(title: "正在读取个人信息")
          : ListView(
              children: [
                _avatarCard(hasAvatar),
                const SizedBox(height: 16),

                // ── Messages ──
                if (_error != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Colors.red.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.error_outline,
                          size: 18,
                          color: Colors.red,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _error!,
                            style: const TextStyle(
                              color: Colors.red,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_msg != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Colors.green.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.check_circle,
                          size: 18,
                          color: Colors.green,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _msg!,
                            style: const TextStyle(
                              color: Colors.green,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                AppSurface(
                  padding: const EdgeInsets.all(16),
                  radius: AppRadius.lg,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _section("用户名"),
                      TextField(
                        controller: _userCtrl,
                        decoration: _dec("用户名"),
                        style: const TextStyle(fontSize: 15),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                AppSurface(
                  padding: const EdgeInsets.all(16),
                  radius: AppRadius.lg,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _section("修改密码"),
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
                    ],
                  ),
                ),
                const SizedBox(height: 32),

                // ── Save ──
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.save, size: 18),
                  label: Text(_saving ? "保存中..." : "保存修改"),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 4),
        child: Text(
          t,
          style: AppText.bodyMedium.copyWith(
            fontWeight: FontWeight.w600,
            color: subTextColor(context),
          ),
        ),
      );

  Widget _avatarCard(bool hasAvatar) {
    return AppSurface(
      padding: const EdgeInsets.all(16),
      radius: AppRadius.lg,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 520;
          final avatar = _avatarPreview(
            hasAvatar: hasAvatar,
            radius: compact ? 26 : 44,
          );
          final info = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "头像",
                style: AppText.bodyMedium.copyWith(
                  fontWeight: FontWeight.w700,
                  color: sectionTextColor(context),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                "支持 JPG / PNG / WebP / GIF，最大 5MB。",
                style: AppText.bodySmall.copyWith(color: hintColor(context)),
              ),
            ],
          );
          final button = FilledButton.icon(
            onPressed: _saving ? null : _pickAvatar,
            icon: const Icon(Icons.photo_camera_outlined, size: 18),
            label: const Text("选择图片"),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          );

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    avatar,
                    const SizedBox(width: 14),
                    Expanded(child: info),
                  ],
                ),
                const SizedBox(height: 14),
                button,
              ],
            );
          }

          return Row(
            children: [
              avatar,
              const SizedBox(width: 18),
              Expanded(child: info),
              const SizedBox(width: 16),
              button,
            ],
          );
        },
      ),
    );
  }

  Widget _avatarPreview({required bool hasAvatar, required double radius}) {
    final diameter = radius * 2;
    final initial =
        _userCtrl.text.isNotEmpty ? _userCtrl.text[0].toUpperCase() : "?";
    final avatarUrl = _avatarUrl;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.4),
              width: radius >= 40 ? 3 : 2,
            ),
            boxShadow: [
              BoxShadow(
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.15),
                blurRadius: radius >= 40 ? 22 : 12,
              ),
            ],
          ),
          child: CircleAvatar(
            radius: radius,
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            child: hasAvatar && avatarUrl != null
                ? ClipOval(
                    child: Image.network(
                      avatarUrl,
                      headers: mediaAuthHeaders,
                      width: diameter,
                      height: diameter,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Text(
                        initial,
                        style: TextStyle(
                          fontSize: radius * 0.68,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  )
                : Text(
                    initial,
                    style: TextStyle(
                      fontSize: radius * 0.68,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
          ),
        ),
        Positioned(
          bottom: -2,
          right: -2,
          child: Material(
            color: Theme.of(context).colorScheme.primary,
            shape: const CircleBorder(),
            child: InkWell(
              onTap: _saving ? null : _pickAvatar,
              customBorder: const CircleBorder(),
              child: Padding(
                padding: EdgeInsets.all(radius >= 40 ? 7 : 5),
                child: Icon(
                  Icons.camera_alt,
                  size: radius >= 40 ? 18 : 14,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  InputDecoration _dec(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: AppText.bodyMedium.copyWith(color: Colors.grey[600]),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
          borderSide: BorderSide(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.4),
          ),
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
