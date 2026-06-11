/// Profile switch / management screen.

import "package:flutter/material.dart";
import "package:http/http.dart" as http;
import "package:shared_preferences/shared_preferences.dart";

import "../services/profile_service.dart";
import "connect_screen.dart";
import "login_screen.dart";
import "../providers/game_provider.dart";
import "../utils/theme_utils.dart";
import "package:provider/provider.dart";
import "package:http/http.dart" as http;
import "dart:convert";

class ProfileSwitchScreen extends StatefulWidget {
  const ProfileSwitchScreen({super.key});

  @override
  State<ProfileSwitchScreen> createState() => _ProfileSwitchScreenState();
}

class _ProfileSwitchScreenState extends State<ProfileSwitchScreen> {
  List<UserProfile> _profiles = [];
  int _activeIndex = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ps = ProfileService();
    final profiles = await ps.loadProfiles();
    final idx = await ps.getActiveIndex();
    if (mounted) setState(() { _profiles = profiles; _activeIndex = idx; _loading = false; });
  }

  Future<void> _addProfile() async {
    final nameCtrl = TextEditingController();
    final hostCtrl = TextEditingController(text: "192.168.1.100");
    final portCtrl = TextEditingController(text: "11451");
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text("新增配置"),
        content: SingleChildScrollView(
          child: SizedBox(width: 300, child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, autofocus: true,
                decoration: const InputDecoration(labelText: "配置名称", hintText: "如: 家里NAS")),
              const SizedBox(height: 8),
              TextField(controller: hostCtrl,
                decoration: const InputDecoration(labelText: "服务器 IP")),
              const SizedBox(height: 8),
              TextField(controller: portCtrl,
                decoration: const InputDecoration(labelText: "端口"), keyboardType: TextInputType.number),
              const SizedBox(height: 8),
              TextField(controller: userCtrl,
                decoration: const InputDecoration(labelText: "用户名")),
              const SizedBox(height: 8),
              TextField(controller: passCtrl,
                decoration: const InputDecoration(labelText: "密码"), obscureText: true),
            ],
          )),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
          FilledButton(onPressed: () async {
            if (nameCtrl.text.trim().isEmpty || hostCtrl.text.trim().isEmpty) return;
            final port = int.tryParse(portCtrl.text.trim()) ?? 11451;
            // Try to login to get token
            try {
              final resp = await http.post(
                Uri.parse("http://${hostCtrl.text.trim()}:$port/api/auth/login"),
                headers: {"Content-Type": "application/json"},
                body: jsonEncode({"username": userCtrl.text.trim(), "password": passCtrl.text}),
              );
              if (resp.statusCode != 200) {
                final err = jsonDecode(resp.body);
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text("登录失败: ${err["detail"]}")),
                  );
                }
                return;
              }
              final data = jsonDecode(resp.body);
              final profile = UserProfile(
                name: nameCtrl.text.trim(),
                host: hostCtrl.text.trim(),
                port: port,
                authToken: data["token"]?.toString() ?? "",
                username: userCtrl.text.trim(),
                isAdmin: data["is_admin"] == true,
              );
              final ps = ProfileService();
              await ps.applyProfile(profile);
              await ps.saveCurrentAsProfile(profile.name);
              Navigator.pop(ctx, true);
            } catch (e) {
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text("连接失败: $e")),
                );
              }
            }
          }, child: const Text("登录并保存")),
        ],
      ),
    );
    if (result == true) _load();
  }

  Future<void> _switchTo(UserProfile profile) async {
    // Validate token before switching — deleted users won't pass
    try {
      final uri = Uri.parse("http://${profile.host}:${profile.port}/api/auth/profile/me");
      final resp = await http.get(uri,
        headers: {"Authorization": "Bearer ${profile.authToken}"});
      if (resp.statusCode != 200) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("此配置已失效，请重新登录")));
        return;
      }
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("无法连接服务器，请检查网络")));
      return;
    }

    await ProfileService().applyProfile(profile);
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const ConnectScreen()),
        (_) => false,
      );
    }
  }

  Future<void> _deleteProfile(int index) async {
    _profiles.removeAt(index);
    await ProfileService().saveProfiles(_profiles);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("切换用户")),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addProfile,
        icon: const Icon(Icons.add),
        label: const Text("新增配置"),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _profiles.isEmpty
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.people_outline, size: 64, color: Colors.grey[600]),
                  const SizedBox(height: 12),
                  Text("暂无保存的配置", style: TextStyle(fontSize: 16, color: hintColor(context))),
                  const SizedBox(height: 4),
                  Text("点击右下角按钮新增", style: AppText.bodySmall.copyWith( color: Colors.grey[600])),
                ]))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _profiles.length,
                  itemBuilder: (_, i) {
                    final p = _profiles[i];
                    final isActive = i == _activeIndex;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      decoration: BoxDecoration(
                        color: cardBg(context),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: isActive
                            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)
                            : cardBorder(context)),
                      ),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: isActive
                              ? Theme.of(context).colorScheme.primaryContainer
                              : cardBorder(context),
                          child: Text(p.name[0].toUpperCase(),
                              style: TextStyle(fontWeight: FontWeight.w600,
                                  color: isActive ? Theme.of(context).colorScheme.primary : Colors.grey[400])),
                        ),
                        title: Row(children: [
                          Text(p.name, style: AppText.body.copyWith( fontWeight: FontWeight.w500)),
                          if (isActive) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text("当前", style: AppText.badge.copyWith( color: Theme.of(context).colorScheme.primary)),
                            ),
                          ],
                        ]),
                        subtitle: Text("${p.username}@${p.host}:${p.port}",
                            style: AppText.bodySmall.copyWith( color: hintColor(context))),
                        trailing: PopupMenuButton<String>(
                          onSelected: (action) {
                            if (action == "switch") _switchTo(p);
                            if (action == "delete") _deleteProfile(i);
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(value: "switch", child: Text("切换到此")),
                            const PopupMenuItem(value: "delete",
                                child: Text("删除", style: TextStyle(color: Colors.red))),
                          ],
                        ),
                        onTap: () => _switchTo(p),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                    );
                  },
                ),
    );
  }
}
