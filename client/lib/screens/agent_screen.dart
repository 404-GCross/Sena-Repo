import 'dart:async';
import 'package:flutter/material.dart';

import '../services/agent_service.dart';
import '../services/api_client.dart';
import '../utils/theme_utils.dart';

Future<void> _showAgentMessage(BuildContext context, String text,
    {String title = '提示'}) async {
  if (!context.mounted) return;
  final message = text.replaceFirst(RegExp(r'^(Exception|AuthException):\s*'), '');
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      scrollable: true,
      content: SelectableText(message),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

const agentPresets = <String, List<String>>{
  'OpenAI': ['openai', 'responses', 'https://api.openai.com/v1', ''],
  'Anthropic': ['anthropic', 'anthropic', 'https://api.anthropic.com', ''],
  'Google Gemini': [
    'gemini',
    'gemini',
    'https://generativelanguage.googleapis.com/v1beta',
    ''
  ],
  'DeepSeek': [
    'deepseek',
    'chat',
    'https://api.deepseek.com/v1',
    'deepseek-chat'
  ],
  '通义千问': [
    'qwen',
    'chat',
    'https://dashscope.aliyuncs.com/compatible-mode/v1',
    'qwen-plus'
  ],
  '智谱': ['zhipu', 'chat', 'https://open.bigmodel.cn/api/paas/v4', ''],
  'OpenRouter': ['openrouter', 'chat', 'https://openrouter.ai/api/v1', ''],
  'Ollama': ['ollama', 'ollama', 'http://127.0.0.1:11434', ''],
  'LM Studio': ['lmstudio', 'chat', 'http://127.0.0.1:1234/v1', ''],
  'vLLM': ['vllm', 'chat', 'http://127.0.0.1:8000/v1', ''],
  '自定义': ['custom', 'chat', '', ''],
};

class AgentScreen extends StatefulWidget {
  final ApiClient api;
  final bool setup;
  const AgentScreen({super.key, required this.api, this.setup = false});
  @override
  State<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends State<AgentScreen> {
  late final service = AgentService(widget.api);
  Map<String, dynamic>? value;
  final controllers = <String, TextEditingController>{};
  String? error;
  bool busy = false;
  int page = 0;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    for (final c in controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> load() async {
    try {
      final data = await service.settings();
      if (mounted) {
        setState(() {
          value = data;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> message(String text, {String title = '提示'}) async {
    if (mounted) {
      await _showAgentMessage(context, text, title: title);
    }
  }

  Future<void> save({bool finish = false}) async {
    setState(() => busy = true);
    try {
      await service.save(value!);
      if (!mounted) return;
      final updated = await service.settings();
      if (!mounted) return;
      setState(() {
        value = updated;
        controllers['api_key']?.clear();
        controllers['proxy_password']?.clear();
      });
      await message('配置已保存', title: '保存成功');
      if (finish && mounted) Navigator.pop(context);
    } catch (e) {
      await message('$e', title: '操作失败');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget field(String key, String label,
      {bool secret = false, bool number = false, int lines = 1, String? help}) {
    final controller = controllers.putIfAbsent(
        key,
        () =>
            TextEditingController(text: secret ? '' : '${value![key] ?? ''}'));
    return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: TextField(
          enabled: !busy,
          controller: controller,
          obscureText: secret,
          maxLines: lines,
          keyboardType: number ? TextInputType.number : null,
          decoration: InputDecoration(
              labelText: label,
              helperText: help,
              helperMaxLines: 3,
              border: const OutlineInputBorder()),
          onChanged: (text) {
            if (key == 'base_url' && value![key] != text) {
              value!['api_key'] = '';
              controllers['api_key']?.clear();
            }
            if ((key == 'proxy_url' || key == 'proxy_username') &&
                value![key] != text) {
              value!['proxy_password'] = '';
              controllers['proxy_password']?.clear();
            }
            value![key] = number
                ? int.tryParse(text) ?? value![key]
                : secret && text.isEmpty
                    ? null
                    : text;
          },
        ));
  }

  Widget select(String key, String label, Map<String, String> options) =>
      Padding(
          padding: const EdgeInsets.only(top: 12),
          child: DropdownButtonFormField<String>(
            key: ValueKey('$key:${value![key]}'),
            initialValue: options.containsKey(value![key])
                ? value![key] as String
                : options.keys.first,
            isExpanded: true,
            decoration: InputDecoration(
                labelText: label, border: const OutlineInputBorder()),
            items: options.entries
                .map((e) => DropdownMenuItem(
                    value: e.key,
                    child: Text(e.value, overflow: TextOverflow.ellipsis)))
                .toList(),
            onChanged: busy
                ? null
                : (v) => setState(() {
                      if (key == 'protocol' && value![key] != v) {
                        value!['api_key'] = '';
                        controllers['api_key']?.clear();
                      }
                      value![key] = v;
                    }),
          ));

  Widget toggle(String key, String title, [String? subtitle]) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
        value: value![key] == true,
        onChanged: busy ? null : (v) => setState(() => value![key] = v),
      );

  Widget card(String title, List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
            color: cardBg(context), borderRadius: BorderRadius.circular(18)),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [Text(title, style: AppText.title), ...children]),
      );

  Future<void> test({bool models = false}) async {
    setState(() => busy = true);
    try {
      await service.save(value!);
      final result = await service.request(
          models ? 'GET' : 'POST', models ? '/models' : '/test');
      if (!mounted) return;
      if (models) {
        final chosen = await showDialog<String>(
            context: context,
            builder: (ctx) => SimpleDialog(
                  title: const Text('选择模型'),
                  children: [
                    for (final model in result['models'] as List)
                      SimpleDialogOption(
                          onPressed: () => Navigator.pop(ctx, '$model'),
                          child: Text('$model'))
                  ],
                ));
        if (chosen != null && mounted) {
          setState(() {
            value!['model'] = chosen;
            controllers['model']?.text = chosen;
          });
        }
      } else {
        await message('${result['message']}', title: '连接测试成功');
      }
    } catch (e) {
      await message('$e', title: '操作失败');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  List<Widget> modelPage() => [
        card('统一模型', [
          const Text('游戏识别、分类和补丁分析共用一个模型。'),
          select('provider', '提供商预设',
              {for (final e in agentPresets.entries) e.value[0]: e.key}),
          TextButton(
              onPressed: busy
                  ? null
                  : () {
                      final p = agentPresets.values.firstWhere(
                          (p) => p[0] == value!['provider'],
                          orElse: () => agentPresets['自定义']!);
                      setState(() {
                        if (value!['base_url'] != p[2] ||
                            value!['protocol'] != p[1]) {
                          value!['api_key'] = '';
                          value!['has_api_key'] = false;
                          controllers['api_key']?.clear();
                        }
                        for (final pair in {
                          'protocol': p[1],
                          'base_url': p[2],
                          'model': p[3]
                        }.entries) {
                          value![pair.key] = pair.value;
                          controllers[pair.key]?.text = pair.value;
                        }
                      });
                    },
              child: const Text('使用预设地址与协议')),
          select('protocol', '接口协议', const {
            'chat': 'OpenAI Chat Completions',
            'responses': 'OpenAI Responses',
            'anthropic': 'Anthropic Messages',
            'gemini': 'Gemini 原生',
            'ollama': 'Ollama 原生'
          }),
          field('base_url', 'Base URL',
              help: '从 Sena 服务端连接；localhost 指服务端环境。更换地址或协议后需重新填写密钥。'),
          field('api_key', 'API Key',
              secret: true,
              help: value!['has_api_key'] == true ? '已设置；留空保留' : '可选，按服务要求填写'),
          TextButton(
              onPressed: () {
                value!['api_key'] = '';
                controllers['api_key']?.clear();
                message('保存后清除 API Key');
              },
              child: const Text('清除已保存密钥')),
          field('model', '模型 ID'),
          toggle('vision', '允许图片分析', '仅在所选模型支持图片输入时开启；候选封面会发送到模型服务。'),
          Wrap(spacing: 12, children: [
            TextButton(
                onPressed: busy || value!['enabled'] != true
                    ? null
                    : () => test(models: true),
                child: const Text('获取模型列表')),
            TextButton(
                onPressed:
                    busy || value!['enabled'] != true ? null : () => test(),
                child: const Text('保存并测试连接与工具调用'))
          ]),
        ]),
        card('智能体独立代理', [
          select('proxy_mode', '代理方式', const {
            'direct': '直连',
            'inherit': '继承服务端代理',
            'custom': '自定义 HTTP / SOCKS5 代理'
          }),
          if (value!['proxy_mode'] == 'custom') ...[
            field('proxy_url', '代理地址'),
            field('proxy_username', '用户名（可选）'),
            field('proxy_password', '密码（留空保留）', secret: true),
            TextButton(
                onPressed: () {
                  value!['proxy_password'] = '';
                  controllers['proxy_password']?.clear();
                  message('保存后清除代理密码');
                },
                child: const Text('清除代理密码'))
          ],
          const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text('仅模型请求使用此代理，普通刮削和 OpenList 保持原有网络设置。直连会忽略代理环境变量。')),
        ]),
        card('任务预算（可选）', [
          const Text('默认不限制。只有填写正数才启用对应上限；达到限制后转入常规流程，不代表游戏无法识别。'),
          field('max_calls', '每任务请求次数上限（0 为不限制）', number: true),
          field('max_tokens', '每任务 Token 上限（0 为不限制）', number: true),
        ]),
        card('请求与分析设置', [
          field('timeout', '单次请求超时（秒）', number: true),
          field('rounds', '每条目最多分析轮数', number: true),
          field('remote_archive_mb', '远程压缩包分析下载上限（MB，0 禁止）', number: true)
        ]),
      ];

  List<Widget> gamePage() => [
        card('游戏刮削偏好', [
          select('cover_language', '封面语言',
              const {'zh': '中文优先', 'original': '原版优先', 'source': '跟随来源默认'}),
          select('cover_fallback', '没有合适封面时',
              const {'original': '使用原版', 'keep': '保留现有封面', 'review': '留待确认'}),
          toggle('portrait', '优先竖版封面'),
          toggle('high_resolution', '优先高清封面'),
          select('name_language', '名称语言', const {
            'zh': '中文优先，原文回退',
            'original': '原文优先',
            'source': '跟随来源默认'
          }),
          toggle('translate_description', '允许翻译简介为中文'),
          select('update_mode', '资料更新策略',
              const {'missing': '仅补全缺失', 'overwrite': '更新未锁定资料'}),
          field('preferences', '补充偏好', lines: 3),
          const Text('智能体使用已启用的刮削源及其顺序。明确结果自动应用，未确定字段使用原有流程补齐，锁定内容不覆盖。'),
        ])
      ];

  List<Widget> patchPage() => [
        card('补丁刮削偏好', [
          toggle('patch_steam_name', '使用 Steam 名称',
              '默认开启；影响关联游戏名称，不重命名原文件。Steam 不可用时回退其他已确认来源。'),
          field('patch_preferences', '补丁补充偏好', lines: 3),
          const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                  '智能体优先匹配游戏和 AppID，读取清单与说明，生成源目录及目标目录。校验通过的明确结果自动保存；特殊安装器、目录不明等情况集中标记为待配置。')),
        ])
      ];

  List<Widget> defaultPage() => [
        for (final type in ['game', 'patch'])
          card(type == 'game' ? '游戏扫描' : '补丁扫描', [
            toggle('${type}_ask', '手动扫描前询问方式', '关闭后使用默认方式，可随时恢复询问。'),
            select('${type}_default', '手动扫描默认方式',
                const {'regular': '常规扫描', 'agent': '智能体优先，常规兜底'}),
            select('scheduled_$type', '定时扫描方式',
                const {'regular': '常规扫描', 'agent': '智能体优先，常规兜底'}),
            const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('定时任务不弹窗。总开关关闭时回退常规方式，不会自动开启智能体。')),
          ])
      ];

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: Text(widget.setup ? '初始化 4/4 · 智能体（可选）' : '智能体'),
            actions: [
              if (!widget.setup)
                IconButton(
                    tooltip: '任务记录',
                    icon: const Icon(Icons.history),
                    onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => AgentJobsScreen(api: widget.api))))
            ]),
        body: value == null
            ? Center(
                child: error == null
                    ? const CircularProgressIndicator()
                    : Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(error!),
                        TextButton(onPressed: load, child: const Text('重试')),
                        if (widget.setup)
                          TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('暂不配置'))
                      ]))
            : ListView(padding: const EdgeInsets.all(20), children: [
                if (widget.setup)
                  const Padding(
                      padding: EdgeInsets.only(bottom: 14),
                      child: Text('基础初始化已完成，已登录管理员。跳过此步不影响游戏库使用。')),
                card('智能体辅助', [
                  toggle('enabled', '启用智能体辅助', '默认关闭。关闭后不调用模型，保留已完成结果与配置。')
                ]),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (int i = 0; i < 4; i++)
                    ChoiceChip(
                        showCheckmark: false,
                        label: Text(['模型与代理', '游戏偏好', '补丁偏好', '扫描默认项'][i]),
                        selected: page == i,
                        onSelected: (_) => setState(() => page = i))
                ]),
                const SizedBox(height: 16),
                ...[modelPage, gamePage, patchPage, defaultPage][page](),
                if (error != null) Text(error!),
                Wrap(spacing: 12, children: [
                  if (widget.setup)
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('暂不配置')),
                  FilledButton(
                      onPressed: busy ? null : () => save(finish: widget.setup),
                      child: Text(busy
                          ? '处理中…'
                          : widget.setup
                              ? '保存并完成'
                              : '保存设置'))
                ]),
              ]),
      );
}

