/// Notification list + admin approval panel.

import "package:flutter/material.dart";
import "package:http/http.dart" as http;
import "dart:convert";

import "package:shared_preferences/shared_preferences.dart";

import "../services/api_client.dart";
import "../utils/theme_utils.dart";

class NotificationScreen extends StatefulWidget {
  final ApiClient api;
  final Future<void> Function()? onChanged;
  const NotificationScreen({super.key, required this.api, this.onChanged});

  @override
  State<NotificationScreen> createState() => _NotificationScreenState();
}

class _NotificationScreenState extends State<NotificationScreen> {
  List<dynamic> _notifications = [];
  List<dynamic> _pendingUsers = [];
  bool _loading = true;

  Future<Map<String, String>> get _authHeaders async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString("auth_token") ?? "";
    return {"Authorization": "Bearer $token", "Content-Type": "application/json"};
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    await Future.wait([_loadNotifications(), _loadPending()]);
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _loadNotifications() async {
    try {
      final resp = await http.get(
        Uri.parse("${widget.api.baseUrl}/api/auth/notifications"),
        headers: await _authHeaders);
      if (resp.statusCode == 200) {
        _notifications = jsonDecode(resp.body) as List<dynamic>;
      }
    } catch (_) {}
  }

  Future<void> _loadPending() async {
    try {
      final resp = await http.get(
        Uri.parse("${widget.api.baseUrl}/api/auth/pending"),
        headers: await _authHeaders);
      if (resp.statusCode == 200) {
        _pendingUsers = jsonDecode(resp.body) as List<dynamic>;
      }
    } catch (_) {}
  }

  Future<void> _approve(int userId, bool approve) async {
    try {
      final resp = await http.post(
        Uri.parse("${widget.api.baseUrl}/api/auth/approve"),
        headers: await _authHeaders,
        body: jsonEncode({"user_id": userId, "approve": approve}),
      );
      if (resp.statusCode != 200) {
        final detail = _errorDetail(resp.body);
        if (mounted) _showError(detail ?? "操作失败: ${resp.statusCode}");
        return;
      }
      await _load();
      final onChanged = widget.onChanged;
      if (onChanged != null) await onChanged();
    } catch (e) {
      if (mounted) _showError("操作失败: $e");
    }
  }

  String? _errorDetail(String body) {
    try {
      final data = jsonDecode(body);
      final detail = data is Map ? data["detail"] : null;
      return detail?.toString();
    } catch (_) {
      return null;
    }
  }

  void _showError(String message) {
    showDialog(context: context, builder: (d) => AlertDialog(
      title: const Text("错误"),
      content: Text(message),
      actions: [FilledButton(onPressed: () => Navigator.pop(d), child: const Text("确定"))],
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("通知"), actions: [
        IconButton(
          icon: const Icon(Icons.done_all),
          tooltip: "全部已读",
          onPressed: () async {
            final resp = await http.post(Uri.parse("${widget.api.baseUrl}/api/auth/notifications/read-all"),
                headers: await _authHeaders);
            if (resp.statusCode != 200) {
              if (mounted) _showError("操作失败: ${resp.statusCode}");
              return;
            }
            await _load();
            final onChanged = widget.onChanged;
            if (onChanged != null) await onChanged();
          },
        ),
      ]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ── Pending Approvals ──
                if (_pendingUsers.isNotEmpty) ...[
                  const Text("待审批用户", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  ..._pendingUsers.map((u) => Card(
                        child: ListTile(
                          title: Text(u["username"] ?? ""),
                          subtitle: Text(u["is_admin"] == true ? "申请管理员" : "普通用户"),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.check_circle, color: Colors.green),
                                onPressed: () => _approve(u["id"] as int, true),
                              ),
                              IconButton(
                                icon: const Icon(Icons.cancel, color: Colors.red),
                                onPressed: () => _approve(u["id"] as int, false),
                              ),
                            ],
                          ),
                        ),
                      )),
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 8),
                ],
                // ── Notifications ──
                const Text("通知记录", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                if (_notifications.isEmpty)
                  const Center(child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text("暂无通知", style: TextStyle(color: Colors.grey)),
                  )),
                ..._notifications.map((n) => ListTile(
                      leading: Icon(
                        n["type"] == "approval_request"
                            ? Icons.person_add
                            : n["type"] == "approved"
                                ? Icons.check_circle
                                : n["type"] == "rejected"
                                    ? Icons.cancel
                                    : Icons.notifications,
                        color: n["type"] == "approval_request"
                            ? Colors.orange
                            : n["type"] == "approved"
                                ? Colors.green
                                : Colors.grey,
                      ),
                      title: Text(n["title"] ?? ""),
                      subtitle: Text(n["body"] ?? "", maxLines: 2),
                      trailing: Text(
                        _fmtTime(n["created_at"]),
                        style: AppText.caption.copyWith( color: Colors.grey),
                      ),
                    )),
              ],
            ),
    );
  }

  String _fmtTime(dynamic ts) {
    if (ts == null) return "";
    final s = ts.toString();
    final end = s.length >= 16 ? 16 : s.length;
    return s.substring(0, end).replaceAll("T", " ");
  }
}
