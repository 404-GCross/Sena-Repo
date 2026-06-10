/// Profile / my page.

import "dart:convert";

import "package:flutter/material.dart";
import "package:http/http.dart" as http;
import "package:provider/provider.dart";
import "package:shared_preferences/shared_preferences.dart";

import "../providers/settings_provider.dart";
import "../services/profile_service.dart";
import "profile_switch_screen.dart";
import "settings_screen.dart";
import "notification_screen.dart";
import "connect_screen.dart";
import "download_manager_screen.dart";
import "../providers/game_provider.dart";
import "../utils/theme_utils.dart";

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String _username = "";
  String _serverInfo = "";
  String? _avatarPath;
  int _userId = 0;

  @override
  void initState() {
    super.initState();
    _loadUserInfo();
  }

  void _switchProfile() {
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => const ProfileSwitchScreen()));
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
    if (_userId > 0) {
      try {
        final resp = await http.get(Uri.parse(
            "${context.read<GameProvider>().api.baseUrl}/api/auth/profile/$_userId"));
        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body) as Map<String, dynamic>;
          if (mounted) setState(() => _avatarPath = data["avatar_path"]);
        }
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
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
              backgroundImage: _avatarPath != null && _avatarPath!.isNotEmpty
                  ? NetworkImage("${context.read<GameProvider>().api.baseUrl}/api/files/avatars/${_avatarPath!.split("/").last}")
                  : null,
              child: _avatarPath == null || _avatarPath!.isEmpty
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
            style: TextStyle(fontSize: 14, color: Colors.grey[500]),
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
            trailing: "Sena Repo v0.1.0",
            onTap: () => _showAbout(context),
          ),
        ]),
        const SizedBox(height: 32),

        // ── Switch user + Logout ──
        Center(
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              icon: const Icon(Icons.swap_horiz, size: 18),
              label: const Text("切换用户"),
              onPressed: _switchProfile,
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
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
          ]),
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _menuCard(List<Widget> children) => Container(
    decoration: BoxDecoration(
      color: cardBg(context),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
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
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 22, color: Colors.white70),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(trailing, style: TextStyle(fontSize: 13, color: Colors.grey[500])),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: Colors.grey[600], size: 20),
        ]),
      ),
    );
  }

  Widget _menuDivider() => Divider(height: 1, indent: 68, color: Colors.white.withValues(alpha: 0.06));

  void _showAbout(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          Icon(Icons.info_outline, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          const Text("关于"),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Sena Repo", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text("版本: 0.1.0", style: TextStyle(fontSize: 14, color: Colors.grey[500])),
            const SizedBox(height: 12),
            Text("GalGame 私人图书馆管理器", style: TextStyle(fontSize: 13, color: Colors.grey[400])),
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
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove("auth_token");
      await prefs.remove("username");
      await prefs.remove("is_admin");
      if (context.mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const ConnectScreen()),
          (_) => false,
        );
      }
    }
  }
}
