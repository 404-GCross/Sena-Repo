/// Profile edit screen — change username, password, avatar.

import "dart:convert";

import "package:file_picker/file_picker.dart";
import "package:flutter/material.dart";
import "../services/logged_http.dart" as http;
import "package:provider/provider.dart";

import "../providers/game_provider.dart";
import "../services/api_client.dart";
import "../services/nextmoe_oauth.dart";
import "../services/nextmoe_token_store.dart";
import "../utils/theme_utils.dart";
import "../utils/source_icons.dart";
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
  Map<String, dynamic>? _binding;
  bool _bindingBusy = false;
  bool _passwordSet = true;

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
    await ApiClient.restoreToken();
    final token = ApiClient.globalToken ?? "";
    final headers = {"Content-Type": "application/json"};
    if (token.isNotEmpty) {
      headers["Authorization"] = "Bearer $token";
    }
    return headers;
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
            _passwordSet = data["password_set"] != false;
            _loading = false;
          });
        _loadBinding();
      } else if (mounted) {
        setState(() {
          _loading = false;
          _error = resp.statusCode == 401
              ? "登录已失效，请重新登录"
              : "加载失败（HTTP ${resp.statusCode}）";
        });
      }
    } catch (e) {
      if (mounted)
        setState(() {
          _loading = false;
          _error = "加载失败: $e";
        });
    }
  }

  Future<void> _loadBinding() async {
    final binding = await context.read<GameProvider>().api.getOauthBinding();
    if (!mounted || binding == null) return;
    setState(() {
      _binding = binding;
      if (binding["password_set"] is bool) {
        _passwordSet = binding["password_set"] == true;
      }
    });
  }

  Future<void> _bindNextmoe() async {
    if (_bindingBusy) return;
    setState(() {
      _bindingBusy = true;
      _error = null;
      _msg = null;
    });
    final api = context.read<GameProvider>().api;
    final outcome = await NextmoeOAuth.authorize(api, purpose: "bind");
    if (!mounted) return;
    setState(() => _bindingBusy = false);
    switch (outcome.kind) {
      case NextmoeAuthKind.bound:
        await _loadBinding();
        if (mounted) {
          setState(() {
            _msg = outcome.boundName.isEmpty
                ? "已绑定 鲲Galgame账号"
                : "已绑定 鲲Galgame账号：${outcome.boundName}";
          });
        }
        return;
      case NextmoeAuthKind.error:
        if (outcome.cancelled) return;
        setState(() => _error = outcome.error);
        return;
      case NextmoeAuthKind.pending:
      case NextmoeAuthKind.rejected:
      case NextmoeAuthKind.session:
        return;
    }
  }

  Future<void> _unbindNextmoe() async {
    if (_bindingBusy) return;
    final name = _binding?["name"]?.toString() ?? "";
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          "解除 鲲Galgame 绑定？",
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        content: Text(
          "解绑后${name.isEmpty ? "该 鲲Galgame账号" : "「$name」"}将无法再登录本服务器；"
          "你需要改用用户名和密码登录。",
          style: const TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text("取消"),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(c, true),
            child: const Text("解除绑定"),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _bindingBusy = true;
      _error = null;
      _msg = null;
    });
    try {
      final api = context.read<GameProvider>().api;
      await api.unbindOauth();
      await NextmoeTokenStore.clear(api);
      await _loadBinding();
      if (mounted) setState(() => _msg = "已解除 鲲Galgame 绑定");
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = "解除绑定失败: $e");
    } finally {
      if (mounted) setState(() => _bindingBusy = false);
    }
  }

  Widget _nextmoeMark(double size) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.25),
      child: Image.asset(
        kungalgameIcon,
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    );
  }

  Widget _bindingChip(bool bound) {
    final color = bound ? Colors.green : hintColor(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        bound ? "已绑定" : "未绑定",
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _thirdPartyCard() {
    final binding = _binding;
    final bound = binding != null && binding["bound"] == true;
    final name = binding?["name"]?.toString() ?? "";
    final oauthId = binding?["user_id"]?.toString() ?? "";
    return AppSurface(
      padding: const EdgeInsets.all(16),
      radius: AppRadius.lg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _section("第三方账号"),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _nextmoeMark(38),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          "鲲Galgame",
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _bindingChip(bound),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (bound)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color:
                              Theme.of(context).colorScheme.surfaceContainerLow,
                          border: Border.all(
                            color:
                                Theme.of(context).colorScheme.outlineVariant,
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    name.isEmpty ? "已绑定账号" : name,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  if (oauthId.isNotEmpty)
                                    Text(
                                      "鲲Galgame ID · $oauthId",
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        color: hintColor(context),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            const Icon(
                              Icons.check_circle,
                              size: 18,
                              color: Colors.green,
                            ),
                          ],
                        ),
                      )
                    else
                      Text(
                        "绑定后可使用 鲲Galgame账号 一键登录本服务器，无需输入密码；"
                        "不会改变用户名与权限。",
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.6,
                          color: hintColor(context),
                        ),
                      ),
                    const SizedBox(height: 12),
                    if (bound)
                      OutlinedButton.icon(
                        onPressed:
                            _bindingBusy || !_passwordSet ? null : _unbindNextmoe,
                        icon: const Icon(Icons.link_off, size: 18),
                        label: const Text("解除绑定"),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red,
                          side: BorderSide(
                            color: Colors.red.withValues(alpha: 0.45),
                          ),
                        ),
                      )
                    else
                      FilledButton.icon(
                        onPressed: _bindingBusy ? null : _bindNextmoe,
                        icon: _bindingBusy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.link, size: 18),
                        label: Text(
                          _bindingBusy ? "等待浏览器授权…" : "绑定 鲲Galgame账号",
                        ),
                      ),
                    if (bound && !_passwordSet)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          "当前账号尚未设置本地密码，请先在「修改密码」中设置后再解除绑定。",
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.5,
                            color: hintColor(context),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
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
                const SizedBox(height: 12),
                _thirdPartyCard(),
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
