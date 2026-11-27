import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import '../services/api_client.dart';
import '../services/logged_http.dart' as http;
import 'app_dialog.dart';
import 'feedback_dialog.dart';

bool taskActive(Object? status) =>
    const {'pending', 'running', 'stopping'}.contains(status);

String taskStateLabel(Object? status) => switch (status) {
  'pending' => '排队中',
  'running' => '进行中',
  'stopping' => '正在停止…',
  'cancelled' => '已停止',
  'completed' => '已完成',
  'failed' => '失败',
  'interrupted' => '已中断',
  _ => '未知状态',
};

class TaskControl {
  TaskControl(
    this.api,
    this.statusPath,
    this.stopPath,
    this.id, {
    this.idField = 'id',
  }) : origin = api.baseUrl,
       generation = ApiClient.sessionGeneration;
  final ApiClient api;
  final String statusPath, stopPath, origin, idField;
  final int generation;
  final Object id;

  Future<Map<String, dynamic>> request({bool stop = false}) async {
    void check() {
      if (api.baseUrl != origin || ApiClient.sessionGeneration != generation)
        throw Exception('连接已变更，请重新打开任务');
    }

    check();
    final url = Uri.parse('$origin${stop ? stopPath : statusPath}');
    final response =
        await (stop
                ? http.post(url, headers: api.headers)
                : http.get(url, headers: api.headers))
            .timeout(const Duration(seconds: 20));
    check();
    if (response.statusCode == 409) throw Exception('任务已更换，请刷新进度');
    if (response.statusCode != 200)
      throw Exception('任务请求失败（HTTP ${response.statusCode}）');
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data[idField] != null && data[idField] != id)
      throw Exception('任务已更换，请返回进度页');
    return data;
  }
}

class TaskStopButton extends StatefulWidget {
  const TaskStopButton({
    super.key,
    required this.control,
    required this.status,
    required this.onChanged,
    this.confirmStop = false,
  });
  final TaskControl control;
  final Object? status;
  final ValueChanged<Map<String, dynamic>> onChanged;
  final bool confirmStop;
  @override
  State<TaskStopButton> createState() => _TaskStopButtonState();
}

class _TaskStopButtonState extends State<TaskStopButton> {
  bool sending = false;
  bool accepted = false;
  @override
  void didUpdateWidget(TaskStopButton old) {
    super.didUpdateWidget(old);
    if (old.control.id != widget.control.id ||
        old.control.origin != widget.control.origin) {
      accepted = false;
      sending = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!taskActive(widget.status)) return const SizedBox.shrink();
    final waiting = sending || accepted || widget.status == 'stopping';
    return TextButton.icon(
      icon: const Icon(Icons.stop_circle_outlined, size: 18),
      label: Text(waiting ? '正在停止…' : '停止任务'),
      onPressed: waiting
          ? null
          : () async {
              final control = widget.control;
              if (widget.confirmStop &&
                  await confirmAppAction(
                        context,
                        section: '智能体任务',
                        title: '停止扫描？',
                        message: '已完成的结果保留，尚未完成的条目不计为失败。',
                        action: '停止',
                      ) !=
                      true) {
                return;
              }
              if (!mounted ||
                  widget.control.id != control.id ||
                  !taskActive(widget.status))
                return;
              setState(() => sending = true);
              try {
                final data = await control.request(stop: true);
                if (mounted && widget.control.id == control.id) {
                  accepted = true;
                  widget.onChanged(data);
                }
              } catch (e) {
                if (context.mounted) {
                  await showFeedbackDialog(
                    context,
                    '$e',
                    title: '未能停止任务',
                    error: true,
                  );
                }
              } finally {
                if (mounted) setState(() => sending = false);
              }
            },
    );
  }
}

class TaskProgressCardBody extends StatelessWidget {
  const TaskProgressCardBody({
    super.key,
    required this.header,
    required this.progress,
    required this.actions,
  });
  final Widget header, progress;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, box) {
      final buttons = Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: actions,
      );
      final wide = box.maxWidth >= 520;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (wide)
            Row(
              children: [
                Expanded(child: header),
                buttons,
              ],
            )
          else
            header,
          progress,
          if (!wide) Align(alignment: Alignment.centerRight, child: buttons),
        ],
      );
    },
  );
}

Future<void> showTaskDetails(
  BuildContext context,
  String title,
  TaskControl control,
  Map<String, dynamic> initial,
) => showDialog<void>(
  context: context,
  builder: (_) => _TaskDetails(title, control, initial),
);

class _TaskDetails extends StatefulWidget {
  const _TaskDetails(this.title, this.control, this.initial);
  final String title;
  final TaskControl control;
  final Map<String, dynamic> initial;
  @override
  State<_TaskDetails> createState() => _TaskDetailsState();
}

class _TaskDetailsState extends State<_TaskDetails> {
  late var data = widget.initial;
  Timer? timer;
  bool fetching = false;
  String? failure;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 2), (_) => load());
  }

  Future<void> load() async {
    if (fetching || !taskActive(data['status'])) return;
    fetching = true;
    try {
      final next = await widget.control.request();
      if (mounted)
        setState(() {
          data = next;
          failure = null;
        });
    } catch (e) {
      if (mounted) setState(() => failure = '$e');
    } finally {
      fetching = false;
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    section: '任务详情',
    title: widget.title,
    actions: [
      TaskStopButton(
        control: widget.control,
        status: data['status'],
        onChanged: (next) => setState(() => data = {...data, ...next}),
      ),
      OutlinedButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(taskStateLabel(data['status'])),
        if (data['roots_total'] != null)
          Text("${data['roots_completed']} / ${data['roots_total']} 个目录"),
        if (data['total_games'] != null)
          Text("${data['processed_games']} / ${data['total_games']} 款游戏"),
        if (data['total'] != null)
          Text("${data['processed']} / ${data['total']} 个文件"),
        for (final field in [
          'message',
          'current_root',
          'stage',
          'current',
          'current_game',
          'last_error',
        ])
          if ('${data[field] ?? ''}'.isNotEmpty) Text('${data[field]}'),
        if (failure != null) Text(failure!),
      ],
    ),
  );
}
