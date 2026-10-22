/// Server backup screen — export, download, import and delete backups.

import "dart:async";
import "dart:convert";
import "dart:io";

import "package:file_picker/file_picker.dart";
import "package:flutter/material.dart";
import "package:path_provider/path_provider.dart";
import "package:provider/provider.dart";
import "package:shared_preferences/shared_preferences.dart";
import "../services/logged_http.dart" as http;

import "../providers/game_provider.dart";
import "../services/api_client.dart";
import "../services/nextmoe_token_store.dart";
import "../utils/theme_utils.dart";
import "../widgets/app_shell.dart";
import "connect_screen.dart";

class BackupScreen extends StatefulWidget {
  final ApiClient api;
  const BackupScreen({super.key, required this.api});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  List<Map<String, dynamic>> _backups = [];
  bool _loading = true;
  bool _busy = false;
  bool _uploading = false;
  double _uploadProgress = 0;
  String? _downloadingName;
  double _downloadProgress = 0;
  int _downloadReceived = 0;
  int _downloadTotal = 0;
  String? _error;
  http.Client? _activeClient;
  bool _cancelled = false;
  String _currentRole = "user";

  bool _autoExpanded = false;
  bool _autoLoaded = false;
  bool _autoLoading = false;
  bool _autoSaving = false;
  bool _autoDirty = false;
  String? _autoError;
  bool _autoEnabled = false;
  String _autoMode = "day";
  String _autoScope = "all";
  bool _autoMedia = true;
  bool _autoSkipUnchanged = true;
  bool _windowEnabled = false;
  String _windowStart = "02:00";
  String _windowEnd = "06:00";
  final Set<int> _autoWeekdays = {0};
  List<String> _autoTimes = ["03:00"];
  String _autoNextRun = "";
  String _autoLastRun = "";
  String _autoLastResult = "";
  String _autoLastError = "";
  int _autoCount = 0;
  int _autoBytes = 0;
  final _intervalCtrl = TextEditingController();
  final _minFreeCtrl = TextEditingController();
  final _keepLastCtrl = TextEditingController();
  final _keepDailyCtrl = TextEditingController();
  final _keepWeeklyCtrl = TextEditingController();
  final _keepMonthlyCtrl = TextEditingController();
  final _monthDaysCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadAutoPref();
    _loadRole();
    _load();
  }

  @override
  void dispose() {
    _intervalCtrl.dispose();
    _minFreeCtrl.dispose();
    _keepLastCtrl.dispose();
    _keepDailyCtrl.dispose();
    _keepWeeklyCtrl.dispose();
    _keepMonthlyCtrl.dispose();
    _monthDaysCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAutoPref() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _autoExpanded = prefs.getBool("backup_auto_expanded") ?? false);
  }

  Future<void> _toggleAuto() async {
    await _setAutoExpanded(!_autoExpanded);
    if (_autoExpanded && !_autoLoaded && _isOwner) _loadAutoSettings();
  }

  Future<void> _setAutoExpanded(bool value) async {
    if (_autoExpanded == value) return;
    setState(() => _autoExpanded = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool("backup_auto_expanded", value);
  }

  Future<void> _loadRole() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _currentRole = prefs.getString("role") ?? "user");
    if (_isOwner) _loadAutoSettings();
  }

  bool get _isOwner => _currentRole == "owner";

  void _showPermissionDenied(String action) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("权限不足"),
        content: Text("$action仅限服主使用"),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text("确定"),
          ),
        ],
      ),
    );
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? Colors.red[700] : null,
    ));
  }

  // ── automatic backup ──

  Future<void> _loadAutoSettings() async {
    if (!_isOwner) return;
    setState(() {
      _autoLoading = true;
      _autoError = null;
    });
    try {
      final resp = await http.get(
        Uri.parse("${widget.api.baseUrl}/api/settings/backup"),
        headers: widget.api.headers,
      );
      if (!mounted) return;
      if (resp.statusCode != 200) {
        setState(() {
          _autoLoading = false;
          _autoError = "读取自动备份设置失败（HTTP ${resp.statusCode}）";
        });
        return;
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      _applyAutoPayload(data);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _autoLoading = false;
        _autoError = "读取自动备份设置失败: $e";
      });
    }
  }

  void _applyAutoPayload(Map<String, dynamic> data) {
    final settings = Map<String, dynamic>.from(data["settings"] as Map? ?? {});
    final retention = Map<String, dynamic>.from(settings["retention"] as Map? ?? {});
    final window = settings["window"];
    final weekdays = ((settings["weekdays"] as List?) ?? const [0])
        .map((item) => (item as num).toInt())
        .toSet();
    final times = ((settings["times"] as List?) ?? const ["03:00"])
        .map((item) => item.toString())
        .toList();
    final minFree = (settings["min_free_gb"] as num?)?.toDouble() ?? 0;
    setState(() {
      _autoLoaded = true;
      _autoLoading = false;
      _autoError = null;
      _autoEnabled = settings["enabled"] == true;
      _autoMode = (settings["mode"] ?? "day").toString();
      _autoScope = (settings["scope"] ?? "all").toString();
      _autoMedia = settings["include_media"] != false;
      _autoSkipUnchanged = settings["skip_if_unchanged"] != false;
      _autoTimes = times.isEmpty ? ["03:00"] : times;
      _autoWeekdays
        ..clear()
        ..addAll(weekdays.isEmpty ? {0} : weekdays);
      _monthDaysCtrl.text =
          ((settings["monthdays"] as List?) ?? const [1]).join(", ");
      _intervalCtrl.text = (settings["interval_hours"] ?? 24).toString();
      _keepLastCtrl.text = (retention["last"] ?? 7).toString();
      _keepDailyCtrl.text = (retention["daily"] ?? 14).toString();
      _keepWeeklyCtrl.text = (retention["weekly"] ?? 8).toString();
      _keepMonthlyCtrl.text = (retention["monthly"] ?? 12).toString();
      _minFreeCtrl.text = minFree == 0 ? "0" : minFree.toString();
      _windowEnabled = window is Map;
      _windowStart = window is Map ? (window["start"] ?? "02:00").toString() : "02:00";
      _windowEnd = window is Map ? (window["end"] ?? "06:00").toString() : "06:00";
      _autoNextRun = data["next_run"]?.toString() ?? "";
      _autoLastRun = data["last_run"]?.toString() ?? "";
      _autoLastResult = (settings["last_result"] ?? "").toString();
      _autoLastError = (settings["last_error"] ?? "").toString();
      _autoCount = (data["auto_count"] as num?)?.toInt() ?? 0;
      _autoBytes = (data["auto_bytes"] as num?)?.toInt() ?? 0;
      _autoDirty = false;
    });
  }

  void _applyAutoStatus(Map<String, dynamic> data) {
    final settings = Map<String, dynamic>.from(data["settings"] as Map? ?? {});
    setState(() {
      _autoNextRun = data["next_run"]?.toString() ?? "";
      _autoLastRun = data["last_run"]?.toString() ?? "";
      _autoLastResult = (settings["last_result"] ?? "").toString();
      _autoLastError = (settings["last_error"] ?? "").toString();
      _autoCount = (data["auto_count"] as num?)?.toInt() ?? _autoCount;
      _autoBytes = (data["auto_bytes"] as num?)?.toInt() ?? _autoBytes;
    });
  }

  Future<void> _saveAutoEnabled(bool value) async {
    setState(() {
      _autoEnabled = value;
      _autoSaving = true;
    });
    try {
      final resp = await http.put(
        Uri.parse("${widget.api.baseUrl}/api/settings/backup"),
        headers: _jsonHeaders(),
        body: jsonEncode({"enabled": value}),
      );
      if (!mounted) return;
      if (resp.statusCode != 200) {
        setState(() => _autoEnabled = !value);
        _toast("保存失败（HTTP ${resp.statusCode}）", error: true);
        return;
      }
      _applyAutoStatus(jsonDecode(resp.body) as Map<String, dynamic>);
      // Enabling opens the form, disabling folds it back to the summary.
      await _setAutoExpanded(value);
    } catch (e) {
      if (!mounted) return;
      setState(() => _autoEnabled = !value);
      _toast("保存失败: $e", error: true);
    } finally {
      if (mounted) setState(() => _autoSaving = false);
    }
  }

  Future<void> _saveAuto() async {
    if (_autoSaving) return;
    setState(() {
      _autoSaving = true;
      _autoError = null;
    });
    final payload = <String, dynamic>{
      "enabled": _autoEnabled,
      "mode": _autoMode,
      "interval_hours": int.tryParse(_intervalCtrl.text.trim()) ?? 24,
      "times": _autoTimes,
      "weekdays": _autoWeekdays.toList()..sort(),
      "monthdays": _parseMonthDays(),
      "window": _windowEnabled
          ? {"start": _windowStart, "end": _windowEnd}
          : null,
      "scope": _autoScope,
      "include_media": _autoMedia,
      "retention": {
        "last": int.tryParse(_keepLastCtrl.text.trim()) ?? 7,
        "daily": int.tryParse(_keepDailyCtrl.text.trim()) ?? 14,
        "weekly": int.tryParse(_keepWeeklyCtrl.text.trim()) ?? 8,
        "monthly": int.tryParse(_keepMonthlyCtrl.text.trim()) ?? 12,
      },
      "skip_if_unchanged": _autoSkipUnchanged,
      "min_free_gb": double.tryParse(_minFreeCtrl.text.trim()) ?? 0,
    };
    try {
      final resp = await http.put(
        Uri.parse("${widget.api.baseUrl}/api/settings/backup"),
        headers: _jsonHeaders(),
        body: jsonEncode(payload),
      );
      if (!mounted) return;
      if (resp.statusCode != 200) {
        setState(() => _autoError = "保存失败（HTTP ${resp.statusCode}）");
        return;
      }
      _applyAutoPayload(jsonDecode(resp.body) as Map<String, dynamic>);
      _toast("自动备份设置已保存");
    } catch (e) {
      if (!mounted) return;
      setState(() => _autoError = "保存失败: $e");
    } finally {
      if (mounted) setState(() => _autoSaving = false);
    }
  }

  List<int> _parseMonthDays() {
    final days = <int>{};
    for (final part in _monthDaysCtrl.text.split(RegExp(r"[,，\s]+"))) {
      final value = int.tryParse(part.trim());
      if (value != null && value >= 1 && value <= 31) days.add(value);
    }
    final sorted = days.toList()..sort();
    return sorted.isEmpty ? [1] : sorted;
  }

  Future<String?> _pickAutoTime(String initial) async {
    final parts = initial.split(":");
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: int.tryParse(parts.first) ?? 3,
        minute: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
      ),
    );
    if (picked == null) return null;
    return "${picked.hour.toString().padLeft(2, "0")}:"
        "${picked.minute.toString().padLeft(2, "0")}";
  }

  void _markAutoDirty() {
    if (!_autoDirty) setState(() => _autoDirty = true);
  }

  String _autoFreqLabel() {
    switch (_autoMode) {
      case "hour":
        return "每 ${_intervalCtrl.text.trim().isEmpty ? "24" : _intervalCtrl.text.trim()} 小时";
      case "week":
        const names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"];
        final days = _autoWeekdays.toList()..sort();
        return "${days.map((d) => names[d]).join("、")} ${_autoTimes.join("、")}";
      case "month":
        return "每月 ${_monthDaysCtrl.text.trim().isEmpty ? "1" : _monthDaysCtrl.text.trim()} 号 ${_autoTimes.join("、")}";
      default:
        return "每天 ${_autoTimes.join("、")}";
    }
  }

  String _autoSummary() {
    if (!_autoLoaded) {
      return _autoLoading ? "正在读取…" : "展开后可设置定时备份";
    }
    final parts = <String>[
      _autoFreqLabel(),
      "保留 ${_keepLastCtrl.text}/${_keepDailyCtrl.text}/"
          "${_keepWeeklyCtrl.text}/${_keepMonthlyCtrl.text}",
      _autoMedia ? "含图片" : "仅数据",
    ];
    if (_autoNextRun.isNotEmpty && _autoEnabled) {
      parts.add("下次 ${_timeText(_autoNextRun)}");
    }
    return parts.join(" · ");
  }

  Widget _autoTimeChips() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final time in _autoTimes)
          InputChip(
            label: Text(time, style: AppText.label),
            onPressed: () async {
              final picked = await _pickAutoTime(time);
              if (picked == null || !mounted) return;
              setState(() {
                final next = <String>{
                  ..._autoTimes.where((item) => item != time),
                  picked,
                }.toList()
                  ..sort();
                _autoTimes = next;
                _autoDirty = true;
              });
            },
            onDeleted: _autoTimes.length > 1
                ? () => setState(() {
                      _autoTimes.remove(time);
                      _autoDirty = true;
                    })
                : null,
            deleteIcon: const Icon(Icons.close_rounded, size: 14),
          ),
        ActionChip(
          avatar: const Icon(Icons.add_rounded, size: 16),
          label: const Text("添加时间"),
          onPressed: () async {
            final picked = await _pickAutoTime("03:00");
            if (picked == null || !mounted) return;
            setState(() {
              if (!_autoTimes.contains(picked)) {
                _autoTimes = [..._autoTimes, picked]..sort();
              }
              _autoDirty = true;
            });
          },
        ),
      ],
    );
  }

  Widget _autoWeekdayChips() {
    const labels = ["一", "二", "三", "四", "五", "六", "日"];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var index = 0; index < 7; index++)
          FilterChip(
            label: Text(labels[index]),
            selected: _autoWeekdays.contains(index),
            onSelected: (selected) => setState(() {
              if (selected) {
                _autoWeekdays.add(index);
              } else if (_autoWeekdays.length > 1) {
                _autoWeekdays.remove(index);
              }
              _autoDirty = true;
            }),
          ),
      ],
    );
  }

  Widget _autoField({required String label, required Widget child}) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(label,
                  style: AppText.label.copyWith(color: hintColor(context))),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _autoSwitchRow({
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
    String? subtitle,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppText.bodySmall),
                if (subtitle != null)
                  Text(subtitle,
                      style: AppText.caption.copyWith(color: hintColor(context))),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _retentionCell(
      String label, TextEditingController controller, String unit) {
    return SizedBox(
      width: 112,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: AppText.caption.copyWith(
                  color: hintColor(context), fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Row(
            children: [
              SizedBox(
                width: 54,
                child: TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  style: AppText.bodySmall,
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                  ),
                  onChanged: (_) => _markAutoDirty(),
                ),
              ),
              const SizedBox(width: 4),
              Text(unit,
                  style: AppText.caption.copyWith(color: hintColor(context))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _autoFreqDetail() {
    switch (_autoMode) {
      case "hour":
        return Row(
          children: [
            SizedBox(
              width: 76,
              child: TextField(
                controller: _intervalCtrl,
                keyboardType: TextInputType.number,
                style: AppText.bodySmall,
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                ),
                onChanged: (_) => _markAutoDirty(),
              ),
            ),
            const SizedBox(width: 6),
            Text("小时一次",
                style: AppText.label.copyWith(color: hintColor(context))),
          ],
        );
      case "week":
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _autoWeekdayChips(),
            const SizedBox(height: 10),
            _autoTimeChips(),
          ],
        );
      case "month":
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 160,
              child: TextField(
                controller: _monthDaysCtrl,
                style: AppText.bodySmall,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: "每月几号",
                  hintText: "1, 15",
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                ),
                onChanged: (_) => _markAutoDirty(),
              ),
            ),
            const SizedBox(height: 10),
            _autoTimeChips(),
          ],
        );
      default:
        return _autoTimeChips();
    }
  }

  Widget _autoBody() {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 4),
        _autoField(
          label: "频率",
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final item in const [
                    ["hour", "每 N 小时"],
                    ["day", "每天"],
                    ["week", "每周"],
                    ["month", "每月"],
                  ])
                    ChoiceChip(
                      label: Text(item[1]),
                      selected: _autoMode == item[0],
                      onSelected: (_) => setState(() {
                        _autoMode = item[0];
                        _autoDirty = true;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              _autoFreqDetail(),
            ],
          ),
        ),
        _autoField(
          label: "执行窗口",
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _autoSwitchRow(
                title: "只在指定时段执行",
                subtitle: "算出的时间不在窗口内时顺延到窗口开始",
                value: _windowEnabled,
                onChanged: (value) => setState(() {
                  _windowEnabled = value;
                  _autoDirty = true;
                }),
              ),
              if (_windowEnabled)
                Row(
                  children: [
                    OutlinedButton(
                      onPressed: () async {
                        final picked = await _pickAutoTime(_windowStart);
                        if (picked == null || !mounted) return;
                        setState(() {
                          _windowStart = picked;
                          _autoDirty = true;
                        });
                      },
                      child: Text(_windowStart),
                    ),
                    Text(" – ",
                        style: AppText.label.copyWith(color: hintColor(context))),
                    OutlinedButton(
                      onPressed: () async {
                        final picked = await _pickAutoTime(_windowEnd);
                        if (picked == null || !mounted) return;
                        setState(() {
                          _windowEnd = picked;
                          _autoDirty = true;
                        });
                      },
                      child: Text(_windowEnd),
                    ),
                  ],
                ),
            ],
          ),
        ),
        _autoField(
          label: "保留",
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _retentionCell("最近", _keepLastCtrl, "份"),
                  _retentionCell("每天", _keepDailyCtrl, "天"),
                  _retentionCell("每周", _keepWeeklyCtrl, "周"),
                  _retentionCell("每月", _keepMonthlyCtrl, "月"),
                ],
              ),
              const SizedBox(height: 6),
              Text("同一时间段只留最新一份，0 表示不启用该档；只清理自动备份",
                  style: AppText.caption.copyWith(color: hintColor(context))),
            ],
          ),
        ),
        _autoField(
          label: "条件",
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _autoSwitchRow(
                title: "数据没有变化时跳过",
                subtitle: "游戏、账号、补丁索引都没变就不生成新包",
                value: _autoSkipUnchanged,
                onChanged: (value) => setState(() {
                  _autoSkipUnchanged = value;
                  _autoDirty = true;
                }),
              ),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("磁盘余量不足时跳过", style: AppText.bodySmall),
                        Text("小于该值时本轮不执行并提示",
                            style: AppText.caption
                                .copyWith(color: hintColor(context))),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 64,
                    child: TextField(
                      controller: _minFreeCtrl,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      style: AppText.bodySmall,
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                      ),
                      onChanged: (_) => _markAutoDirty(),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text("GB",
                      style: AppText.caption.copyWith(color: hintColor(context))),
                ],
              ),
            ],
          ),
        ),
        if (_autoError != null) ...[
          const SizedBox(height: 10),
          Text(_autoError!, style: AppText.caption.copyWith(color: cs.error)),
        ],
        const SizedBox(height: 14),
        Container(height: 1, color: cardBorder(context).withValues(alpha: 0.7)),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _autoNextRun.isEmpty
                        ? "下次运行：未安排"
                        : "下次运行：${_timeText(_autoNextRun)}（服务器本地时间）",
                    style: AppText.caption.copyWith(color: hintColor(context)),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _autoStatusLine(),
                    style: AppText.caption.copyWith(
                      color: _autoLastResult == "error"
                          ? cs.error
                          : hintColor(context),
                    ),
                  ),
                  if (_autoDirty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text("有未保存的修改",
                          style: AppText.caption
                              .copyWith(color: Theme.of(context).colorScheme.primary)),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _autoSaving ? null : _saveAuto,
              child: _autoSaving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text("保存"),
            ),
          ],
        ),
      ],
    );
  }

  String _autoStatusLine() {
    if (_autoLastResult == "error" && _autoLastError.isNotEmpty) {
      return "上次失败：$_autoLastError";
    }
    final parts = <String>[];
    if (_autoLastRun.isNotEmpty) {
      final label = switch (_autoLastResult) {
        "ok" => "上次成功",
        "unchanged" => "上次跳过（无变化）",
        "busy" => "上次跳过（任务进行中）",
        _ => "上次运行",
      };
      parts.add("$label ${_timeText(_autoLastRun)}");
    } else {
      parts.add("还没有运行过");
    }
    parts.add("自动备份 $_autoCount 份");
    if (_autoBytes > 0) parts.add("占用 ${_sizeText(_autoBytes)}");
    return parts.join(" · ");
  }

  Widget _autoBackupCard() {
    final cs = Theme.of(context).colorScheme;
    return AppSurface(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: _toggleAuto,
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: cs.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(11),
                          ),
                          child: Icon(Icons.schedule_rounded,
                              size: 18, color: cs.primary),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text("自动备份",
                                  style: AppText.subtitle
                                      .copyWith(fontWeight: FontWeight.w700)),
                              Text("按日历定时打包到 backups/sena-backup",
                                  style: AppText.caption
                                      .copyWith(color: hintColor(context))),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Switch(
                value: _autoEnabled,
                onChanged: _autoSaving ? null : _saveAutoEnabled,
              ),
              InkWell(
                onTap: _toggleAuto,
                borderRadius: BorderRadius.circular(20),
                child: AnimatedRotation(
                  turns: _autoExpanded ? 0 : -0.25,
                  duration: const Duration(milliseconds: 200),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child:
                        Icon(Icons.expand_more_rounded, color: hintColor(context)),
                  ),
                ),
              ),
            ],
          ),
          if (!_autoExpanded)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 44),
              child: Text(
                _autoSummary(),
                style: AppText.caption.copyWith(color: hintColor(context)),
              ),
            ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            alignment: Alignment.topCenter,
            child: _autoExpanded
                ? (_autoLoading
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : _autoBody())
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  /// Transfer budget: at least a minute, plus room for a slow 256 KB/s link.
  Duration _transferTimeout(int bytes) {
    final seconds = 60 + (bytes / (256 * 1024)).ceil();
    return Duration(seconds: seconds.clamp(60, 3600));
  }

  void _cancelTransfer() {
    _cancelled = true;
    _activeClient?.close();
  }

  String _sizeText(int bytes) {
    if (bytes <= 0) return "0 B";
    const units = ["B", "KB", "MB", "GB", "TB"];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return unit == 0
        ? "${value.toStringAsFixed(0)} ${units[unit]}"
        : "${value.toStringAsFixed(1)} ${units[unit]}";
  }

  String _timeText(String? iso) {
    if (iso == null || iso.isEmpty) return "";
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso;
    final local = parsed.toLocal();
    String two(int v) => v.toString().padLeft(2, "0");
    return "${local.year}-${two(local.month)}-${two(local.day)} "
        "${two(local.hour)}:${two(local.minute)}";
  }

  Map<String, String> _jsonHeaders() => {
        ...widget.api.headers,
        "Content-Type": "application/json",
      };

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final resp = await http.get(
        Uri.parse("${widget.api.baseUrl}/api/backup/list"),
        headers: widget.api.headers,
      );
      if (resp.statusCode != 200) {
        setState(() {
          _loading = false;
          _error = "读取备份列表失败（HTTP ${resp.statusCode}）";
        });
        return;
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final raw = (data["backups"] as List?) ?? const [];
      setState(() {
        _backups = raw
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = "$e";
      });
    }
  }

  Future<void> _export() async {
    final options = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => const _ExportOptionsDialog(),
    );
    if (options == null) return;

    setState(() => _busy = true);
    try {
      final resp = await http.post(
        Uri.parse("${widget.api.baseUrl}/api/backup/export"),
        headers: _jsonHeaders(),
        body: jsonEncode({
          "scope": options["scope"] ?? "all",
          "include_media": options["include_media"] ?? true,
        }),
      );
      if (resp.statusCode != 200) {
        _toast("导出失败（HTTP ${resp.statusCode}）", error: true);
        return;
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final name = data["name"]?.toString() ?? "";
      _toast(name.isEmpty ? "备份已导出" : "已生成备份：$name");
      await _load();
    } catch (e) {
      _toast("导出失败: $e", error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download(Map<String, dynamic> entry) async {
    final name = entry["name"]?.toString() ?? "";
    if (name.isEmpty) return;
    final fileName = name.split("/").last;
    final totalBytes = (entry["size"] as num?)?.toInt() ?? 0;
    final isMobile = Platform.isAndroid || Platform.isIOS;

    String? target;
    if (!isMobile) {
      target = await FilePicker.platform.saveFile(
        dialogTitle: "保存备份",
        fileName: fileName,
      );
      if (target == null || target.isEmpty) return;
    }

    setState(() {
      _busy = true;
      _cancelled = false;
      _downloadingName = name;
      _downloadProgress = 0;
      _downloadReceived = 0;
      _downloadTotal = totalBytes;
    });
    File? created;
    final client = http.Client();
    _activeClient = client;
    try {
      if (isMobile) {
        final dir = Directory(
            "${(await getApplicationSupportDirectory()).path}/backups");
        await dir.create(recursive: true);
        target = "${dir.path}/$fileName";
      }
      final destination = File(target!);
      // Write beside the target and only replace it once the transfer is complete.
      final partial = File("${destination.path}.part");
      created = partial;
      if (await partial.exists()) await partial.delete();
      final request = http.Request(
        "GET",
        Uri.parse("${widget.api.baseUrl}/api/backup/download"
            "?name=${Uri.encodeQueryComponent(name)}"),
      );
      request.headers.addAll(widget.api.headers);
      final response =
          await client.send(request).timeout(_transferTimeout(totalBytes));
      if (response.statusCode != 200) {
        _toast("下载失败（HTTP ${response.statusCode}）", error: true);
        return;
      }
      final total = totalBytes > 0 ? totalBytes : (response.contentLength ?? 0);
      final sink = partial.openWrite();
      try {
        await _pipeDownload(response.stream, sink, total)
            .timeout(_transferTimeout(total));
      } finally {
        await sink.close();
      }
      if (await destination.exists()) await destination.delete();
      await partial.rename(destination.path);
      created = null;
      _toast(isMobile ? "已保存到 ${destination.path}" : "备份已保存");
    } catch (e) {
      final pending = created;
      if (pending != null && await pending.exists()) {
        try {
          await pending.delete();
        } catch (_) {}
      }
      _toast(_cancelled ? "已取消" : "下载失败: $e", error: !_cancelled);
    } finally {
      client.close();
      _activeClient = null;
      if (mounted) {
        setState(() {
          _busy = false;
          _cancelled = false;
          _downloadingName = null;
          _downloadProgress = 0;
          _downloadReceived = 0;
          _downloadTotal = 0;
        });
      }
    }
  }

  Future<void> _pipeDownload(
    Stream<List<int>> stream,
    IOSink sink,
    int total,
  ) async {
    var received = 0;
    var reported = 0.0;
    var reportedBytes = 0;
    var flushed = 0;
    await for (final chunk in stream) {
      sink.add(chunk);
      received += chunk.length;
      // Keep the write queue bounded on fast links.
      if (received - flushed >= 8 * 1024 * 1024) {
        flushed = received;
        await sink.flush();
      }
      if (total <= 0) {
        if (received - reportedBytes < 1024 * 1024) continue;
        reportedBytes = received;
      } else {
        final progress = received / total;
        if (progress - reported < 0.02 && progress < 1) continue;
        reported = progress;
      }
      if (mounted) {
        setState(() {
          _downloadReceived = received;
          _downloadTotal = total;
          _downloadProgress =
              total > 0 ? (received / total).clamp(0.0, 1.0) : 0;
        });
      }
    }
  }

  Future<void> _delete(Map<String, dynamic> entry) async {
    final name = entry["name"]?.toString() ?? "";
    if (name.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("删除备份？"),
        content: Text(name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text("删除"),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      final resp = await http.delete(
        Uri.parse("${widget.api.baseUrl}/api/backup"
            "?name=${Uri.encodeQueryComponent(name)}"),
        headers: widget.api.headers,
      );
      if (resp.statusCode != 200) {
        _toast("删除失败（HTTP ${resp.statusCode}）", error: true);
        return;
      }
      _toast("备份已删除");
      await _load();
    } catch (e) {
      _toast("删除失败: $e", error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Stream<List<int>> _uploadStream(File file, int total) async* {
    var sent = 0;
    var reported = 0.0;
    await for (final chunk in file.openRead()) {
      sent += chunk.length;
      final progress = total > 0 ? sent / total : 0.0;
      if (progress - reported >= 0.02 || progress >= 1) {
        reported = progress;
        if (mounted) {
          setState(() => _uploadProgress = progress.clamp(0.0, 1.0));
        }
      }
      yield chunk;
    }
  }

  Future<void> _import() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ["zip", "json"],
    );
    final filePath = picked?.files.single.path;
    if (filePath == null) return;
    final fileName = picked!.files.single.name;

    if (!mounted) return;
    final options = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => const _ImportOptionsDialog(),
    );
    if (options == null) return;

    setState(() {
      _uploading = true;
      _uploadProgress = 0;
      _error = null;
      _cancelled = false;
    });
    final client = http.Client();
    _activeClient = client;
    try {
      final localFile = File(filePath);
      final total = await localFile.length();
      final request = http.MultipartRequest(
          "POST", Uri.parse("${widget.api.baseUrl}/api/backup/import"));
      request.headers.addAll(widget.api.headers);
      request.fields["scope"] = options["scope"] ?? "all";
      request.fields["mode"] = options["mode"] ?? "merge";
      request.fields["media_policy"] = options["media_policy"] ?? "skip";
      request.files.add(
        http.MultipartFile("file", _uploadStream(localFile, total), total,
            filename: fileName),
      );
      final response =
          await client.send(request).timeout(_transferTimeout(total));
      final body = await response.stream
          .bytesToString()
          .timeout(_transferTimeout(total));
      if (response.statusCode != 200) {
        String detail = "导入失败";
        try {
          detail = (jsonDecode(body) as Map)["detail"]?.toString() ?? detail;
        } catch (_) {}
        _toast(detail, error: true);
        return;
      }
      final data = jsonDecode(body) as Map<String, dynamic>;
      final lines = ((data["detail"] as List?) ?? const [])
          .map((line) => line.toString())
          .toList();
      final relogin = data["relogin_required"] == true;
      await _load();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(data["message"]?.toString() ?? "备份已导入"),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final line in lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(line, style: AppText.caption),
                  ),
                if (relogin)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      "账号数据已恢复，当前登录态失效，需要重新登录。",
                      style: AppText.caption.copyWith(
                        color: Theme.of(dialogContext).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text("知道了"),
            ),
          ],
        ),
      );
      if (!mounted) return;
      try {
        await context.read<GameProvider>().refreshGames();
      } catch (_) {
        // A replaced account set invalidates the token; the relogin prompt handles it.
      }
      if (!mounted || !relogin) return;
      final reloginNow = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text("重新登录"),
          content: const Text("服务器账号已按备份恢复，是否现在重新登录？"),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text("稍后"),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text("去登录"),
            ),
          ],
        ),
      );
      if (reloginNow != true || !mounted) return;
      await NextmoeTokenStore.clear(widget.api);
      await widget.api.logout();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove("active_profile_index");
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const ConnectScreen()),
        (_) => false,
      );
    } catch (e) {
      _toast(_cancelled ? "已取消" : "导入失败: $e", error: !_cancelled);
    } finally {
      client.close();
      _activeClient = null;
      if (mounted) {
        setState(() {
          _uploading = false;
          _uploadProgress = 0;
          _cancelled = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: "备份与恢复",
      subtitle: "导出、下载与恢复服务端数据",
      leading: const Icon(Icons.backup_rounded, size: 24),
      scrollable: false,
      padding: EdgeInsets.zero,
      child: _loading && _backups.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                AppSurface(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("导出备份",
                          style: AppText.subtitle
                              .copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Text(
                        "点「导出备份」先选范围：仅游戏库（含账号）、仅补丁规则，或两个都；"
                        "选游戏库时可以带上封面/背景/头像。"
                        "备份里有密码哈希与解压密码，请妥善保管。",
                        style: AppText.caption
                            .copyWith(color: hintColor(context), height: 1.35),
                      ),
                      const SizedBox(height: AppGap.sm),
                      Wrap(
                        spacing: AppGap.sm,
                        runSpacing: AppGap.sm,
                        children: [
                          AppActionButton(
                            icon: Icons.archive_outlined,
                            label: "导出备份",
                            filled: true,
                            busy: _busy,
                            onPressed: _busy
                                ? null
                                : () {
                                    if (!_isOwner) {
                                      _showPermissionDenied("导出备份");
                                      return;
                                    }
                                    _export();
                                  },
                          ),
                          AppActionButton(
                            icon: Icons.upload_file_rounded,
                            label: "导入备份",
                            busy: _uploading,
                            onPressed: _uploading
                                ? null
                                : () {
                                    if (!_isOwner) {
                                      _showPermissionDenied("恢复备份");
                                      return;
                                    }
                                    _import();
                                  },
                          ),
                          if (_uploading || _busy)
                            AppActionButton(
                              icon: Icons.close_rounded,
                              label: "取消",
                              color: hintColor(context),
                              onPressed: _cancelTransfer,
                            ),
                        ],
                      ),
                      if (_uploading) ...[
                        const SizedBox(height: AppGap.sm),
                        LinearProgressIndicator(
                          value: _uploadProgress > 0 ? _uploadProgress : null,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          "正在上传并导入… "
                          "${(_uploadProgress * 100).clamp(0, 100).toStringAsFixed(0)}%",
                          style: AppText.caption
                              .copyWith(color: hintColor(context)),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_isOwner) ...[
                  _autoBackupCard(),
                  const SizedBox(height: 20),
                ],
                Text("服务端上的备份",
                    style:
                        AppText.subtitle.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(_error!,
                        style: AppText.caption.copyWith(color: Colors.red[300])),
                  ),
                if (_backups.isEmpty)
                  AppSurface(
                    padding: const EdgeInsets.all(16),
                    child: Text("还没有备份文件，点上面的「导出备份」生成一份。",
                        style: AppText.caption
                            .copyWith(color: hintColor(context))),
                  )
                else
                  for (final entry in _backups) ...[
                    _backupRow(entry),
                    const SizedBox(height: AppGap.sm),
                  ],
              ],
            ),
    );
  }

  Widget _sourceBadge(String source) {
    final cs = Theme.of(context).colorScheme;
    final isAuto = source == "auto";
    final color = isAuto ? cs.primary : hintColor(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(isAuto ? "自动" : "上传",
          style: AppText.badge
              .copyWith(color: color, fontWeight: FontWeight.w700)),
    );
  }

  Widget _backupRow(Map<String, dynamic> entry) {
    final name = entry["name"]?.toString() ?? "";
    final shortName = name.split("/").last;
    final size = (entry["size"] as num?)?.toInt() ?? 0;
    final hasMedia = entry["has_media"] == true;
    final source = entry["source"]?.toString() ?? "manual";
    final downloading = _downloadingName == name;
    final meta = [
      _sizeText(size),
      _timeText(entry["modified_at"]?.toString()),
      if (hasMedia) "含图片" else "仅数据",
    ].where((part) => part.isNotEmpty).join(" · ");

    return AppSurface(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Icon(
            shortName.endsWith(".zip")
                ? Icons.folder_zip_outlined
                : Icons.description_outlined,
            color: hintColor(context),
          ),
          const SizedBox(width: AppGap.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(shortName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.bodySmall
                        .copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (source != "manual") ...[
                      _sourceBadge(source),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Text(
                        downloading ? _downloadMetaText() : meta,
                        style: AppText.caption.copyWith(
                          color: downloading
                              ? Theme.of(context).colorScheme.primary
                              : hintColor(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (downloading)
            _downloadProgressRing()
          else
            IconButton(
              tooltip: "下载",
              icon: const Icon(Icons.download_rounded, size: 20),
              onPressed: _busy
                  ? null
                  : () {
                      if (!_isOwner) {
                        _showPermissionDenied("下载备份");
                        return;
                      }
                      _download(entry);
                    },
            ),
          IconButton(
            tooltip: "删除",
            icon: Icon(Icons.delete_outline_rounded,
                size: 20, color: Colors.red[300]),
            onPressed: _busy ? null : () => _delete(entry),
          ),
        ],
      ),
    );
  }

  String _downloadMetaText() {
    if (_downloadTotal <= 0) {
      return "下载中 · ${_sizeText(_downloadReceived)}";
    }
    final percent = (_downloadProgress * 100).clamp(0, 100).toStringAsFixed(0);
    return "下载中 $percent% · ${_sizeText(_downloadReceived)} / "
        "${_sizeText(_downloadTotal)}";
  }

  Widget _downloadProgressRing() {
    final percent = (_downloadProgress * 100).clamp(0, 100).round();
    return SizedBox(
      width: 40,
      height: 40,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              value: _downloadTotal > 0 ? _downloadProgress : null,
              strokeWidth: 2.6,
            ),
          ),
          Text(
            _downloadTotal > 0 ? "$percent%" : "…",
            style: AppText.caption.copyWith(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: hintColor(context),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExportOptionsDialog extends StatefulWidget {
  const _ExportOptionsDialog();

  @override
  State<_ExportOptionsDialog> createState() => _ExportOptionsDialogState();
}

class _ExportOptionsDialogState extends State<_ExportOptionsDialog> {
  String _scope = "all";
  bool _includeMedia = true;

  @override
  Widget build(BuildContext context) {
    // Images only exist in the library part of a backup.
    final mediaAvailable = _scope != "patch";
    return AlertDialog(
      title: const Text("导出备份"),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RadioListTile<String>(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: "library",
              groupValue: _scope,
              onChanged: (value) => setState(() => _scope = value ?? "library"),
              title: const Text("仅游戏库"),
              subtitle: const Text("游戏、版本、标签、账号与扫描/刮削设置"),
            ),
            RadioListTile<String>(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: "patch",
              groupValue: _scope,
              onChanged: (value) => setState(() => _scope = value ?? "patch"),
              title: const Text("仅补丁"),
              subtitle: const Text("补丁匹配规则与类型关键词"),
            ),
            RadioListTile<String>(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: "all",
              groupValue: _scope,
              onChanged: (value) => setState(() => _scope = value ?? "all"),
              title: const Text("两个都备份"),
              subtitle: const Text("游戏库 + 补丁规则（含扫描/刮削设置）"),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: mediaAvailable && _includeMedia,
              onChanged: mediaAvailable
                  ? (value) => setState(() => _includeMedia = value ?? true)
                  : null,
              title: const Text("包含图片与头像"),
              subtitle: Text(mediaAvailable ? "封面、背景与头像" : "仅补丁备份不含图片"),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("取消"),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, {
            "scope": _scope,
            "include_media": mediaAvailable && _includeMedia,
          }),
          child: const Text("开始导出"),
        ),
      ],
    );
  }
}

class _ImportOptionsDialog extends StatefulWidget {
  const _ImportOptionsDialog();

  @override
  State<_ImportOptionsDialog> createState() => _ImportOptionsDialogState();
}

class _ImportOptionsDialogState extends State<_ImportOptionsDialog> {
  String _scope = "all";
  String _mode = "merge";
  String _mediaPolicy = "skip";

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("导入备份"),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _scope,
              decoration: const InputDecoration(labelText: "恢复范围"),
              items: const [
                DropdownMenuItem(value: "all", child: Text("全部（补丁 + 游戏库 + 账号 + 设置）")),
                DropdownMenuItem(value: "patch", child: Text("仅补丁规则")),
                DropdownMenuItem(value: "library", child: Text("仅游戏库、账号与设置")),
              ],
              onChanged: (value) => setState(() => _scope = value ?? "all"),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _mode,
              decoration: const InputDecoration(labelText: "已存在的条目"),
              items: const [
                DropdownMenuItem(value: "merge", child: Text("合并更新（保留现有条目）")),
                DropdownMenuItem(value: "replace", child: Text("清空重建（先删除游戏库与账号）")),
              ],
              onChanged: (value) => setState(() => _mode = value ?? "merge"),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _mediaPolicy,
              decoration: const InputDecoration(labelText: "已有图片"),
              items: const [
                DropdownMenuItem(value: "skip", child: Text("保留本机已有图片")),
                DropdownMenuItem(value: "overwrite", child: Text("换成备份里的图片")),
              ],
              onChanged: (value) =>
                  setState(() => _mediaPolicy = value ?? "skip"),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("取消"),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, {
            "scope": _scope,
            "mode": _mode,
            "media_policy": _mediaPolicy,
          }),
          child: const Text("开始导入"),
        ),
      ],
    );
  }
}
