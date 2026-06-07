/// Profile / my page.

import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../providers/settings_provider.dart";

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
          leading: const Icon(Icons.settings),
          title: const Text("设置"),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            // TODO: settings page
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("设置页面（待实现）")),
            );
          },
        ),
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
