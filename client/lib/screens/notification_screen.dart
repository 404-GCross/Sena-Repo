/// Notification list + admin approval panel.

import "package:flutter/material.dart";
import "package:http/http.dart" as http;
import "dart:convert";

import "../services/api_client.dart";
import "../services/secure_store.dart";
import "../utils/theme_utils.dart";
import "../widgets/app_shell.dart";

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
    final token = await SecureStore.getString("auth_token") ?? "";
    return {
      "Authorization": "Bearer $token",
      "Content-Type": "application/json",
    };
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
        headers: await _authHeaders,
      );
      if (resp.statusCode == 200) {
        _notifications = jsonDecode(resp.body) as List<dynamic>;
      }
    } catch (_) {}
  }

  Future<void> _loadPending() async {
    try {
      final resp = await http.get(
        Uri.parse("${widget.api.baseUrl}/api/auth/pending"),
        headers: await _authHeaders,
      );
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
    showDialog(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text("错误"),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(d),
            child: const Text("确定"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: "通知",
      subtitle: "处理用户审批和系统消息",
      leading: const Icon(Icons.notifications_outlined, size: 24),
      actions: [
        AppActionButton(
          icon: Icons.done_all_rounded,
          label: "全部已读",
          onPressed: () async {
            final resp = await http.post(
              Uri.parse(
                  "${widget.api.baseUrl}/api/auth/notifications/read-all"),
              headers: await _authHeaders,
            );
            if (resp.statusCode != 200) {
              if (mounted) _showError("操作失败: ${resp.statusCode}");
              return;
            }
            await _load();
            final onChanged = widget.onChanged;
            if (onChanged != null) await onChanged();
          },
        ),
      ],
      child: _loading
          ? const AppStateView.loading(title: "正在读取通知")
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_pendingUsers.isNotEmpty) ...[
                  const AppSectionTitle(
                    icon: Icons.how_to_reg_outlined,
                    title: "待审批用户",
                    subtitle: "确认新用户是否允许进入当前服务器",
                  ),
                  const SizedBox(height: AppGap.md),
                  AppSurface(
                    padding: const EdgeInsets.all(6),
                    child: Column(
                      children: [
                        for (final u in _pendingUsers)
                          AppListTile(
                            icon: u["is_admin"] == true
                                ? Icons.admin_panel_settings_outlined
                                : Icons.person_add_alt_1_outlined,
                            color: Colors.orange,
                            title: u["username"]?.toString() ?? "",
                            subtitle: u["is_admin"] == true ? "申请管理员" : "普通用户",
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.check_circle,
                                      color: Colors.green),
                                  tooltip: "通过",
                                  onPressed: () =>
                                      _approve(u["id"] as int, true),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.cancel,
                                      color: Colors.red),
                                  tooltip: "拒绝",
                                  onPressed: () =>
                                      _approve(u["id"] as int, false),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppGap.xl),
                ],
                const AppSectionTitle(
                  icon: Icons.inbox_outlined,
                  title: "通知记录",
                  subtitle: "最近的服务器消息和审批结果",
                ),
                const SizedBox(height: AppGap.md),
                if (_notifications.isEmpty)
                  const AppSurface(
                    padding: EdgeInsets.all(12),
                    child: AppStateView(
                      icon: Icons.notifications_none_outlined,
                      title: "暂无通知",
                      message: "当前没有新的消息记录",
                    ),
                  )
                else
                  AppSurface(
                    padding: const EdgeInsets.all(6),
                    child: Column(
                      children: [
                        for (final n in _notifications)
                          AppListTile(
                            icon: _notificationIcon(n["type"]),
                            color: _notificationColor(n["type"]),
                            title: n["title"]?.toString() ?? "",
                            subtitle: n["body"]?.toString() ?? "",
                            trailing: Text(
                              _fmtTime(n["created_at"]),
                              style: AppText.caption
                                  .copyWith(color: hintColor(context)),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  IconData _notificationIcon(dynamic type) {
    return type == "approval_request"
        ? Icons.person_add_alt_1_outlined
        : type == "approved"
            ? Icons.check_circle_outline
            : type == "rejected"
                ? Icons.cancel_outlined
                : Icons.notifications_outlined;
  }

  Color _notificationColor(dynamic type) {
    return type == "approval_request"
        ? Colors.orange
        : type == "approved"
            ? Colors.green
            : type == "rejected"
                ? Colors.red
                : Colors.grey;
  }

  String _fmtTime(dynamic ts) {
    if (ts == null) return "";
    final s = ts.toString();
    final end = s.length >= 16 ? 16 : s.length;
    return s.substring(0, end).replaceAll("T", " ");
  }
}