Future<String?> chooseScanMode(
    BuildContext context, ApiClient api, String kind) async {
  final service = AgentService(api);
  Map<String, dynamic> config;
  try {
    config = await service.settings();
  } catch (_) {
    return 'regular';
  }
  if (!context.mounted) return null;
  final available =
      config['enabled'] == true && '${config['model'] ?? ''}'.isNotEmpty;
  var mode = '${config['${kind}_default'] ?? 'regular'}';
  if (!available && mode == 'agent') {
    mode = 'regular';
    if (config['${kind}_ask'] == false) {
      await _showAgentMessage(context, '智能体已关闭或未配置，本次使用常规扫描');
      if (!context.mounted) return null;
    }
  }
  if (config['${kind}_ask'] == false) return mode;
  var remember = false;
  final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
          builder: (ctx, update) => AlertDialog(
                scrollable: true,
                title: Text('选择${kind == 'patch' ? '补丁' : '游戏'}扫描方式'),
                content: SizedBox(
                    width: 420,
                    child: RadioGroup<String>(
                        groupValue: mode,
                        onChanged: (v) => update(() => mode = v!),
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                           const RadioListTile<String>(
                               value: 'regular',
                               title: Text('常规扫描'),
                               subtitle: Text('使用现有流程，不调用模型')),
                          RadioListTile<String>(
                              value: 'agent',
                              enabled: available,
                              title: const Text('智能体扫描'),
                              subtitle: Text(available
                                  ? '智能体优先，常规兜底；明确结果自动应用'
                                  : '智能体尚未开启或未配置')),
                          CheckboxListTile(
                              value: remember,
                              title: const Text('记住此选择，下次不再询问'),
                              onChanged: (v) =>
                                  update(() => remember = v == true)),
                        ]))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, mode),
                      child: const Text('开始扫描'))
                ],
              )));
  if (result != null && remember) {
    config['${kind}_ask'] = false;
    config['${kind}_default'] = result;
    await service.save(config);
  }
  return result;
}

