/// Profile switch / management screen.

import "package:flutter/material.dart";
import "package:http/http.dart" as http;
import "package:shared_preferences/shared_preferences.dart";

import "../services/profile_service.dart";
import "connect_screen.dart";
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

  bool _useHttps = false;

  Future<void> _addProfile() async {
    await _showProfileEditor(null);
  }

  Future<void> _editProfile(UserProfile p) async {
    await _showProfileEditor(p);
  }

  Future<void> _showProfileEditor(UserProfile? existing) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? "");
    final hostCtrl = TextEditingController(text: existing?.host ?? "192.168.1.100");
    final portCtrl = TextEditingController(text: (existing?.port ?? 11451).toString());
    final userCtrl = TextEditingController(text: existing?.username ?? "");
    final passCtrl = TextEditingController();
    _useHttps = existing?.useHttps ?? false;

    final isEdit = existing != null;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(isEdit ? "缂栬緫閰嶇疆" : "鏂板閰嶇疆"),
        content: SingleChildScrollView(
          child: SizedBox(width: 300, child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, autofocus: !isEdit,
                decoration: const InputDecoration(labelText: "閰嶇疆鍚嶇О", hintText: "濡? 瀹堕噷NAS")),
              const SizedBox(height: 8),
              TextField(controller: hostCtrl,
                decoration: const InputDecoration(labelText: "鏈嶅姟鍣?IP")),
              const SizedBox(height: 8),
              TextField(controller: portCtrl,
                decoration: const InputDecoration(labelText: "绔彛"), keyboardType: TextInputType.number),
              const SizedBox(height: 8),
              SwitchListTile(
                title: const Text("HTTPS", style: TextStyle(fontSize: 14)),
                value: _useHttps,
                onChanged: (v) => setD(() => _useHttps = v),
                dense: true,
              ),
              const SizedBox(height: 8),
              TextField(controller: userCtrl,
                decoration: InputDecoration(labelText: isEdit ? "鐢ㄦ埛鍚嶏紙鐣欑┖涓嶄慨鏀癸級" : "鐢ㄦ埛鍚?)),
              const SizedBox(height: 8),
              TextField(controller: passCtrl,
                decoration: InputDecoration(labelText: isEdit ? "瀵嗙爜锛堢暀绌轰笉淇敼锛? : "瀵嗙爜"), obscureText: true),
            ],
          )),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("鍙栨秷")),
          FilledButton(onPressed: () async {
            if (nameCtrl.text.trim().isEmpty || hostCtrl.text.trim().isEmpty) return;
            final port = int.tryParse(portCtrl.text.trim()) ?? 11451;
            final scheme = _useHttps ? "https" : "http";

            // For edit: if password is empty, keep existing token
            if (isEdit && passCtrl.text.isEmpty && existing != null) {
              final profile = UserProfile(
                name: nameCtrl.text.trim(),
                host: hostCtrl.text.trim(),
                port: port,
                authToken: existing.authToken,
                username: userCtrl.text.trim().isEmpty ? existing.username : userCtrl.text.trim(),
                isAdmin: existing.isAdmin,
                useHttps: _useHttps,
              );
              final ps = ProfileService();
              await ps.applyProfile(profile);
              await saveEditedProfile(profile, existing);
              Navigator.pop(ctx, true);
              return;
            }

            // Try to login to get token
            try {
              final resp = await http.post(
                Uri.parse("$scheme://${hostCtrl.text.trim()}:$port/api/auth/login"),
                headers: {"Content-Type": "application/json"},
                body: jsonEncode({"username": userCtrl.text.trim(), "password": passCtrl.text}),
              );
              if (resp.statusCode != 200) {
                final err = jsonDecode(resp.body);
                if (ctx.mounted) Navigator.pop(ctx);
                _toast("鐧诲綍澶辫触: ${err["detail"]}", title: "閿欒");
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
                useHttps: _useHttps,
              );
              final ps = ProfileService();
              await ps.applyProfile(profile);
              // Remove old profile if editing, then save as new
              if (isEdit && existing != null) {
                await saveEditedProfile(profile, existing);
              } else {
                await ps.saveCurrentAsProfile(profile.name);
              }
              Navigator.pop(ctx, true);
            } catch (e) {
              if (ctx.mounted) Navigator.pop(ctx);
              _toast("杩炴帴澶辫触: $e", title: "閿欒");
            }
          }, child: const Text("淇濆瓨")),
        ],
      )),
    );
    if (result == true) _load();
  }

  Future<void> saveEditedProfile(UserProfile newProfile, UserProfile oldProfile) async {
    final ps = ProfileService();
    final profiles = await ps.loadProfiles();
    final idx = profiles.indexWhere((p) => p.name == oldProfile.name);
    if (idx >= 0) {
      profiles[idx] = newProfile;
    } else {
      profiles.add(newProfile);
    }
    await ps.saveProfiles(profiles);
  }

  void _toast(String msg, {String title = "鎻愮ず"}) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(msg),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("纭畾"))],
      ),
    );
  }

  Future<void> _switchTo(UserProfile profile, int index) async {
    // Validate token before switching 鈥?deleted users won't pass
    try {
      final uri = Uri.parse("${profile.scheme}://${profile.host}:${profile.port}/api/auth/profile/me");
      final resp = await http.get(uri,
        headers: {"Authorization": "Bearer ${profile.authToken}"});
      if (resp.statusCode != 200) {
        _toast("姝ら厤缃凡澶辨晥锛岃閲嶆柊鐧诲綍", title: "閿欒");
        return;
      }
    } catch (_) {
      _toast("鏃犳硶杩炴帴鏈嶅姟鍣紝璇锋鏌ョ綉缁?, title: "閿欒");
      return;
    }

    await ProfileService().applyProfile(profile);
    await ProfileService().setActiveIndex(index);
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
      appBar: AppBar(title: const Text("鍒囨崲鐢ㄦ埛")),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addProfile,
        icon: const Icon(Icons.add),
        label: const Text("鏂板閰嶇疆"),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _profiles.isEmpty
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.people_outline, size: 64, color: Colors.grey[600]),
                  const SizedBox(height: 12),
                  Text("鏆傛棤淇濆瓨鐨勯厤缃?, style: TextStyle(fontSize: 16, color: hintColor(context))),
                  const SizedBox(height: 4),
                  Text("鐐瑰嚮鍙充笅瑙掓寜閽柊澧?, style: AppText.bodySmall.copyWith( color: Colors.grey[600])),
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
                              child: Text("褰撳墠", style: AppText.badge.copyWith( color: Theme.of(context).colorScheme.primary)),
                            ),
                          ],
                        ]),
                        subtitle: Text("${p.username}@${p.host}:${p.port}",
                            style: AppText.bodySmall.copyWith( color: hintColor(context))),
                        trailing: PopupMenuButton<String>(
                          onSelected: (action) {
                            if (action == "switch") _switchTo(p, i);
                            if (action == "edit") _editProfile(p);
                            if (action == "delete") _deleteProfile(i);
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: "switch", child: Text("鍒囨崲鍒版")),
                            PopupMenuItem(value: "edit", child: Text("缂栬緫")),
                            PopupMenuItem(value: "delete",
                                child: Text("鍒犻櫎", style: TextStyle(color: Colors.red))),
                          ],
                        ),
                        onTap: () => _switchTo(p, i),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                    );
                  },
                ),
    );
  }
}
