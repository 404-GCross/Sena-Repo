import 'package:flutter/material.dart';

import '../utils/theme_utils.dart';
import 'app_dialog.dart';
import 'app_shell.dart';
import 'task_progress_actions.dart';

class AgentResultView extends StatelessWidget {
  const AgentResultView({
    super.key,
    required this.job,
    required this.items,
    required this.bucket,
    required this.offset,
    required this.loading,
    required this.busy,
    required this.control,
    required this.onStopped,
    required this.onPage,
    required this.refresh,
    required this.onRetry,
    required this.onIgnore,
    required this.statusLabel,
    required this.reviewStatuses,
    required this.recordDetails,
  });

  final Map<String, dynamic> job;
  final List<Map> items;
  final String bucket;
  final int offset;
  final bool loading, busy;
  final TaskControl control;
  final ValueChanged<Map<String, dynamic>> onStopped;
  final void Function(String, int) onPage;
  final Future<void> Function() refresh, onRetry;
  final Future<void> Function(List<int>) onIgnore;
  final String Function(dynamic) statusLabel;
  final Set<String> reviewStatuses;
  final Widget Function(Map) recordDetails;

  int count(String state) => (job['item_counts'] as Map)[state] as int? ?? 0;
  bool get active => taskActive(job['status']);

  Future<void> taskDetails(BuildContext context) async {
    final preparation = job['preparation_count'] as int? ?? 0;
    final showRecords = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        section: '智能体 · ${statusLabel(job['kind'])}',
        title: '任务详情',
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${taskStateLabel(job['status'])} · 模型请求 ${job['calls']} 次 · ${job['tokens']} Token',
            ),
            const SizedBox(height: 8),
            SelectableText('${job['message'] ?? ''}'),
            if (preparation > 0)
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(
                  '目录与准备记录 $preparation 条 · ${job['preparation_failed']} 条待核实',
                ),
              ),
          ],
        ),
      ),
    );
    if (showRecords == true && context.mounted) onPage('preparation', 0);
  }

  Widget progress(BuildContext context) {
    final current = job['current_item'] as Map?;
    final total = job['item_total'] as int;
    final processed = count('success') + count('failed') + count('ignored');
    final status = job['status'];
    final heading = switch (status) {
      'running' => current == null ? '正在准备扫描' : '正在扫描：${current['name']}',
      'pending' => '等待开始扫描',
      'completed' => '扫描完成',
      'cancelled' => '扫描已停止',
      'stopping' => '正在停止扫描',
      'failed' => '任务失败',
      _ => taskStateLabel(status),
    };
    final cs = Theme.of(context).colorScheme;
    final stats = [
      if (active && job['plan_known'] == true)
        '已处理 $processed / $total 项'
      else if (active && total == 0)
        '正在准备条目清单'
      else ...[
        '成功 ${count('success')} 项',
        '失败 ${count('failed')} 项',
      ],
      if (count('unfinished') > 0) '未完成 ${count('unfinished')} 项',
      if (count('ignored') > 0) '已忽略 ${count('ignored')} 项',
    ];
    return AppSurface(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '智能体 · ${statusLabel(job['kind'])}',
                  style: AppText.label,
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: (status == 'completed' ? Colors.green : cs.primary)
                      .withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 3,
                    horizontal: 9,
                  ),
                  child: Text(taskStateLabel(status), style: AppText.label),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(heading, style: AppText.title),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            borderRadius: BorderRadius.circular(6),
            value: total > 0 && (job['plan_known'] == true || !active)
                ? processed / total
                : active
                ? null
                : 0,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(stats.join(' · '), style: AppText.bodySmall),
              ),
              if (active)
                TaskStopButton(
                  control: control,
                  status: status,
                  onChanged: onStopped,
                  confirmStop: true,
                ),
              if (job['can_retry'] == true)
                TextButton(
                  onPressed: busy
                      ? null
                      : () async {
                          if (await confirmAppAction(
                                    context,
                                    section: '智能体任务',
                                    title: '重试未完成条目？',
                                    message:
                                        '重试失败或未完成的条目。若任务在生成条目清单前中断，将重新准备扫描。',
                                    action: '重试',
                                  ) ==
                                  true &&
                              context.mounted) {
                            await onRetry();
                          }
                        },
                  child: const Text('重试未完成'),
                ),
            ],
          ),
          if ((job['preparation_failed'] as int? ?? 0) > 0)
            TextButton(
              onPressed: () => onPage('preparation', 0),
              child: Text('目录检查有 ${job['preparation_failed']} 条待核实 ›'),
            ),
        ],
      ),
    );
  }

  Widget filters(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final choices = {
      'all': '全部',
      if (active) 'scanning': '扫描中',
      'success': '成功 ${count('success')}',
      'failed': '失败 ${count('failed')}',
    };
    return AppSurface(
      radius: AppRadius.md,
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          for (final entry in choices.entries)
            Expanded(
              child: Semantics(
                selected: bucket == entry.key,
                child: TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    minimumSize: const Size(0, 40),
                    backgroundColor: bucket == entry.key
                        ? cs.primary.withValues(alpha: .13)
                        : null,
                    foregroundColor: bucket == entry.key
                        ? cs.primary
                        : subTextColor(context),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: () => onPage(entry.key, 0),
                  child: Text(entry.value, textAlign: TextAlign.center),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget entry(BuildContext context, Map item) {
    final cs = Theme.of(context).colorScheme;
    final (label, icon, color) = switch (item['state']) {
      'scanning' => ('扫描中', Icons.sync, cs.primary),
      'success' => ('成功', Icons.check, Colors.green.shade700),
      'failed' => ('失败', Icons.priority_high, cs.error),
      'ignored' => ('已忽略', Icons.visibility_off_outlined, cs.outline),
      'waiting' => ('等待中', Icons.schedule, cs.outline),
      _ => ('未完成', Icons.pause, cs.outline),
    };
    final records = (item['records'] as List).cast<Map>();
    final ids = [
      for (final r in records)
        if (reviewStatuses.contains(r['status'])) r['id'] as int,
    ];
    return ExpansionTile(
      key: PageStorageKey('${job['id']}:$bucket:${item['key']}'),
      leading: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, color: color, size: 18),
        ),
      ),
      title: Text(
        '${item['name']}',
        style: AppText.section,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '$label · ${item['brief']}',
        style: AppText.bodySmall,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      expandedAlignment: Alignment.centerLeft,
      children: [
        for (final r in records) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(
              '${statusLabel(r['status'])}：${r['summary'] ?? ''}',
            ),
          ),
          recordDetails(r),
          if (((r['data'] as Map?)?['cover_checks'] as List? ?? []).isNotEmpty)
            ExpansionTile(
              title: const Text('候选封面与依据'),
              children: [
                for (final c
                    in (r['data']['cover_checks'] as List).whereType<Map>())
                  ListTile(
                    dense: true,
                    title: Text(
                      [
                        c['source'],
                        if (c['cover'] != null) '#${c['cover']}',
                        if (c['width'] != null)
                          '${c['width']} × ${c['height']}',
                      ].whereType<String>().join(' · '),
                    ),
                    subtitle: SelectableText(
                      [
                        c['rejection'],
                        c['reason'],
                        ...(c['printed_titles'] as List? ?? []),
                      ].whereType<String>().join(' · '),
                    ),
                  ),
              ],
            ),
        ],
        if (records.isEmpty)
          Text(item['state'] == 'scanning' ? '${job['message']}' : '尚无处理记录'),
        if (ids.isNotEmpty && item['state'] == 'failed')
          TextButton(
            onPressed: busy ? null : () => onIgnore(ids),
            child: const Text('忽略此项'),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final successes = items.where((r) => r['state'] == 'success').toList();
    final collapse =
        bucket == 'all' &&
        successes.isNotEmpty &&
        successes.length < items.length;
    final pageSize = job['page_size'] as int;
    return Scaffold(
      appBar: AppBar(
        title: const Text('分析结果'),
        actions: [
          TextButton(
            onPressed: () => taskDetails(context),
            child: const Text('任务详情'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            progress(context),
            const SizedBox(height: 12),
            filters(context),
            const SizedBox(height: 12),
            if (bucket == 'preparation')
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('目录与准备记录 · 不计入条目数'),
              ),
            AppSurface(
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  children: [
                    if (items.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          loading
                              ? '读取中…'
                              : bucket == 'scanning' &&
                                    job['current_item'] != null
                              ? '正在扫描目录：${job['current_item']['name']}'
                              : bucket == 'failed'
                              ? '暂无失败条目'
                              : bucket == 'success'
                              ? '暂无成功条目'
                              : '暂无条目结果',
                        ),
                      ),
                    for (final row in items)
                      if (!collapse || row['state'] != 'success')
                        entry(context, row),
                    if (collapse)
                      ExpansionTile(
                        key: PageStorageKey('success:${job['id']}:$offset'),
                        title: Text(
                          '${job['has_more'] == true || offset > 0 ? '本页' : '已'}成功 ${successes.length} 项',
                        ),
                        children: [
                          for (final row in successes) entry(context, row),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            if (bucket != 'preparation')
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '按条目计数 · 点开条目可查看依据',
                  textAlign: TextAlign.center,
                  style: AppText.caption.copyWith(color: hintColor(context)),
                ),
              ),
            if (offset > 0 || job['has_more'] == true)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    onPressed: offset > 0
                        ? () => onPage(bucket, offset - pageSize)
                        : null,
                    child: const Text('上一页'),
                  ),
                  TextButton(
                    onPressed: job['has_more'] == true
                        ? () => onPage(bucket, offset + pageSize)
                        : null,
                    child: const Text('下一页'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
