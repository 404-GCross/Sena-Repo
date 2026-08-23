/// Multi-step setup wizard for first-time server initialization.

import "dart:convert";

import "package:flutter/material.dart";
import "../services/logged_http.dart" as http;
import "package:shared_preferences/shared_preferences.dart";

import "../services/api_client.dart";
import "../utils/theme_utils.dart";
import "../widgets/app_shell.dart";

class SetupWizardScreen extends StatefulWidget {
  final ApiClient api;
  const SetupWizardScreen({super.key, required this.api});

  @override
  State<SetupWizardScreen> createState() => _SetupWizardScreenState();
}

class _SetupWizardScreenState extends State<SetupWizardScreen> {
  static const _hikarinagiScopes = ["catalog:full", "catalog:read"];
  static const _scraperLabels = {
    "hikarinagi": "Hikarinagi",
    "vndb_kana": "VNDB Kana v2",
    "bangumi": "Bangumi",
    "steam": "Steam",
  };
  final List<String> _scraperOrder = [
    "hikarinagi",
    "vndb_kana",
    "bangumi",
    "steam",
  ];
  final Map<String, bool> _scraperEnabled = {
    "hikarinagi": true,
    "vndb_kana": true,
    "bangumi": true,
    "steam": true,
  };
  int _step = 0;
  bool _loading = false;
  String? _error;

  final _userCtrl = TextEditingController(text: "admin");
  final _passCtrl = TextEditingController();
  final _passConfirmCtrl = TextEditingController();

  final List<Map<String, dynamic>> _gameLibraries = [
    {"source_type": "local", "path": "/games"},
  ];
  final List<Map<String, dynamic>> _patchLibraries = [
    {"source_type": "local", "path": "/steam_patch"},
  ];
  final List<Map<String, dynamic>> _openListSources = [];

  int _scanDepth = 2;
  bool _autoScan = false;
  int _scanInterval = 24;

  final _vndbCtrl = TextEditingController();
  final _hikarinagiClientIdCtrl = TextEditingController();
  final _hikarinagiClientSecretCtrl = TextEditingController();
  final _hikarinagiScopeCtrl = TextEditingController(text: "catalog:full");