Future<void> startAgentTask(BuildContext context, ApiClient api, String kind,
    {List<int>? rootIds, List<int>? gameIds}) async {
  final result = await AgentService(api).request('POST', '/jobs', {
    'kind': kind,
    if (rootIds != null) 'root_ids': rootIds,
    if (gameIds != null) 'game_ids': gameIds
  });
  if (context.mounted) {
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) =>
                AgentJobsScreen(api: api, jobId: result['id'] as int)));
  }
}

class AgentJobsScreen extends StatefulWidget {
  final ApiClient api;
  final int? jobId;
  const AgentJobsScreen({super.key, required this.api, this.jobId});
  @override
  State<AgentJobsScreen> createState() => _AgentJobsScreenState();
}

class _AgentJobsScreenState extends State<AgentJobsScreen> {
  static const reviewStatuses = {
    'review', 'fallback', 'partial', 'unmatched', 'budget_fallback',
    'model_fallback', 'validation_fallback', 'config_fallback', 'source_fallback',
  };
  late final service = AgentService(widget.api);
  List<dynamic> rows = [];
  Map<String, dynamic>? job;
  String? error;
  bool review = false, loading = false;
  int offset = 0;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(const Duration(seconds: 3), (_) => load());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    if (loading) return;
    loading = true;
    try {
      final data = await service.request(
          'GET',
          widget.jobId == null
              ? '/jobs?offset=$offset'
              : '/jobs/${widget.jobId}?offset=$offset&review_only=$review');
      if (mounted) {
        setState(() {
          if (widget.jobId == null) {
            rows = data as List;
          } else {
            job = Map<String, dynamic>.from(data);
            rows = job!['results'] as List;
            if (!['pending', 'running'].contains(job!['status'])) {
              timer?.cancel();
            }
          }
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      loading = false;
    }
  }

  Future<void> action(String path, [Object? body]) async {
    try {
      final data = await service.request('POST', path, body);
      if (mounted && data is Map && data['id'] != null) {
        await Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => AgentJobsScreen(
                    api: widget.api, jobId: data['id'] as int)));
      }
      await load();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  String label(dynamic value) =>
      const {
        'pending': '排队中',
        'running': '运行中',
        'completed': '已完成',
        'cancelled': '已停止',
        'failed': '失败',
        'interrupted': '已中断',
        'review': '待处理',
        'fallback': '常规兜底',
        'budget_fallback': '预算回退',
        'model_fallback': '模型异常回退',
        'validation_fallback': '校验回退',
        'config_fallback': '配置变化回退',
        'source_fallback': '资料源异常回退',
        'partial': '部分识别',
        'unmatched': '匹配待核实',
        'skipped': '保留已有记录',
        'identified': '智能识别',
        'applied': '已自动应用',
        'cached': '复用结果',
        'ignored': '已忽略',
        'game': '游戏扫描',
        'patch': '补丁扫描',
        'scrape': '资料刮削',
      }[value] ??
      '$value';

  String resultSummary(Map row) {
    final summary = '${row['summary']}';
    final groups = (row['data'] as Map?)?['groups'];
    if (row['status'] == 'identified' && groups is List && groups.isNotEmpty &&
        summary.contains('未确定内容交给常规扫描')) {
      return '已识别 ${groups.length} 组游戏';
    }
    return summary;
  }

  Widget resultDetails(Map row) {
    final data = row['data'] as Map? ?? {};
    final patch = data['patch'] as Map?;
    return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (patch != null) ...[
              Text('${patch['game_name'] ?? '未匹配'}', style: AppText.title),
              Text('Steam AppID：${patch['app_id'] ?? '待确认'}'),
              const SizedBox(height: 10),
              SelectableText(
                  '复制源目录：${patch['patch_dir'] ?? ''}\n游戏内目标：${(patch['target_dir'] ?? '').toString().isEmpty ? '游戏根目录' : patch['target_dir']}'),
              Text(
                  '安装配置：${patch['manifest_status'] == 'confirmed' ? '已确认（安装前客户端仍会校验）' : '待配置，请到补丁管理页补充'}'),
            ] else ...[
              if (data['name'] != null) Text('${data['name']}'),
              if (data['source'] != null) Text('资料来源：${data['source']}'),
              for (final group in data['groups'] as List? ?? [])
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${group['name']}'),
                    subtitle: Text(
                        '${group['source']} · ${group['evidence']}${group['directory_only'] == true ? '\n散装目录条目，尚无压缩包下载版本' : ''}')),
              for (final file in data['files'] as List? ?? [])
                SelectableText('$file'),
            ],
          ],
        ));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(
          title: Text(widget.jobId == null ? '智能体任务' : '分析结果'),
          actions: [
            IconButton(onPressed: load, icon: const Icon(Icons.refresh))
          ]),
      body: ListView(padding: const EdgeInsets.all(18), children: [
        if (error != null) Text(error!),
        if (job != null) ...[
          Text(
              '${label(job!['status'])} · 模型请求 ${job!['calls']} · Token ${job!['tokens']}',
              style: AppText.title),
          Text('${job!['message']}'),
          if (job!['calls'] == 0 && ['pending', 'running'].contains(job!['status']))
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('模型尚未调用；目录列举和文件清单准备不计入调用次数。'),
            ),
          Wrap(spacing: 8, children: [
            for (final entry in (job!['counts'] as Map? ?? {}).entries)
              Chip(label: Text('${label(entry.key)} ${entry.value}'))
          ]),
          Wrap(spacing: 10, children: [
            if (['pending', 'running'].contains(job!['status']))
              TextButton(
                  onPressed: () => action('/jobs/${widget.jobId}/cancel'),
                  child: const Text('停止后续调用'))
            else
              TextButton(
                  onPressed: () => action('/jobs/${widget.jobId}/retry'),
                  child: const Text('重试未完成内容')),
            FilterChip(
                label: const Text('仅看待处理'),
                selected: review,
                onSelected: (v) {
                  setState(() {
                    review = v;
                    offset = 0;
                  });
                  load();
                }),
            if (rows.any((r) => reviewStatuses.contains(r['status'])))
              TextButton(
                  onPressed: () => action('/results/ignore', {
                        'ids': rows
                            .where((r) =>
                                reviewStatuses.contains(r['status']))
                            .map((r) => r['id'])
                            .toList()
                      }),
                  child: const Text('忽略本页待处理项')),
          ])
        ],
        for (final row in rows)
          Card(
              child: widget.jobId == null
                  ? ListTile(
                      title: Text(
                          '${label(row['kind'])} · ${label(row['status'])}'),
                      subtitle: Text('${row['message']}'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => AgentJobsScreen(
                                  api: widget.api, jobId: row['id'] as int))))
                  : ExpansionTile(
                      title: Text(resultSummary(row as Map)),
                      subtitle: Text('${label(row['status'])} · ${row['key']}'),
                      children: [
                          resultDetails(row as Map),
                          if (reviewStatuses.contains(row['status']))
                            TextButton(
                                onPressed: () =>
                                    action('/results/${row['id']}/ignore'),
                                child: const Text('忽略此项'))
                        ])),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          TextButton(
              onPressed: offset == 0
                  ? null
                  : () {
                      setState(() => offset =
                          (offset - (widget.jobId == null ? 30 : 100))
                              .clamp(0, 1000000));
                      load();
                    },
              child: const Text('上一页')),
          TextButton(
              onPressed: rows.length < (widget.jobId == null ? 30 : 100)
                  ? null
                  : () {
                      setState(() => offset += widget.jobId == null ? 30 : 100);
                      load();
                    },
              child: const Text('下一页'))
        ]),
      ]));
}
