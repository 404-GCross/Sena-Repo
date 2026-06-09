/// Profile / my page.

import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "package:shared_preferences/shared_preferences.dart";

import "../providers/settings_provider.dart";
import "settings_screen.dart";
import "notification_screen.dart";
import "connect_screen.dart";
import "../providers/game_provider.dart";

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SizedBox(height: 24),
        const CircleAvatar(
          radius: 40,
          child: Icon(Icons.person, size: 40),
        ),
        const SizedBox(height: 16),
        const Center(
          child: Text("Sena Repo", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            "服务器: ${settings.serverHost}:${settings.serverPort}",
            style: TextStyle(color: Colors.grey[500]),
          ),
        ),
        const SizedBox(height: 32),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.notifications_outlined),
          title: const Text("通知"),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => NotificationScreen(
                  api: context.read<GameProvider>().api))),
        ),
        ListTile(
          leading: const Icon(Icons.settings),
          title: const Text("设置"),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const SettingsScreen())),
        ),
        const SizedBox(height: 32),
        ListTile(
          leading: const Icon(Icons.logout, color: Colors.red),
          title: const Text("退出登录", style: TextStyle(color: Colors.red)),
          onTap: () async {
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
              if (context.mounted) {
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const ConnectScreen()),
                  (_) => false,
                );
              }
            }
          },
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text("关于"),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            showAboutDialog(
              context: context,
              applicationName: "Sena Repo",
              applicationVersion: "0.1.0",
              applicationLegalese: "GPL-2.0",
            );
          },
        ),
      ],
    );
  }
}
