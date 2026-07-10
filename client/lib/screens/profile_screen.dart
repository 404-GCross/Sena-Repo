/// Profile / my page.

import "dart:convert";

import "package:flutter/material.dart";
import "package:http/http.dart" as http;
import "package:provider/provider.dart";
import "package:shared_preferences/shared_preferences.dart";

import "../providers/settings_provider.dart";
import "../utils/theme_utils.dart";
import "../utils/version.dart";
import "../services/api_client.dart";
import "profile_switch_screen.dart";
import "settings_screen.dart";
import "notification_screen.dart";
import "connect_screen.dart";
import "download_manager_screen.dart";
import "../providers/game_provider.dart";

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String _username = "";
  String _serverInfo = "";
  String _serverVersion = "";
  String? _avatarPath;
  int _userId = 0;
  int _avatarVersion = DateTime.now().millisecondsSinceEpoch;
  int _lastLoadTime = 0;
  int _lastVersionLoadTime = 0;

  String? get _avatarUrl {
    if (_avatarPath == null || _avatarPath!.isEmpty) return null;
    final name = _avatarPath!.split(RegExp(r'[/\\]')).last;
    return "${context.read<GameProvider>().api.baseUrl}/api/files/avatars/$name?v=$_avatarVersion";
  }

  @override
  void initState() {
    super.initState();
    _loadUserInfo();
    _loadServerVersion();
  }

  Future<void> refresh() async {
    await _loadUserInfo();
    _loadServerVersion();
  }

  void _maybeRefresh() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastLoadTime > 10000 && _userId > 0) {
      _loadUserInfo();
    }
    if (now - _lastVersionLoadTime > 30000) {
      _loadServerVersion();
    }
  }


  Future<void> _loadServerVersion() async {
    try {
      final api = context.read<GameProvider>().api;
      final resp = await http.get(Uri.parse("${api.baseUrl}/api/health"));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        if (mounted) setState(() => _serverVersion = data["version"] ?? "");
        _lastVersionLoadTime = DateTime.now().millisecondsSinceEpoch;
      }
    } catch (_) {}
  }

  Future<void> _loadUserInfo() async {
    final prefs = await SharedPreferences.getInstance();
    final settings = context.read<SettingsProvider>();
    final token = prefs.getString("auth_token");
    _userId = int.tryParse(token ?? "") ?? 0;
    if (mounted) {
      setState(() {
        _username = prefs.getString("username") ?? "Sena Repo";
        _serverInfo = "服务器: ${settings.serverHost}:${settings.serverPort}";
      });
    }
    // Try loading avatar from server
    try {
      final resp = await http.get(Uri.parse(
          "${context.read<GameProvider>().api.baseUrl}/api/auth/profile/me"),
          headers: {"Authorization": "Bearer ${prefs.getString("auth_token") ?? ""}"});
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        if (mounted) setState(() {
          _userId = data["id"] ?? 0;
          _avatarPath = data["avatar_path"];
          _avatarVersion = DateTime.now().millisecondsSinceEpoch;
          _lastLoadTime = DateTime.now().millisecondsSinceEpoch;
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    _maybeRefresh();
    final settings = context.watch<SettingsProvider>();
    final hasCover = settings.serverHost.isNotEmpty;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      children: [
        // ── Avatar & Name ──
        const SizedBox(height: 16),
        Center(
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
                width: 3,
              ),
              boxShadow: [
                BoxShadow(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                  blurRadius: 20,
                ),
              ],
            ),
            child: CircleAvatar(
              radius: 44,
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              backgroundImage: _avatarUrl != null
                  ? NetworkImage(_avatarUrl!)
                  : null,
              child: _avatarUrl == null
                  ? Text(
                      _username.isNotEmpty ? _username[0].toUpperCase() : "S",
                      style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary),
                    )
                  : null,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            _username,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text(
            "服务器: ${settings.serverHost}:${settings.serverPort}",
            style: AppText.bodyMedium.copyWith( color: hintColor(context)),
          ),
        ),
        const SizedBox(height: 32),

        // ── Menu Items ──
        _menuCard([
          _menuItem(
            icon: Icons.settings,
            title: "设置",
            trailing: "服务器、刮削源、显示",
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ]),
        const SizedBox(height: 16),
        _menuCard([
          _menuItem(
            icon: Icons.info_outline,
            title: "关于",
            trailing: "客户端 v$appVersion  ·  服务端 ${_serverVersion.isNotEmpty ? "v$_serverVersion" : "..."}",
            onTap: () => _showAbout(context),
          ),
        ]),
        const SizedBox(height: 32),

        const SizedBox(height: 32),

        // Logout
        Center(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.red,
              side: BorderSide(color: Colors.red.withValues(alpha: 0.4)),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            icon: const Icon(Icons.logout, size: 18),
            label: const Text("退出登录"),
            onPressed: _logout,
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _menuCard(List<Widget> children) => Container(
    decoration: BoxDecoration(
      color: cardBg(context),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: cardBorder(context)),
    ),
    child: Column(children: children),
  );

  Widget _menuItem({
    required IconData icon,
    required String title,
    required String trailing,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: cardBorder(context),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 22, color: sectionTextColor(context)),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(trailing, style: AppText.bodySmall.copyWith( color: hintColor(context))),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: Colors.grey[600], size: 20),
        ]),
      ),
    );
  }

  Widget _menuDivider() => Divider(height: 1, indent: 68, color: cardBorder(context));

  void _showAbout(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Column(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image.asset("assets/icon.png", width: 56, height: 56),
          ),
          const SizedBox(height: 12),
          const Text("Sena Repo", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text("客户端 v$appVersion  ·  服务端 ${_serverVersion.isNotEmpty ? "v$_serverVersion" : "未知"}",
              style: TextStyle(fontSize: 13, color: cs.primary)),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Divider(),
            const SizedBox(height: 8),
            Text("GalGame 私有库管理器", style: AppText.bodyMedium.copyWith(color: subTextColor(context))),
            const SizedBox(height: 12),
            InkWell(
              onTap: () {},
              child: Text("github.com/404-GCross/Sena-Repo",
                  style: TextStyle(fontSize: 12, color: cs.primary.withValues(alpha: 0.8))),
            ),
          ],
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text("确定")),
        ],
      ),
    );
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("退出登录"),
        content: const Text("确定退出登录吗？"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("取消")),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("确定")),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await ApiClient.clearTokens();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove("active_profile_index");
      await prefs.remove("auth_token");
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const ConnectScreen()),
          (_) => false,
        );
      }
    }
  }
}
