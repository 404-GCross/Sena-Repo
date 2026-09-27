/// Platform category management (admin) — custom categories and detection rules.

import "package:flutter/material.dart";

import "../models/game.dart";
import "../services/api_client.dart";
import "../utils/theme_utils.dart";
import "../widgets/app_shell.dart";

void _showToast(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: error ? Colors.red.shade700 : null,
    ),
  );
}

class PlatformCategoriesScreen extends StatefulWidget {
  final ApiClient api;

  const PlatformCategoriesScreen({super.key, required this.api});

  @override
  State<PlatformCategoriesScreen> createState() =>
      _PlatformCategoriesScreenState();
}

class _PlatformCategoriesScreenState extends State<PlatformCategoriesScreen> {
  List<PlatformCategory> _categories = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  List<PlatformCategory> get _custom =>
      _categories.where((category) => !category.isSystem).toList();

  List<PlatformCategory> get _system =>
      _categories.where((category) => category.isSystem).toList();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final categories = await widget.api.getPlatformCategories();
      if (!mounted) return;
      setState(() {
        _categories = categories;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<String?> _promptName({required String title, String? initial}) {
    final controller = TextEditingController(text: initial ?? "");
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 32,
          decoration: const InputDecoration(
            labelText: "分类名",
            hintText: "例如 Switch、PSP、模拟器",
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text("保存"),
          ),
        ],
      ),
    );
  }

  Future<void> _addCategory() async {
    final name = await _promptName(title: "添加分类");
    final value = name?.trim() ?? "";
    if (value.isEmpty) return;
    try {
      await widget.api.createPlatformCategory(value);
      await _load();
      if (mounted) _showToast(context, "已添加分类「$value」");
    } catch (e) {
      if (mounted) _showToast(context, "添加失败: $e", error: true);
    }
  }

  Future<void> _renameCategory(PlatformCategory category) async {
    final name = await _promptName(title: "重命名分类", initial: category.name);
    final value = name?.trim() ?? "";
    if (value.isEmpty || value == category.name) return;
    try {
      await widget.api.updatePlatformCategory(category.id, name: value);
      await _load();
      if (mounted) _showToast(context, "已重命名为「$value」");
    } catch (e) {
      if (mounted) _showToast(context, "重命名失败: $e", error: true);
    }
  }

  Future<void> _deleteCategory(PlatformCategory category) async {
    int? reassignTo;
    if (category.versionCount > 0) {
      final targets = _categories.where((c) => c.id != category.id).toList();
      reassignTo = await showDialog<int>(
        context: context,
        builder: (ctx) {
          int? selected = targets.isEmpty ? null : targets.first.id;
          return StatefulBuilder(
            builder: (ctx, setDialogState) => AlertDialog(
              title: const Text("删除分类"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "还有 ${category.versionCount} 个版本使用「${category.name}」，"
                    "请选择替代分类：",
                  ),
                  const SizedBox(height: 12),
                  DropdownButton<int>(
                    value: selected,
                    isExpanded: true,
                    items: [
                      for (final target in targets)
                        DropdownMenuItem(
                          value: target.id,
                          child: Text(target.name),
                        ),
                    ],
                    onChanged: (value) => setDialogState(() => selected = value),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("取消"),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: selected == null
                      ? null
                      : () => Navigator.pop(ctx, selected),
                  child: const Text("删除并转移"),
                ),
              ],
            ),
          );
        },
      );
      if (reassignTo == null) return;
    } else {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text("删除分类"),
          content: Text("确定删除分类「${category.name}」？"),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("取消"),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("删除"),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    try {
      final message = await widget.api
          .deletePlatformCategory(category.id, reassignToId: reassignTo);
      await _load();
      if (mounted) _showToast(context, message);
    } catch (e) {
      if (mounted) _showToast(context, "删除失败: $e", error: true);
    }
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    final list = List<PlatformCategory>.from(_custom);
    if (newIndex > oldIndex) newIndex -= 1;
    final moved = list.removeAt(oldIndex);
    list.insert(newIndex, moved);
    setState(() => _categories = [...list, ..._system]);
    try {
      await widget.api.reorderPlatformCategories(
          list.map((category) => category.id).toList());
      await _load();
    } catch (e) {
      if (mounted) _showToast(context, "保存顺序失败: $e", error: true);
      await _load();
    }
  }

  Future<void> _openRules(PlatformCategory category) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            PlatformRulesScreen(api: widget.api, category: category),
      ),
    );
    await _load();
  }

  Future<void> _reidentify() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("重新识别分类"),
        content: const Text(
          "会按当前规则重新识别所有版本，手动修改过的分类也会被覆盖。确定继续？",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("开始"),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final message = await widget.api.reidentifyPlatformCategories();
      await _load();
      if (mounted) _showToast(context, message);
    } catch (e) {
      if (mounted) _showToast(context, "重新识别失败: $e", error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackdrop(
        child: Column(
          children: [
            AppPageHeader(
              showBack: true,
              leading: const Icon(Icons.category_outlined, size: 26),
              title: "分类管理",
              subtitle: "自定义平台分类与识别规则",
              onBack: () => Navigator.pop(context),
            ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addCategory,
        icon: const Icon(Icons.add),
        label: const Text("添加分类"),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("加载分类失败", style: AppText.title),
            const SizedBox(height: 8),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: AppText.bodySmall.copyWith(color: subTextColor(context)),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text("重试")),
          ],
        ),
      );
    }
    return ReorderableListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      buildDefaultDragHandles: false,
      header: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          "列表顺序就是扫描匹配优先级：从上到下，首个命中的规则决定分类。"
          "点分类可编辑匹配规则。",
          style: AppText.bodySmall.copyWith(color: subTextColor(context)),
        ),
      ),
      footer: _footer(),
      onReorder: _reorder,
      children: [
        for (var index = 0; index < _custom.length; index++)
          _categoryCard(_custom[index], index,
              key: ValueKey(_custom[index].id)),
      ],
    );
  }

  Widget _footer() {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final category in _system) _systemCard(category),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _reidentify,
            icon: const Icon(Icons.published_with_changes),
            label: const Text("按规则重新识别全部分类"),
          ),
          const SizedBox(height: 6),
          Text(
            "会用当前规则重刷所有版本，手动改过的分类也会被覆盖。",
            style: AppText.bodySmall.copyWith(color: subTextColor(context)),
          ),
        ],
      ),
    );
  }

  Widget _categoryCard(PlatformCategory category, int index,
      {required Key key}) {
    return Card(
      key: key,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: ReorderableDragStartListener(
          index: index,
          child: const Icon(Icons.drag_indicator),
        ),
        title: Text(
          category.name,
          style: AppText.body.copyWith(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          "${category.versionCount} 个版本 · ${category.rules.length} 条规则",
          style: AppText.bodySmall.copyWith(color: subTextColor(context)),
        ),
        onTap: () => _openRules(category),
        trailing: PopupMenuButton<String>(
          tooltip: "更多",
          onSelected: (action) {
            if (action == "rules") {
              _openRules(category);
            } else if (action == "rename") {
              _renameCategory(category);
            } else if (action == "delete") {
              _deleteCategory(category);
            }
          },
          itemBuilder: (ctx) => const [
            PopupMenuItem(value: "rules", child: Text("匹配规则")),
            PopupMenuItem(value: "rename", child: Text("重命名")),
            PopupMenuItem(
              value: "delete",
              child: Text("删除", style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _systemCard(PlatformCategory category) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(Icons.help_outline, color: hintColor(context)),
        title: Text(category.name),
        subtitle: Text(
          "${category.versionCount} 个版本 · 未命中任何规则的文件会归到这里",
          style: AppText.bodySmall.copyWith(color: subTextColor(context)),
        ),
        trailing: Chip(
          label: const Text("系统"),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}

class PlatformRulesScreen extends StatefulWidget {
  final ApiClient api;
  final PlatformCategory category;

  const PlatformRulesScreen({
    super.key,
    required this.api,
    required this.category,
  });

  @override
  State<PlatformRulesScreen> createState() => _PlatformRulesScreenState();
}

class _PlatformRulesScreenState extends State<PlatformRulesScreen> {
  List<PlatformCategoryRule> _rules = [];
  bool _loading = true;
  String? _error;
  final _testController = TextEditingController();
  String? _testResult;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _testController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final categories = await widget.api.getPlatformCategories();
      var current = widget.category;
      for (final category in categories) {
        if (category.id == widget.category.id) current = category;
      }
      if (!mounted) return;
      setState(() {
        _rules = current.rules;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<(String, String)?> _ruleDialog({PlatformCategoryRule? rule}) {
    var kind = rule?.kind ?? "keyword";
    final controller = TextEditingController(text: rule?.pattern ?? "");
    return showDialog<(String, String)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(rule == null ? "添加匹配规则" : "编辑匹配规则"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: "keyword", label: Text("关键词")),
                    ButtonSegment(value: "regex", label: Text("正则")),
                  ],
                  selected: {kind},
                  onSelectionChanged: (selection) =>
                      setDialogState(() => kind = selection.first),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: kind == "keyword" ? "包含的关键词" : "正则表达式",
                    hintText:
                        kind == "keyword" ? "例如 switch" : r"例如 \[Switch\]",
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  kind == "keyword"
                      ? "文件名包含这个词（不区分大小写）就归到该分类"
                      : "对完整文件名做正则搜索（不区分大小写）",
                  style:
                      AppText.bodySmall.copyWith(color: subTextColor(context)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("取消"),
            ),
            FilledButton(
              onPressed: () {
                final pattern = controller.text.trim();
                if (pattern.isEmpty) return;
                Navigator.pop(ctx, (kind, pattern));
              },
              child: const Text("保存"),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addRule() async {
    final result = await _ruleDialog();
    if (result == null) return;
    try {
      await widget.api
          .createPlatformRule(widget.category.id, result.$1, result.$2);
      await _load();
      if (mounted) _showToast(context, "已添加规则");
    } catch (e) {
      if (mounted) _showToast(context, "添加失败: $e", error: true);
    }
  }

  Future<void> _editRule(PlatformCategoryRule rule) async {
    final result = await _ruleDialog(rule: rule);
    if (result == null) return;
    try {
      await widget.api.updatePlatformRule(
        widget.category.id,
        rule.id,
        kind: result.$1,
        pattern: result.$2,
      );
      await _load();
      if (mounted) _showToast(context, "已更新规则");
    } catch (e) {
      if (mounted) _showToast(context, "更新失败: $e", error: true);
    }
  }

  Future<void> _deleteRule(PlatformCategoryRule rule) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("删除规则"),
        content: Text("确定删除规则「${rule.pattern}」？"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("取消"),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("删除"),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.api.deletePlatformRule(widget.category.id, rule.id);
      await _load();
      if (mounted) _showToast(context, "规则已删除");
    } catch (e) {
      if (mounted) _showToast(context, "删除失败: $e", error: true);
    }
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    final list = List<PlatformCategoryRule>.from(_rules);
    if (newIndex > oldIndex) newIndex -= 1;
    final moved = list.removeAt(oldIndex);
    list.insert(newIndex, moved);
    setState(() => _rules = list);
    try {
      await widget.api.reorderPlatformRules(
          widget.category.id, list.map((rule) => rule.id).toList());
      await _load();
    } catch (e) {
      if (mounted) _showToast(context, "保存顺序失败: $e", error: true);
      await _load();
    }
  }

  Future<void> _test() async {
    final filename = _testController.text.trim();
    if (filename.isEmpty) return;
    try {
      final category = await widget.api.testPlatformMatch(filename);
      if (!mounted) return;
      setState(() => _testResult = "命中分类：$category");
    } catch (e) {
      if (!mounted) return;
      setState(() => _testResult = "测试失败: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackdrop(
        child: Column(
          children: [
            AppPageHeader(
              showBack: true,
              leading: const Icon(Icons.rule, size: 26),
              title: "${widget.category.name} · 匹配规则",
              subtitle: "按顺序匹配，首个命中的规则决定分类",
              onBack: () => Navigator.pop(context),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _testController,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: "测试文件名",
                        hintText: "例如 [Switch]Game.zip",
                      ),
                      onSubmitted: (_) => _test(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _test, child: const Text("测试")),
                ],
              ),
            ),
            if (_testResult != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _testResult!,
                    style: AppText.bodySmall.copyWith(
                      color: subTextColor(context),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addRule,
        icon: const Icon(Icons.add),
        label: const Text("添加规则"),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("加载规则失败", style: AppText.title),
            const SizedBox(height: 8),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: AppText.bodySmall.copyWith(color: subTextColor(context)),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text("重试")),
          ],
        ),
      );
    }
    if (_rules.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            "还没有规则，点右下角添加；不匹配任何规则的文件会归到「未分类」。",
            textAlign: TextAlign.center,
            style: AppText.bodySmall.copyWith(color: subTextColor(context)),
          ),
        ),
      );
    }
    return ReorderableListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      buildDefaultDragHandles: false,
      onReorder: _reorder,
      children: [
        for (var index = 0; index < _rules.length; index++)
          _ruleCard(_rules[index], index, key: ValueKey(_rules[index].id)),
      ],
    );
  }

  Widget _ruleCard(PlatformCategoryRule rule, int index, {required Key key}) {
    return Card(
      key: key,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: ReorderableDragStartListener(
          index: index,
          child: const Icon(Icons.drag_indicator),
        ),
        title: Text(rule.pattern),
        subtitle: Text(rule.kind == "regex" ? "正则" : "关键词"),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: "编辑",
              icon: const Icon(Icons.edit_outlined, size: 20),
              onPressed: () => _editRule(rule),
            ),
            IconButton(
              tooltip: "删除",
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () => _deleteRule(rule),
            ),
          ],
        ),
      ),
    );
  }
}