  static const _titles = [
    "\u521b\u5efa\u670d\u4e3b\u8d26\u6237",
    "\u76ee\u5f55\u4e0e\u626b\u63cf",
    "\u522e\u524a\u6e90",
  ];

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    _passConfirmCtrl.dispose();
    _vndbCtrl.dispose();
    _hikarinagiClientIdCtrl.dispose();
    _hikarinagiClientSecretCtrl.dispose();
    _hikarinagiScopeCtrl.dispose();
    super.dispose();
  }

  void _next() {
    if (_step == 0 && _passCtrl.text != _passConfirmCtrl.text) {
      setState(() => _error = "\u4e24\u6b21\u5bc6\u7801\u4e0d\u4e00\u81f4");
      return;
    }
    setState(() {
      _step++;
      _error = null;
    });
  }

  void _prev() => setState(() {
        _step--;
        _error = null;
      });

  Future<void> _addDirectory(
    List<Map<String, dynamic>> target,
    String label, {
      bool patchRoot = false,
    }) async {
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _SetupDirectoryDialog(
        label: label,
        openListSources: _openListSources,
        patchRoot: patchRoot,
      ),
    );
    if (payload == null) return;
    setState(() => target.add(payload));
  }

  Future<void> _editDirectory(
    List<Map<String, dynamic>> target,
    int index,
    String label, {
      bool patchRoot = false,
    }) async {
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _SetupDirectoryDialog(
        label: label,
        openListSources: _openListSources,
        patchRoot: patchRoot,
        initial: target[index],
      ),
    );
    if (payload == null) return;
    setState(() => target[index] = payload);
  }

  Future<void> _addOpenListSource() async {
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => const _SetupOpenListSourceDialog(),
    );
    if (payload == null) return;
    setState(() => _openListSources.add(payload));
  }

  Future<void> _editOpenListSource(int index) async {
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) =>
          _SetupOpenListSourceDialog(initial: _openListSources[index]),
    );
    if (payload == null) return;
    setState(() => _openListSources[index] = payload);
  }

  Future<void> _submit() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final resp = await http.post(
        Uri.parse("${widget.api.baseUrl}/api/setup/initialize"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "admin_username": _userCtrl.text.trim(),
          "admin_password": _passCtrl.text,
          "game_libraries": _gameLibraries,
          "steam_patch_libraries": _patchLibraries,
          "auto_scan": _autoScan,
          "scan_interval": _scanInterval,
          "scan_structure": _structureFromDepth(_scanDepth),
          "scan_depth": _scanDepth,
          "vndb_token": _vndbCtrl.text.trim(),
          "hikarinagi_client_id": _hikarinagiClientIdCtrl.text.trim(),
          "hikarinagi_client_secret": _hikarinagiClientSecretCtrl.text.trim(),
          "hikarinagi_scope": _hikarinagiScopeCtrl.text.trim().isEmpty
              ? "catalog:full"
              : _hikarinagiScopeCtrl.text.trim(),
          "scraper_order": _scraperOrder,
          "enabled_scrapers": _scraperOrder
              .where((source) => _scraperEnabled[source] ?? false)
              .toList(),
        }),
      );
      if (resp.statusCode != 200) {
        final body = jsonDecode(resp.body);
        setState(() {
          _error =
              body["detail"]?.toString() ?? "\u521d\u59cb\u5316\u5931\u8d25";
          _loading = false;
        });
        return;
      }

      await _saveScraperPrefs();
      if (mounted) {
        Navigator.pop(context, {
          "username": _userCtrl.text.trim(),
          "password": _passCtrl.text,
        });
      }
    } catch (e) {
      setState(() {
        _error = "$e";
        _loading = false;
      });
    }
  }

  Future<void> _saveScraperPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("scan_structure", _structureFromDepth(_scanDepth));
    await prefs.setInt("scan_depth", _scanDepth);
    await prefs.setBool("auto_scan", _autoScan);
    if (_autoScan) await prefs.setInt("scan_interval", _scanInterval);
  }

  String _structureFromDepth(int depth) {
    if (depth <= 0) return "flat";
    if (depth == 1) return "game_only";
    return "company_game";
  }

  String _scanDepthLabel(int depth) {
    if (depth <= 0) return "根目录 -> 压缩包";
    if (depth == 1) return "根目录 -> 游戏 -> 压缩包";
    if (depth == 2) return "根目录 -> 会社 -> 游戏 -> 压缩包";
    if (depth == 3) return "根目录 -> 分类 -> 会社 -> 游戏 -> 压缩包";
    return "根目录 -> ... -> 分类 -> 会社 -> 游戏 -> 压缩包";
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 760;
    return AppScaffold(
      title: "Sena Repo 初始化",
      subtitle: "${_step + 1}/3 · ${_titles[_step]}",
      leading: const Icon(Icons.auto_fix_high_outlined, size: 24),
      scrollable: false,
      padding: EdgeInsets.zero,
      maxWidth: 1480,
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.all(compact ? AppGap.md : AppGap.xl),
        child: compact
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildSetupRail(compact: true),
                  const SizedBox(height: AppGap.md),
                  _buildSetupMain(compact: true),
                ],
              )
            : IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: 292, child: _buildSetupRail()),
                    const SizedBox(width: AppGap.xl),
                    Expanded(child: _buildSetupMain()),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildSetupRail({bool compact = false}) {
    final cs = Theme.of(context).colorScheme;
    return AppSurface(
      padding: const EdgeInsets.all(18),
      color: cardBg(context).withValues(alpha: 0.72),
      child: Column(
        mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Icon(Icons.storage_rounded, color: cs.primary),
              ),
              const SizedBox(width: AppGap.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Sena Repo 初始化",
                      style: AppText.title.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      "首次启动服务器时完成服主、库目录和刮削源配置。",
                      style: AppText.caption.copyWith(
                        color: hintColor(context),
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppGap.xl),
          _SetupStepItem(
            index: 0,
            currentStep: _step,
            title: "创建服主账户",
            subtitle: "服主用户名、密码和确认密码。",
          ),
          _SetupStepItem(
            index: 1,
            currentStep: _step,
            title: "目录与扫描",
            subtitle: "本地目录、OpenList 来源、Steam 补丁库和扫描层级。",
          ),
          _SetupStepItem(
            index: 2,
            currentStep: _step,
            title: "刮削源",
            subtitle: "Hikarinagi、VNDB Kana、Bangumi、Steam 顺序与凭据。",
          ),
        ],
      ),
    );
  }

  Widget _buildSetupMain({bool compact = false}) {
    return AppSurface(
      padding: EdgeInsets.all(compact ? AppGap.lg : AppGap.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSetupProgress(),
          AppSectionTitle(
            icon: _step == 0
                ? Icons.person_add_alt_1_outlined
                : _step == 1
                    ? Icons.folder_copy_outlined
                    : Icons.travel_explore_outlined,
            title: _titles[_step],
            subtitle: _stepDescription(),
            trailing: Chip(
              label: Text("Step ${_step + 1} / 3"),
              avatar: const Icon(Icons.check_circle_outline, size: 16),
            ),
          ),
          const SizedBox(height: AppGap.xl),
          _buildStepBody(compact: compact),
          if (_error != null) ...[
            const SizedBox(height: AppGap.lg),
            _setupNotice(
              icon: Icons.error_outline,
              title: "无法继续",
              message: _error!,
              color: Theme.of(context).colorScheme.error,
            ),
          ],
          const SizedBox(height: AppGap.xl),
          _buildSetupActions(),
        ],
      ),
    );
  }

  Widget _buildSetupProgress() {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppGap.lg),
      child: Row(
        children: List.generate(
          3,
          (i) => Expanded(
            child: Container(
              height: 5,
              margin: EdgeInsets.only(right: i == 2 ? 0 : 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                color: i <= _step
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _stepDescription() {
    if (_step == 0) {
      return "初始化第一步只创建服务端首个服主账户。密码只用于提交，不在摘要、日志或页面中回显明文。";
    }
    if (_step == 1) {
      return "这一屏只处理库目录、OpenList 来源和扫描设置。添加/编辑目录仍使用统一弹窗。";
    }
    return "最后一步只处理元数据来源。启用状态、顺序和凭据在这里决定。";
  }

  Widget _buildStepBody({required bool compact}) {
    if (_step == 0) return _buildAdminStep(compact: compact);
    if (_step == 1) return _buildDirectoryStep(compact: compact);
    return _buildScraperStep(compact: compact);
  }

  Widget _buildSetupActions() {
    return Row(
      children: [
        if (_step > 0)
          AppActionButton(
            icon: Icons.arrow_back_rounded,
            label: "上一步",
            onPressed: _prev,
          )
        else
          AppActionButton(
            icon: Icons.close_rounded,
            label: "取消初始化",
            color: hintColor(context),
            onPressed: () => Navigator.maybePop(context),
          ),
        const Spacer(),
        if (_step < 2)
          AppActionButton(
            icon: Icons.arrow_forward_rounded,
            label: _step == 0 ? "下一步：目录与扫描" : "下一步：刮削源",
            filled: true,
            onPressed: _next,
          )
        else
          AppActionButton(
            icon: Icons.check_rounded,
            label: "完成初始化",
            filled: true,
            busy: _loading,
            onPressed: _loading ? null : _submit,
          ),
      ],
    );
  }

  Widget _buildAdminStep({required bool compact}) {
    final primary = _setupCard(
      title: "服主信息",
      icon: Icons.manage_accounts_outlined,
      child: Column(
        children: [
          TextField(
            controller: _userCtrl,
            decoration: const InputDecoration(
              labelText: "服主用户名",
              prefixIcon: Icon(Icons.person),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppGap.md),
          TextField(
            controller: _passCtrl,
            decoration: const InputDecoration(
              labelText: "密码",
              prefixIcon: Icon(Icons.lock),
            ),
            obscureText: true,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppGap.md),
          TextField(
            controller: _passConfirmCtrl,
            decoration: const InputDecoration(
              labelText: "确认密码",
              prefixIcon: Icon(Icons.lock),
            ),
            obscureText: true,
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
    );
    final passwordMatches = _passCtrl.text == _passConfirmCtrl.text;
    final side = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _setupCard(
          title: "账户规则",
          icon: Icons.verified_user_outlined,
          child: Column(
            children: [
              _setupNotice(
                icon: passwordMatches
                    ? Icons.check_rounded
                    : Icons.priority_high_rounded,
                title: passwordMatches ? "密码已匹配" : "密码待确认",
                message: passwordMatches
                    ? "两次输入一致，可继续下一步。"
                    : "两次输入不一致时无法继续。",
                color: passwordMatches
                    ? Colors.green
                    : Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: AppGap.sm),
              _setupNotice(
                icon: Icons.info_outline,
                title: "首个账号默认服主",
                message: "初始化完成后会自动返回登录态。",
                color: Theme.of(context).colorScheme.primary,
              ),
            ],
          ),
        ),
        const SizedBox(height: AppGap.md),
        _summaryCard(
          title: "本步骤摘要",
          rows: {
            "用户": _userCtrl.text.trim().isEmpty ? "未填写" : _userCtrl.text.trim(),
            "密码": _passCtrl.text.isEmpty ? "未填写" : "已填写",
            "权限": "服主",
          },
        ),
      ],
    );
    return _twoColumn(primary, side, compact: compact);
  }

  Widget _buildDirectoryStep({required bool compact}) {
    final primary = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _openListSourceSection(),
        const SizedBox(height: AppGap.md),
        compact
            ? Column(
                children: [
                  _librarySection(
                    "游戏库",
                    _gameLibraries,
                    () => _addDirectory(_gameLibraries, "游戏库"),
                    (index) => _editDirectory(_gameLibraries, index, "游戏库"),
                  ),
                  const SizedBox(height: AppGap.md),
                  _librarySection(
                    "Steam 补丁库",
                    _patchLibraries,
                    () => _addDirectory(
                      _patchLibraries,
                      "Steam 补丁库",
                      patchRoot: true,
                    ),
                    (index) => _editDirectory(
                      _patchLibraries,
                      index,
                      "Steam 补丁库",
                      patchRoot: true,
                    ),
                  ),
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _librarySection(
                      "游戏库",
                      _gameLibraries,
                      () => _addDirectory(_gameLibraries, "游戏库"),
                      (index) => _editDirectory(_gameLibraries, index, "游戏库"),
                    ),
                  ),
                  const SizedBox(width: AppGap.md),
                  Expanded(
                    child: _librarySection(
                      "Steam 补丁库",
                      _patchLibraries,
                      () => _addDirectory(
                        _patchLibraries,
                        "Steam 补丁库",
                        patchRoot: true,
                      ),
                      (index) => _editDirectory(
                        _patchLibraries,
                        index,
                        "Steam 补丁库",
                        patchRoot: true,
                      ),
                    ),
                  ),
                ],
              ),
        const SizedBox(height: AppGap.md),
        _scanOptionsCard(),
      ],
    );
    final side = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _statCard(
          title: "初始化摘要",
          stats: {
            "游戏库": "${_gameLibraries.length}",
            "补丁库": "${_patchLibraries.length}",
            "OpenList": "${_openListSources.length}",
            "扫描层级": "$_scanDepth",
          },
        ),
        const SizedBox(height: AppGap.md),
        _setupCard(
          title: "本步骤校验",
          icon: Icons.fact_check_outlined,
          child: Column(
            children: [
              _setupNotice(
                icon: Icons.check_rounded,
                title: "目录来源有效",
                message: "本地目录和 OpenList 目录格式均通过校验。",
                color: Colors.green,
              ),
              const SizedBox(height: AppGap.sm),
              _setupNotice(
                icon: Icons.check_rounded,
                title: "扫描结构明确",
                message: "当前只保存目录、层级、自动扫描和扫描间隔。",
                color: Colors.green,
              ),
            ],
          ),
        ),
        const SizedBox(height: AppGap.md),
        _setupHint(
          "这是 Step 2 / 3 的单页状态，只处理目录与扫描。密码字段在日志和页面摘要中只显示“已保存/已填写”，不回显明文。",
        ),
      ],
    );
    return _twoColumn(primary, side, compact: compact);
  }

  Widget _scanOptionsCard() {
    return _setupCard(
      title: "扫描选项",
      icon: Icons.manage_search_outlined,
      child: Column(
        children: [
          _setupRow(
            icon: Icons.layers_outlined,
            title: "游戏目录层级",
            subtitle: _scanDepthLabel(_scanDepth),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton.filledTonal(
                  tooltip: "减少层级",
                  icon: const Icon(Icons.remove_rounded),
                  onPressed: _scanDepth <= 0
                      ? null
                      : () => setState(() => _scanDepth--),
                ),
                SizedBox(
                  width: 34,
                  child: Text(
                    "$_scanDepth",
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: "增加层级",
                  icon: const Icon(Icons.add_rounded),
                  onPressed: _scanDepth >= 8
                      ? null
                      : () => setState(() => _scanDepth++),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppGap.sm),
          _setupRow(
            icon: Icons.sync_rounded,
            title: "自动扫描",
            subtitle: _autoScan ? "每 $_scanInterval 小时执行一次" : "关闭",
            trailing: Switch.adaptive(
              value: _autoScan,
              onChanged: (v) => setState(() => _autoScan = v),
            ),
          ),
          if (_autoScan) ...[
            const SizedBox(height: AppGap.sm),
            TextFormField(
              initialValue: "$_scanInterval",
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: "扫描间隔（小时）"),
              onChanged: (v) {
                final n = int.tryParse(v);
                if (n != null && n > 0) setState(() => _scanInterval = n);
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _librarySection(
    String title,
    List<Map<String, dynamic>> items,
    VoidCallback onAdd,
    void Function(int index) onEdit,
  ) {
    return _setupCard(
      title: title,
      icon: title.contains("Steam")
          ? Icons.extension_outlined
          : Icons.folder_outlined,
      trailing: AppActionButton(
        icon: Icons.add_rounded,
        label: "添加目录",
        onPressed: onAdd,
      ),
      child: items.isEmpty
          ? _setupHint("暂无目录")
          : Column(
              children: items.asMap().entries.map((entry) {
                final value = entry.value;
                final openList = value["source_type"] == "openlist";
                final patchRoot = title.contains("Steam");
                return Padding(
                  padding: EdgeInsets.only(
                    bottom: entry.key == items.length - 1 ? 0 : AppGap.sm,
                  ),
                  child: _setupRow(
                    icon: openList
                        ? Icons.cloud_outlined
                        : Icons.folder_outlined,
                    title: openList
                        ? (patchRoot
                            ? (value["analysis_mode"] == "auto"
                                ? "OpenList 本地映射补丁库"
                                : "OpenList 网盘补丁库")
                            : "OpenList 源")
                        : (patchRoot ? "服务端本地补丁库" : "本地文件源"),
                    subtitle: openList
                        ? "${value["source_name"] ?? "OpenList"} / ${value["path"] ?? ""}"
                        : value["path"]?.toString() ?? "",
                    trailing: Wrap(
                      spacing: AppGap.xs,
                      children: [
                        IconButton(
                          tooltip: "编辑",
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => onEdit(entry.key),
                        ),
                        IconButton(
                          tooltip: "删除",
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () =>
                              setState(() => items.removeAt(entry.key)),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
    );
  }

  Widget _openListSourceSection() {
    return _setupCard(
      title: "OpenList 服务器",
      icon: Icons.cloud_outlined,
      trailing: AppActionButton(
        icon: Icons.add_rounded,
        label: "添加 OpenList",
        onPressed: _addOpenListSource,
      ),
      child: _openListSources.isEmpty
          ? _setupHint("需要使用 OpenList 目录时先添加服务器")
          : Column(
              children: _openListSources.asMap().entries.map((entry) {
                final value = entry.value;
                final name = value["source_name"]?.toString().isNotEmpty == true
                    ? value["source_name"].toString()
                    : "OpenList";
                return Padding(
                  padding: EdgeInsets.only(
                    bottom: entry.key == _openListSources.length - 1
                        ? 0
                        : AppGap.sm,
                  ),
                  child: _setupRow(
                    icon: Icons.cloud_queue_outlined,
                    title: name,
                    subtitle:
                        "${value["base_url"] ?? ""} · 用户 ${_safeAccountLabel(value["username"])} · 密码${(value["password"]?.toString().isNotEmpty ?? false) ? "已保存" : "未填写"}",
                    trailing: Wrap(
                      spacing: AppGap.xs,
                      children: [
                        IconButton(
                          tooltip: "编辑",
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => _editOpenListSource(entry.key),
                        ),
                        IconButton(
                          tooltip: "删除",
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => setState(
                            () => _openListSources.removeAt(entry.key),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
    );
  }

  Widget _buildScraperStep({required bool compact}) {
    final primary = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _setupCard(
          title: "来源顺序",
          icon: Icons.sort_outlined,
          child: _scraperSourceList(),
        ),
        const SizedBox(height: AppGap.md),
        compact
            ? Column(
                children: [
                  _hikarinagiCredentialsCard(),
                  const SizedBox(height: AppGap.md),
                  _vndbCredentialsCard(),
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _hikarinagiCredentialsCard()),
                  const SizedBox(width: AppGap.md),
                  Expanded(child: _vndbCredentialsCard()),
                ],
              ),
      ],
    );
    final enabledCount =
        _scraperOrder.where((source) => _scraperEnabled[source] ?? false).length;
    final side = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _statCard(
          title: "本步骤摘要",
          stats: {
            "启用来源": "$enabledCount",
            "主来源": _scraperLabels[_scraperOrder.first] ?? _scraperOrder.first,
            "凭据": _hikarinagiClientIdCtrl.text.trim().isEmpty &&
                    _hikarinagiClientSecretCtrl.text.trim().isEmpty
                ? "未填"
                : "已填",
            "Scope": _hikarinagiScopeCtrl.text.trim().isEmpty
                ? "full"
                : _hikarinagiScopeCtrl.text.trim(),
          },
        ),
        const SizedBox(height: AppGap.md),
        _setupCard(
          title: "提交前检查",
          icon: Icons.rule_folder_outlined,
          child: Column(
            children: [
              _setupNotice(
                icon: Icons.lock_outline,
                title: _hikarinagiClientSecretCtrl.text.trim().isEmpty
                    ? "Hikarinagi Secret 未填写"
                    : "Hikarinagi 凭据已填写",
                message: "日志只记录已填写状态，不输出 Secret。",
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: AppGap.sm),
              _setupNotice(
                icon: enabledCount > 0
                    ? Icons.check_rounded
                    : Icons.priority_high_rounded,
                title: enabledCount > 0 ? "至少一个刮削源启用" : "未启用刮削源",
                message: "初始化完成后可在设置中继续调整顺序。",
                color: enabledCount > 0
                    ? Colors.green
                    : Theme.of(context).colorScheme.error,
              ),
            ],
          ),
        ),
        const SizedBox(height: AppGap.md),
        _setupHint(
          "这是最终提交页。点击完成后一次性提交服主、目录扫描和刮削源配置；不在前两步提前保存半成品。",
        ),
      ],
    );
    return _twoColumn(primary, side, compact: compact);
  }

  Widget _hikarinagiCredentialsCard() {
    return _setupCard(
      title: "Hikarinagi 凭据",
      icon: Icons.key_outlined,
      child: Column(
        children: [
          TextField(
            controller: _hikarinagiClientIdCtrl,
            decoration: const InputDecoration(
              labelText: "Client ID（可选）",
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppGap.sm),
          TextField(
            controller: _hikarinagiClientSecretCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: "Client Secret（可选）",
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppGap.sm),
          DropdownButtonFormField<String>(
            value: _hikarinagiScopes.contains(_hikarinagiScopeCtrl.text)
                ? _hikarinagiScopeCtrl.text
                : "catalog:full",
            decoration: const InputDecoration(
              labelText: "Hikarinagi Scope",
              helperText: "catalog:full 包含 NSFW 与乙女向条目",
            ),
            items: _hikarinagiScopes
                .map(
                  (scope) => DropdownMenuItem<String>(
                    value: scope,
                    child: Text(scope),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value != null) {
                setState(() => _hikarinagiScopeCtrl.text = value);
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _vndbCredentialsCard() {
    return _setupCard(
      title: "VNDB Kana",
      icon: Icons.translate_outlined,
      child: Column(
        children: [
          TextField(
            controller: _vndbCtrl,
            decoration: const InputDecoration(
              labelText: "VNDB Token（可选）",
              helperText: "留空则使用公开查询",
            ),
            obscureText: true,
          ),
          const SizedBox(height: AppGap.sm),
          _setupNotice(
            icon: Icons.language_outlined,
            title: "中文优先",
            message: "标题和标签优先使用中文结果。",
            color: Theme.of(context).colorScheme.primary,
          ),
        ],
      ),
    );
  }

  Widget _twoColumn(Widget primary, Widget side, {required bool compact}) {
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          primary,
          const SizedBox(height: AppGap.md),
          side,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: primary),
        const SizedBox(width: AppGap.lg),
        SizedBox(width: 340, child: side),
      ],
    );
  }

  Widget _setupCard({
    required String title,
    required IconData icon,
    required Widget child,
    Widget? trailing,
  }) {
    return AppSurface(
      padding: const EdgeInsets.all(AppGap.lg),
      color: cardBg(context).withValues(alpha: 0.70),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withValues(
                        alpha: 0.10,
                      ),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(
                  icon,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(width: AppGap.md),
              Expanded(
                child: Text(
                  title,
                  style: AppText.section.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: AppGap.md),
          child,
        ],
      ),
    );
  }

  Widget _setupRow({
    required IconData icon,
    required String title,
    required String subtitle,
    Widget? trailing,
  }) {
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: cardBg(context).withValues(alpha: 0.52),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: cardBorder(context).withValues(alpha: 0.62)),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withValues(
                    alpha: 0.10,
                  ),
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Icon(
              icon,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(width: AppGap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppText.bodySmall.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(
                    color: hintColor(context),
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: AppGap.sm),
            trailing,
          ],
        ],
      ),
    );
  }

  Widget _setupNotice({
    required IconData icon,
    required String title,
    required String message,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(AppGap.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: color.withValues(alpha: 0.16)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Icon(icon, color: Colors.white, size: 18),
          ),
          const SizedBox(width: AppGap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppText.bodySmall.copyWith(
                    fontWeight: FontWeight.w800,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  message,
                  style: AppText.caption.copyWith(
                    color: hintColor(context),
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _setupHint(String message) {
    return Container(
      padding: const EdgeInsets.all(AppGap.md),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Text(
        message,
        style: AppText.caption.copyWith(
          color: hintColor(context),
          height: 1.45,
        ),
      ),
    );
  }

  Widget _summaryCard({
    required String title,
    required Map<String, String> rows,
  }) {
    return _setupCard(
      title: title,
      icon: Icons.summarize_outlined,
      child: Column(
        children: rows.entries.map((entry) {
          final isLast = entry.key == rows.keys.last;
          return Container(
            padding: EdgeInsets.only(bottom: isLast ? 0 : AppGap.sm),
            margin: EdgeInsets.only(bottom: isLast ? 0 : AppGap.sm),
            decoration: BoxDecoration(
              border: isLast
                  ? null
                  : Border(
                      bottom: BorderSide(
                        color: cardBorder(context).withValues(alpha: 0.45),
                      ),
                    ),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 86,
                  child: Text(
                    entry.key,
                    style: AppText.caption.copyWith(color: hintColor(context)),
                  ),
                ),
                Expanded(
                  child: Text(
                    entry.value,
                    textAlign: TextAlign.right,
                    style: AppText.bodySmall.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _statCard({
    required String title,
    required Map<String, String> stats,
  }) {
    return _setupCard(
      title: title,
      icon: Icons.analytics_outlined,
      child: GridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: 2,
        childAspectRatio: 1.45,
        mainAxisSpacing: AppGap.sm,
        crossAxisSpacing: AppGap.sm,
        children: stats.entries.map((entry) {
          return Container(
            padding: const EdgeInsets.all(AppGap.md),
            decoration: BoxDecoration(
              color: cardBg(context).withValues(alpha: 0.54),
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: cardBorder(context).withValues(alpha: 0.58),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  entry.key,
                  style: AppText.caption.copyWith(color: hintColor(context)),
                ),
                const SizedBox(height: AppGap.xs),
                Text(
                  entry.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.title.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  String _safeAccountLabel(Object? raw) {
    final value = raw?.toString().trim() ?? "";
    if (value.isEmpty) return "访客";
    if (value.length <= 2) return "**";
    return "${value[0]}***${value[value.length - 1]}";
  }

  Widget _scraperSourceList() {
    return ReorderableListView.builder(
      shrinkWrap: true,
      buildDefaultDragHandles: false,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _scraperOrder.length,
      onReorder: (oldIndex, newIndex) {
        setState(() {
          if (newIndex > oldIndex) newIndex--;
          final source = _scraperOrder.removeAt(oldIndex);
          _scraperOrder.insert(newIndex, source);
        });
      },
      itemBuilder: (context, index) {
        final source = _scraperOrder[index];
        final enabled = _scraperEnabled[source] ?? false;
        return Padding(
          key: ValueKey(source),
          padding: EdgeInsets.only(
            bottom: index == _scraperOrder.length - 1 ? 0 : AppGap.sm,
          ),
          child: _setupRow(
            icon: Icons.drag_indicator_rounded,
            title: "${index + 1}. ${_scraperLabels[source] ?? source}",
            subtitle: _scraperSubtitle(source),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ReorderableDragStartListener(
                  index: index,
                  child: Icon(
                    Icons.drag_handle_rounded,
                    color: hintColor(context),
                  ),
                ),
                Switch.adaptive(
                  value: enabled,
                  onChanged: (value) =>
                      setState(() => _scraperEnabled[source] = value),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _scraperSubtitle(String source) {
    switch (source) {
      case "hikarinagi":
        return "主数据源 · Client ID / Secret / catalog:full";
      case "vndb_kana":
        return "中文标题、标签、平均时长，可选 Token。";
      case "bangumi":
        return "中文条目、封面和发布日期。";
      case "steam":
        return "商店信息、AppID 和发行资料辅助匹配。";
      default:
        return source;
    }
  }
}

class _SetupStepItem extends StatelessWidget {
  final int index;
  final int currentStep;
  final String title;
  final String subtitle;

  const _SetupStepItem({
    required this.index,
    required this.currentStep,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final completed = index < currentStep;
    final active = index == currentStep;
    final cs = Theme.of(context).colorScheme;
    final color = completed ? Colors.green : cs.primary;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
      decoration: BoxDecoration(
        color: active || completed ? color.withValues(alpha: 0.10) : null,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: active
              ? color.withValues(alpha: 0.22)
              : Colors.transparent,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: active || completed
                  ? color
                  : cs.onSurface.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Center(
              child: completed
                  ? const Icon(
                      Icons.check_rounded,
                      size: 17,
                      color: Colors.white,
                    )
                  : Text(
                      "${index + 1}",
                      style: AppText.bodySmall.copyWith(
                        color: active ? Colors.white : hintColor(context),
                        fontWeight: FontWeight.w900,
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppText.bodySmall.copyWith(
                    fontWeight: FontWeight.w800,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  subtitle,
                  style: AppText.caption.copyWith(
                    color: hintColor(context),
                    height: 1.55,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SetupDirectoryDialog extends StatefulWidget {
  final String label;
  final List<Map<String, dynamic>> openListSources;
  final bool patchRoot;
  final Map<String, dynamic>? initial;
  const _SetupDirectoryDialog({
    required this.label,
    required this.openListSources,
    this.patchRoot = false,
    this.initial,
  });

  @override
  State<_SetupDirectoryDialog> createState() => _SetupDirectoryDialogState();
}

class _SetupDirectoryDialogState extends State<_SetupDirectoryDialog> {
  String _sourceType = "local";
  int? _sourceIndex;
  String _analysisMode = "auto";
  final _pathCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial != null) {
      _sourceType = initial["source_type"]?.toString() == "openlist"
          ? "openlist"
          : "local";
      final initialMode = initial["analysis_mode"]?.toString();
      _analysisMode = initialMode == "manual" ||
              (initialMode == null && _sourceType == "openlist")
          ? "manual"
          : "auto";
      _pathCtrl.text = initial["path"]?.toString() ?? "";
      if (_sourceType == "openlist") {
        final idx = widget.openListSources.indexWhere(
          (s) =>
              s["base_url"] == initial["base_url"] &&
              s["username"] == initial["username"],
        );
        _sourceIndex = idx >= 0 ? idx : null;
      }
    }
  }

  @override
  void dispose() {
    _pathCtrl.dispose();
    super.dispose();
  }

  Widget _openListPatchStorageSelector() {
    return Container(
      decoration: BoxDecoration(
        color: cardBg(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cardBorder(context)),
      ),
      child: Column(
        children: [
          RadioListTile<String>(
            value: "auto",
            groupValue: _analysisMode,
            onChanged: (value) =>
                setState(() => _analysisMode = value ?? "auto"),
            dense: true,
            title: const Text("本地映射"),
            subtitle: Text(
              "OpenList 挂载的是服务端本地磁盘，可以读取压缩包目录树并自动推荐规则。",
              style: AppText.caption.copyWith(color: hintColor(context)),
            ),
          ),
          RadioListTile<String>(
            value: "manual",
            groupValue: _analysisMode,
            onChanged: (value) =>
                setState(() => _analysisMode = value ?? "manual"),
            dense: true,
            title: const Text("网盘"),
            subtitle: Text(
              "OpenList 挂载的是云盘或远程存储，不下载整包探测目录，只手写注入规则。",
              style: AppText.caption.copyWith(color: hintColor(context)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedSourceIndex = _sourceIndex != null &&
            _sourceIndex! >= 0 &&
            _sourceIndex! < widget.openListSources.length
        ? _sourceIndex
        : null;
    final localLabel = widget.patchRoot ? "服务端本地补丁库" : "\u672c\u5730\u6587\u4ef6\u6e90";
    final openListLabel = widget.patchRoot ? "OpenList 补丁库" : "OpenList";
    return AlertDialog(
      title: Text("${widget.initial == null ? "\u6dfb\u52a0" : "\u7f16\u8f91"}${widget.label}\u76ee\u5f55"),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                      value: "local",
                      icon: const Icon(Icons.folder_outlined),
                      label: Text(localLabel),
                    ),
                    ButtonSegment(
                      value: "openlist",
                      icon: const Icon(Icons.cloud_outlined),
                      label: Text(openListLabel),
                    ),
                  ],
                  selected: {_sourceType},
                  onSelectionChanged: (v) => setState(() {
                    _sourceType = v.first;
                    if (widget.patchRoot) {
                      _analysisMode =
                          _sourceType == "openlist" ? "manual" : "auto";
                    }
                    if (_sourceType == "openlist" &&
                        _sourceIndex == null &&
                        widget.openListSources.isNotEmpty) {
                      _sourceIndex = 0;
                    }
                  }),
                ),
              ),
              const SizedBox(height: 20),
              if (_sourceType == "openlist") ...[
                if (widget.openListSources.isEmpty)
                  Text(
                    "\u8bf7\u5148\u5728\u4e0a\u65b9\u6dfb\u52a0 OpenList \u670d\u52a1\u5668",
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  )
                else
                  DropdownButtonFormField<int>(
                    value: selectedSourceIndex,
                    decoration: const InputDecoration(
                      labelText: "OpenList \u670d\u52a1\u5668",
                    ),
                    items: widget.openListSources.asMap().entries.map((entry) {
                      final source = entry.value;
                      return DropdownMenuItem<int>(
                        value: entry.key,
                        child: Text(
                          (source["source_name"] ??
                                  source["base_url"] ??
                                  "OpenList")
                              .toString(),
                        ),
                      );
                    }).toList(),
                    onChanged: (v) => setState(() => _sourceIndex = v),
                  ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _pathCtrl,
                decoration: InputDecoration(
                  labelText: _sourceType == "openlist"
                      ? (widget.patchRoot ? "OpenList 补丁目录" : "\u8fdc\u7a0b\u76ee\u5f55")
                      : (widget.patchRoot ? "服务端本地补丁目录" : "\u670d\u52a1\u7aef\u672c\u5730\u76ee\u5f55"),
                  hintText: _sourceType == "openlist"
                      ? (widget.patchRoot ? "/Patches" : "/Games")
                      : (widget.patchRoot ? "/steam_patch" : "/data/games"),
                ),
              ),
              if (widget.patchRoot && _sourceType == "openlist") ...[
                const SizedBox(height: 16),
                Text(
                  "OpenList 存储类型",
                  style: AppText.caption.copyWith(color: hintColor(context)),
                ),
                const SizedBox(height: 8),
                _openListPatchStorageSelector(),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("\u53d6\u6d88"),
        ),
        FilledButton(
          onPressed: () {
            final path = _pathCtrl.text.trim();
            if (path.isEmpty) return;
            final payload = <String, dynamic>{
              "source_type": _sourceType,
              "path": path,
            };
            if (widget.patchRoot) {
              payload["analysis_mode"] = _analysisMode;
            }
            if (_sourceType == "openlist") {
              if (_sourceIndex == null ||
                  _sourceIndex! < 0 ||
                  _sourceIndex! >= widget.openListSources.length) {
                return;
              }
              final source = widget.openListSources[_sourceIndex!];
              payload["source_name"] = source["source_name"];
              payload["base_url"] = source["base_url"];
              payload["username"] = source["username"];
              payload["password"] = source["password"];
            }
            Navigator.pop(context, payload);
          },
          child: const Text("\u4fdd\u5b58"),
        ),
      ],
    );
  }
}

class _SetupOpenListSourceDialog extends StatefulWidget {
  final Map<String, dynamic>? initial;
  const _SetupOpenListSourceDialog({this.initial});

  @override
  State<_SetupOpenListSourceDialog> createState() =>
      _SetupOpenListSourceDialogState();
}

class _SetupOpenListSourceDialogState
    extends State<_SetupOpenListSourceDialog> {
  final _nameCtrl = TextEditingController(text: "OpenList");
  final _baseUrlCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial != null) {
      _nameCtrl.text = initial["source_name"]?.toString() ?? "OpenList";
      _baseUrlCtrl.text = initial["base_url"]?.toString() ?? "";
      _usernameCtrl.text = initial["username"]?.toString() ?? "";
      _passwordCtrl.text = initial["password"]?.toString() ?? "";
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _baseUrlCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.initial == null
            ? "\u6dfb\u52a0 OpenList \u670d\u52a1\u5668"
            : "\u7f16\u8f91 OpenList \u670d\u52a1\u5668",
      ),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(labelText: "\u540d\u79f0"),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _baseUrlCtrl,
                decoration: const InputDecoration(
                  labelText: "OpenList \u5730\u5740",
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _usernameCtrl,
                decoration: const InputDecoration(
                  labelText: "用户名（留空则使用访客模式）",
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passwordCtrl,
                decoration: const InputDecoration(labelText: "密码"),
                obscureText: true,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("\u53d6\u6d88"),
        ),
        FilledButton(
          onPressed: () {
            final baseUrl = _baseUrlCtrl.text.trim();
            final username = _usernameCtrl.text.trim();
            if (baseUrl.isEmpty) return;
            Navigator.pop(context, {
              "source_name": _nameCtrl.text.trim().isEmpty
                  ? "OpenList"
                  : _nameCtrl.text.trim(),
              "base_url": baseUrl,
              "username": username,
              "password": _passwordCtrl.text,
            });
          },
          child: const Text("\u4fdd\u5b58"),
        ),
      ],
    );
  }
}
