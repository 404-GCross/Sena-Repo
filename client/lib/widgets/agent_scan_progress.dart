import 'dart:async';

import 'package:flutter/material.dart';

import '../screens/agent_screen.dart';
import '../services/agent_service.dart';
import '../services/api_client.dart';
import '../utils/theme_utils.dart';
import 'task_progress_actions.dart';

class AgentScanProgress extends StatefulWidget {
  final ApiClient api;
  final ValueChanged<bool>? onActivityChanged;
  final bool showCompleted;
  final String? kind;

  const AgentScanProgress({
    super.key,
    required this.api,
    this.onActivityChanged,
    this.showCompleted = true,
    this.kind,
  });

  @override
  State<AgentScanProgress> createState() => _AgentScanProgressState();
}

class _AgentScanProgressState extends State<AgentScanProgress> {
  late final service = AgentService(widget.api);
  Timer? timer;
  Map<String, dynamic>? job;
  bool loading = false;
  bool? lastActive;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
    timer = Timer.periodic(const Duration(seconds: 3), (_) => _load());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (loading || !mounted) return;
    loading = true;
    try {
      final response = await service.request('GET', '/jobs') as List;
      if (!mounted) return;
      final jobs = response
          .whereType<Map>()
          .where((row) => widget.kind == null || row['kind'] == widget.kind)
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
      final latest = jobs.isEmpty
          ? null
          : jobs.firstWhere(
              (row) => taskActive(row['status']),
              orElse: () => jobs.first,
            );
      final active = latest != null && taskActive(latest['status']);
      setState(() {
        job = latest;
        error = null;
      });
      if (active != lastActive) {
        lastActive = active;
        widget.onActivityChanged?.call(active);
      }
    } catch (_) {
      if (mounted) setState(() => error = '暂时无法读取智能体扫描进度');
    } finally {
      loading = false;
    }
  }

  Future<void> _open() async {
    final id = job?['id'];
    if (id is! int) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => AgentJobsScreen(api: widget.api, jobId: id),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (job == null) {
      if (error == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          children: [
            Expanded(child: Text(error!)),
            TextButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final active = taskActive(job!['status']);
    if (!active && !widget.showCompleted) return const SizedBox.shrink();
    final failed = job!['status'] == 'failed';
    final kind = switch (job!['kind']) {
      'patch' => '智能体补丁扫描',
      'scrape' => '智能体刮削',
      _ => '智能体游戏扫描',
    };
    final state = switch (job!['status']) {
      'pending' => '排队中',
      'running' => '进行中',
      'stopping' => '正在停止…',
      'completed' => '已完成',
      'cancelled' => '已停止',
      'interrupted' => '已中断',
      'failed' => '失败',
      _ => '状态未知',
    };
    final accent = failed
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: cardBg(context),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: TaskProgressCardBody(
            header: InkWell(
              onTap: _open,
              child: Row(
                children: [
                  Icon(
                    active
                        ? Icons.auto_awesome
                        : failed
                        ? Icons.error_outline
                        : Icons.history,
                    color: accent,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '$kind · $state',
                      style: AppText.body.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: _open, child: const Text('查看详情')),
              if (active && job!['id'] is int)
                TaskStopButton(
                  key: ValueKey(job!['id']),
                  control: TaskControl(
                    widget.api,
                    '/api/agent/jobs/${job!['id']}',
                    '/api/agent/jobs/${job!['id']}/cancel',
                    job!['id'],
                  ),
                  status: job!['status'],
                  onChanged: (next) {
                    setState(() => job = {...job!, ...next});
                    unawaited(_load());
                  },
                ),
            ],
            progress: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                Text(
                  error ?? '${job!['message'] ?? ''}',
                  style: AppText.bodySmall,
                ),
                if (active) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(minHeight: 6),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 16,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '模型请求 ${job!['calls'] ?? 0} · Token ${job!['tokens'] ?? 0}',
                      style: AppText.label,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
