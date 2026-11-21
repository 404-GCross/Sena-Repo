import 'dart:async';

import 'package:flutter/material.dart';
import '../services/api_client.dart';
import '../services/steam_service.dart';
import 'task_progress_actions.dart';

class PatchTaskProgress extends StatefulWidget {
  const PatchTaskProgress({
    super.key,
    required this.api,
    required this.admin,
    this.requestKey,
  });
  final ApiClient api;
  final bool admin;
  final String? requestKey;
  @override
  State<PatchTaskProgress> createState() => _PatchTaskProgressState();
}

class _PatchTaskProgressState extends State<PatchTaskProgress> {
  Timer? timer;
  Map<String, dynamic>? data;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(const Duration(seconds: 2), (_) => load());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    if (busy) return;
    busy = true;
    try {
      final next = await SteamService.patchScanStatus(widget.api);
      if (mounted) setState(() => data = next);
    } catch (_) {
      // Older servers may not expose scan progress.
    } finally {
      busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final job = data;
    if (job == null ||
        widget.requestKey != null && job['request_key'] != widget.requestKey ||
        job['run_id'] is! String ||
        job['status'] == 'idle') {
      return widget.requestKey != null
          ? const LinearProgressIndicator()
          : const SizedBox.shrink();
    }
    final id = job['run_id'] as String, status = job['status'];
    final control = TaskControl(
      widget.api,
      '/api/steam/scan-patches/status',
      '/api/steam/scan-patches/$id/stop',
      id,
      idField: 'run_id',
    );
    final total = (job['total'] as num?)?.toInt() ?? 0,
        done = (job['processed'] as num?)?.toInt() ?? 0;
    final label = job['operation']?.toString() ?? '补丁扫描';
    return Padding(
      padding: const EdgeInsets.all(12),
      child: TaskProgressCardBody(
        header: Text('$label · ${taskStateLabel(status)}'),
        actions: [
          if (widget.requestKey == null && widget.admin)
            TextButton(
              onPressed: () => showTaskDetails(context, label, control, job),
              child: const Text('查看详情'),
            ),
          if (widget.admin && taskActive(status))
            TaskStopButton(
              key: ValueKey(id),
              control: control,
              status: status,
              onChanged: (next) => setState(() => data = next),
            ),
        ],
        progress: taskActive(status)
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${job['stage'] ?? ''} ${total > 0 ? '$done / $total' : ''}',
                  ),
                  LinearProgressIndicator(
                    value: total > 0 ? (done / total).clamp(0.0, 1.0) : null,
                  ),
                ],
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}
