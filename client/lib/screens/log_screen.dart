// Client log viewer with searchable, structured log records.

import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:file_picker/file_picker.dart";
import "package:flutter/material.dart";
import "package:flutter/services.dart";

import "../services/logger_service.dart";
import "../utils/theme_utils.dart";
import "../widgets/app_shell.dart";

class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  static const int _initialVisibleLimit = 80;
  static const int _loadMoreStep = 80;

  final _searchController = TextEditingController();
  final _logger = LoggerService();

  List<File> _files = const [];
  List<LogRecord> _entries = const [];
  File? _selectedFile;
  String _level = "全部";
  String _module = "全部模块";
  bool _loading = true;
  bool _live = true;
  bool _mobileFiltersExpanded = false;
  int _visibleLimit = _initialVisibleLimit;
  Timer? _liveTimer;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onFilterChanged);
    _load();
    _startLiveRefresh();
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    _searchController
      ..removeListener(_onFilterChanged)
      ..dispose();
    super.dispose();
  }

  void _onFilterChanged() => setState(() {
        _visibleLimit = _initialVisibleLimit;
      });

  void _startLiveRefresh() {
    _liveTimer?.cancel();
    if (!_live) return;
    _liveTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (mounted && !_loading) _load(quiet: true);
    });
  }

  Future<void> _load({bool quiet = false}) async {
    if (!quiet && mounted) setState(() => _loading = true);
    final files = await _logger.getLogFiles();
    if (!mounted) return;

    File? selected;
    if (_selectedFile != null) {
      for (final file in files) {
        if (file.path == _selectedFile!.path) selected = file;
      }
    }
    selected ??= files.isEmpty ? null : files.first;
    final entries = selected == null
        ? <LogRecord>[]
        : await _logger.readLogEntries(selected);
    if (!mounted) return;
    setState(() {
      _files = files;
      _selectedFile = selected;
      _entries = entries;
      _loading = false;
    });
  }

  Future<void> _selectFile(File file) async {
    setState(() {
      _selectedFile = file;
      _entries = const [];
      _loading = true;
    });
    final entries = await _logger.readLogEntries(file);
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
      _level = "全部";
      _module = "全部模块";
      _visibleLimit = _initialVisibleLimit;
      _searchController.clear();
    });
  }

  List<LogRecord> get _filteredEntries {
    final query = _searchController.text.trim().toLowerCase();
    return _entries.where((entry) {
      final levelMatch = _level == "全部" || entry.level == _level;
      final moduleMatch = _module == "全部模块" || entry.module == _module;
      final queryMatch =
          query.isEmpty || entry.raw.toLowerCase().contains(query);
      return levelMatch && moduleMatch && queryMatch;
    }).toList();
  }

  int _count(String level) =>
      _entries.where((entry) => entry.level == level).length;

  List<String> get _modules {
    final values = _entries.map((entry) => entry.module).toSet().toList()
      ..sort();
    return ["全部模块", ...values];
  }

  Future<void> _copyVisibleLogs() async {
    final text = _filteredEntries.reversed.map((entry) => entry.raw).join("\n");
    if (text.isEmpty) {
      _message("当前没有可复制的日志");
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _message("已复制 ${_filteredEntries.length} 条日志");
  }

  Future<void> _exportLogs() async {
    final visible = _filteredEntries.reversed.toList();
    if (visible.isEmpty) {
      _message("当前没有可导出的日志");
      return;
    }
    final original = _selectedFile?.uri.pathSegments.last ?? "sena.log";
    final name = original.endsWith(".log")
        ? original.substring(0, original.length - 4)
        : original;
    final content = "${visible.map((entry) => entry.raw).join("\n")}\n";
    if (Platform.isAndroid || Platform.isIOS) {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: "导出日志",
        fileName: "${name}_filtered.log",
        type: FileType.custom,
        allowedExtensions: ["log", "txt"],
        bytes: Uint8List.fromList(utf8.encode(content)),
      );
      if (path == null || path.isEmpty) return;
      _message("日志已导出");
      return;
    }
    final path = await FilePicker.platform.saveFile(
      dialogTitle: "导出日志",
      fileName: "${name}_filtered.log",
      type: FileType.custom,
      allowedExtensions: ["log", "txt"],
    );
    if (path == null || path.isEmpty) return;
    try {
      await File(path).writeAsString(content);
      _message("日志已导出");
    } catch (e) {
      _message("导出失败: $e");
    }
  }

  Future<void> _cleanOldLogs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("清理旧日志"),
        content: const Text("删除 7 天前的客户端日志，当前日志不会受到影响。"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text("清理"),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _logger.cleanOldLogs();
    await _load();
    _message("旧日志已清理");
  }

  void _toggleLive(bool value) {
    setState(() => _live = value);
    _startLiveRefresh();
  }

  void _loadEarlierEntries() {
    setState(() => _visibleLimit += _loadMoreStep);
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: "日志",
      subtitle: "查看客户端运行记录和错误信息",
      leading: const Icon(Icons.article_outlined, size: 24),
      actions: [
        AppActionButton(
          icon: Icons.copy_all_outlined,
          label: "复制",
          onPressed: _entries.isEmpty ? null : _copyVisibleLogs,
        ),
        AppActionButton(
          icon: Icons.file_download_outlined,
          label: "导出",
          onPressed: _entries.isEmpty ? null : _exportLogs,
        ),
        AppActionButton(
          icon: Icons.refresh_rounded,
          label: "刷新",
          onPressed: _loading ? null : () => _load(),
          busy: _loading,
        ),
      ],
      scrollable: false,
      child: _loading && _files.isEmpty
          ? const AppStateView.loading(title: "正在读取日志")
          : _files.isEmpty
              ? AppStateView(
                  icon: Icons.article_outlined,
                  title: "暂无日志",
                  message: "当前设备还没有生成可查看的客户端日志",
                  action: AppActionButton(
                    icon: Icons.refresh_rounded,
                    label: "重新读取",
                    onPressed: _load,
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final isDesktop = constraints.maxWidth >= 760;
                    if (!isDesktop) return _buildMobilePage();

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildHeading(),
                        const SizedBox(height: 14),
                        _buildMetrics(constraints.maxWidth),
                        const SizedBox(height: 14),
                        _buildToolbar(constraints.maxWidth),
                        const SizedBox(height: 14),
                        Expanded(child: _buildDesktopLogView()),
                      ],
                    );
                  },
                ),
    );
  }

  Widget _buildMobilePage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildMobileHeader(),
        const SizedBox(height: 8),
        _buildMobileToolbar(),
        const SizedBox(height: 8),
        Expanded(child: _buildMobileLogView()),
      ],
    );
  }

  Widget _buildMobileHeader() {
    final cs = Theme.of(context).colorScheme;
    final summary =
        "${_entries.length} 条 · INFO ${_count("INFO")} · WARN ${_count("WARN")} · ERROR ${_count("ERROR")}";
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: cs.primary.withValues(alpha: 0.11),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Icon(Icons.article_outlined, size: 18, color: cs.primary),
        ),
        const SizedBox(width: AppGap.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("日志", style: AppText.title.copyWith(fontSize: 20)),
              Text(
                summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(color: hintColor(context)),
              ),
            ],
          ),
        ),
        TextButton.icon(
          onPressed: () => setState(
            () => _mobileFiltersExpanded = !_mobileFiltersExpanded,
          ),
          icon: Icon(
            _mobileFiltersExpanded
                ? Icons.keyboard_arrow_up_rounded
                : Icons.tune_rounded,
            size: 19,
          ),
          label: Text(_mobileFiltersExpanded ? "收起" : "筛选"),
        ),
      ],
    );
  }

  Widget _buildMobileToolbar() {
    final levels = ["全部", "INFO", "WARN", "ERROR"];
    return AppSurface(
      radius: AppRadius.md,
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _searchController,
            decoration: const InputDecoration(
              hintText: "搜索日志内容、地址或请求 ID",
              prefixIcon: Icon(Icons.search_rounded, size: 19),
              isDense: true,
            ),
          ),
          if (_mobileFiltersExpanded) ...[
            const SizedBox(height: 8),
            _buildDropdown(
              value: _module,
              items: _modules,
              onChanged: (value) => setState(() {
                _module = value!;
                _visibleLimit = _initialVisibleLimit;
              }),
              icon: Icons.category_outlined,
              width: double.infinity,
            ),
            const SizedBox(height: 8),
            _buildMobileLevelChips(levels),
            const SizedBox(height: 4),
            Row(
              children: [
                Switch.adaptive(value: _live, onChanged: _toggleLive),
                Text(
                  "实时跟随",
                  style: AppText.caption.copyWith(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                IconButton(
                  tooltip: "清空筛选",
                  onPressed: () {
                    _searchController.clear();
                    setState(() {
                      _level = "全部";
                      _module = "全部模块";
                      _visibleLimit = _initialVisibleLimit;
                    });
                  },
                  icon: const Icon(Icons.filter_alt_off_outlined, size: 19),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHeading() {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: cs.primary.withValues(alpha: 0.11),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Icon(Icons.article_outlined, size: 18, color: cs.primary),
        ),
        const SizedBox(width: AppGap.md),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("日志", style: AppText.title.copyWith(fontSize: 21)),
            Text("查看客户端运行记录和错误信息",
                style: AppText.caption.copyWith(color: hintColor(context))),
          ],
        ),
      ],
    );
  }

  Widget _buildMetrics(double width) {
    final cards = [
      _MetricData(
          "全部记录", _entries.length, Icons.article_outlined, Colors.indigo),
      _MetricData("信息", _count("INFO"), Icons.info_outline, Colors.teal),
      _MetricData(
          "警告", _count("WARN"), Icons.warning_amber_outlined, Colors.orange),
      _MetricData("错误", _count("ERROR"), Icons.error_outline, Colors.red),
    ];
    return SizedBox(
      height: 82,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: cards.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, index) => SizedBox(
          width: width < 560 ? 152 : (width - 30) / 4,
          child: AppMetricCard(
            label: cards[index].label,
            value: cards[index].value.toString(),
            icon: cards[index].icon,
            color: cards[index].color,
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar(double width) {
    final levels = ["全部", "INFO", "WARN", "ERROR"];
    return AppSurface(
      radius: AppRadius.md,
      padding: const EdgeInsets.all(10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: width >= 760 ? 300 : width - 52,
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: "搜索日志内容、地址或请求 ID",
                prefixIcon: Icon(Icons.search_rounded, size: 19),
                isDense: true,
              ),
            ),
          ),
          _buildDropdown(
            value: _module,
            items: _modules,
            onChanged: (value) => setState(() {
              _module = value!;
              _visibleLimit = _initialVisibleLimit;
            }),
            icon: Icons.category_outlined,
            width: width >= 760 ? 132 : 150,
          ),
          _buildLevelChips(levels),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Switch.adaptive(value: _live, onChanged: _toggleLive),
              Text("实时跟随",
                  style: AppText.caption.copyWith(fontWeight: FontWeight.w700)),
            ],
          ),
          IconButton(
            tooltip: "清空筛选",
            onPressed: () {
              _searchController.clear();
              setState(() {
                _level = "全部";
                _module = "全部模块";
                _visibleLimit = _initialVisibleLimit;
              });
            },
            icon: const Icon(Icons.filter_alt_off_outlined, size: 19),
          ),
        ],
      ),
    );
  }

  Widget _buildDropdown({
    required String value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
    required IconData icon,
    required double width,
  }) {
    return SizedBox(
      width: width,
      child: DropdownButtonFormField<String>(
        initialValue: value,
        isDense: true,
        decoration: InputDecoration(prefixIcon: Icon(icon, size: 18)),
        items: items
            .map((item) => DropdownMenuItem(value: item, child: Text(item)))
            .toList(),
        onChanged: onChanged,
      ),
    );
  }

  Widget _buildLevelChips(List<String> levels) {
    return Wrap(
      spacing: 4,
      children: levels
          .map(
            (level) => FilterChip(
              label: Text(level),
              selected: _level == level,
              onSelected: (_) => setState(() {
                _level = level;
                _visibleLimit = _initialVisibleLimit;
              }),
              visualDensity: VisualDensity.compact,
              showCheckmark: false,
            ),
          )
          .toList(),
    );
  }

  Widget _buildMobileLevelChips(List<String> levels) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: levels
            .map(
              (level) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: FilterChip(
                  label: Text(level),
                  selected: _level == level,
                  onSelected: (_) => setState(() {
                    _level = level;
                    _visibleLimit = _initialVisibleLimit;
                  }),
                  visualDensity: VisualDensity.compact,
                  showCheckmark: false,
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  Widget _buildDesktopLogView() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 278, child: _buildFilePanel()),
        const SizedBox(width: 14),
        Expanded(child: _buildConsole()),
      ],
    );
  }

  Widget _buildMobileLogView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildMobileFilePicker(),
        const SizedBox(height: 10),
        Expanded(child: _buildConsole()),
      ],
    );
  }

  Widget _buildFilePanel() {
    return AppSurface(
      padding: const EdgeInsets.all(6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _panelHeader("日志文件", "7 天保留"),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              itemCount: _files.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, index) {
                final file = _files[index];
                final selected = file.path == _selectedFile?.path;
                return _LogFileTile(
                  file: file,
                  selected: selected,
                  entryCount: selected ? _entries.length : null,
                  onTap: () => _selectFile(file),
                );
              },
            ),
          ),
          const Divider(height: 1),
          _panelHeader("今日模块", "按记录数"),
          for (final module in ["连接", "扫描", "刮削", "下载"])
            _moduleRow(
                module, _entries.where((e) => e.module == module).length),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _cleanOldLogs,
              child: const Text("清理 7 天前的日志"),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileFilePicker() {
    return AppSurface(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<File>(
          value: _selectedFile,
          isExpanded: true,
          icon: const Icon(Icons.more_vert_rounded),
          items: _files
              .map(
                (file) => DropdownMenuItem(
                  value: file,
                  child: Text(
                    file.path.split(Platform.pathSeparator).last,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: (file) {
            if (file != null) _selectFile(file);
          },
        ),
      ),
    );
  }

  Widget _buildConsole() {
    final filtered = _filteredEntries;
    final visible = filtered.take(_visibleLimit).toList(growable: false);
    final hasMore = filtered.length > visible.length;
    return AppSurface(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildConsoleHeader(visible.length),
          const Divider(height: 1),
          Expanded(
            child: filtered.isEmpty
                ? const AppStateView(
                    icon: Icons.search_off_rounded,
                    title: "没有匹配的日志",
                    message: "尝试清空筛选条件或更换关键词",
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: visible.length,
                    separatorBuilder: (_, __) => Divider(
                      height: 1,
                      indent: 12,
                      endIndent: 12,
                      color: cardBorder(context).withValues(alpha: 0.42),
                    ),
                    itemBuilder: (_, index) => _LogRecordTile(
                      record: visible[index],
                      onTap: () => _showRecord(visible[index]),
                    ),
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  hasMore
                      ? "显示 ${visible.length} / ${filtered.length} 条记录"
                      : "显示 ${visible.length} 条记录",
                  style: AppText.caption,
                ),
                if (hasMore)
                  TextButton(
                    onPressed: _loadEarlierEntries,
                    child: const Text("加载更早记录"),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConsoleHeader(int visibleCount) {
    final name = _selectedFile?.path.split(Platform.pathSeparator).last ?? "日志";
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    AppText.bodyMedium.copyWith(fontWeight: FontWeight.w800)),
          ),
          AppStatusPill(
            icon: _live ? Icons.circle : Icons.pause_circle_outline,
            label: _live ? "实时" : "已暂停",
            color: _live ? Colors.teal : hintColor(context),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: "复制可见日志",
            onPressed: visibleCount == 0 ? null : _copyVisibleLogs,
            icon: const Icon(Icons.copy_all_outlined, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _panelHeader(String title, String trailing) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title,
              style: AppText.bodyMedium.copyWith(fontWeight: FontWeight.w800)),
          Text(trailing,
              style: AppText.caption.copyWith(color: hintColor(context))),
        ],
      ),
    );
  }

  Widget _moduleRow(String module, int count) {
    final colors = {
      "连接": Colors.blue,
      "扫描": Colors.teal,
      "刮削": Colors.pink,
      "下载": Colors.orange,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Row(
        children: [
          Container(
              width: 7,
              height: 7,
              decoration:
                  BoxDecoration(color: colors[module], shape: BoxShape.circle)),
          const SizedBox(width: 7),
          Expanded(child: Text(module, style: AppText.caption)),
          Text("$count",
              style: AppText.caption.copyWith(fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }

  Future<void> _showRecord(LogRecord record) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("日志详情", style: AppText.title),
              const SizedBox(height: 12),
              _detailRow(
                  "时间", record.timestamp?.toString() ?? record.timestampLabel),
              _detailRow("级别", record.level),
              _detailRow("模块", record.module),
              const SizedBox(height: 8),
              SelectableText(record.raw,
                  style: AppText.label.copyWith(fontFamily: "monospace")),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: record.raw));
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                  _message("日志内容已复制");
                },
                icon: const Icon(Icons.copy_outlined, size: 17),
                label: const Text("复制这条日志"),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 52,
              child: Text(label,
                  style: AppText.caption.copyWith(color: hintColor(context)))),
          Expanded(
              child: Text(value,
                  style:
                      AppText.bodySmall.copyWith(fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }
}

class _MetricData {
  final String label;
  final int value;
  final IconData icon;
  final Color color;

  const _MetricData(this.label, this.value, this.icon, this.color);
}

class _LogFileTile extends StatelessWidget {
  final File file;
  final bool selected;
  final int? entryCount;
  final VoidCallback onTap;

  const _LogFileTile({
    required this.file,
    required this.selected,
    required this.entryCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final name = file.path.split(Platform.pathSeparator).last;
    final base = Theme.of(context).colorScheme.primary;
    return Material(
      color: selected ? base.withValues(alpha: 0.10) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: base.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(Icons.description_outlined, size: 17, color: base),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.bodySmall
                            .copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 3),
                    Text(entryCount == null ? "历史日志" : "今天 · $entryCount 条",
                        style: AppText.caption
                            .copyWith(color: hintColor(context))),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LogRecordTile extends StatefulWidget {
  final LogRecord record;
  final VoidCallback onTap;

  const _LogRecordTile({required this.record, required this.onTap});

  @override
  State<_LogRecordTile> createState() => _LogRecordTileState();
}

class _LogRecordTileState extends State<_LogRecordTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final cs = Theme.of(context).colorScheme;
    final color = record.isError
        ? Colors.red
        : record.isWarn
            ? Colors.orange
            : Colors.teal;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: AppMotion.fast,
        curve: AppMotion.curve,
        decoration: BoxDecoration(
          color: _hovered
              ? cs.primary.withValues(alpha: 0.06)
              : Colors.transparent,
          border: Border(
              left: BorderSide(
                  color: _hovered ? cs.primary : Colors.transparent, width: 3)),
        ),
        child: InkWell(
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                    width: 66,
                    child: Text(record.timestampLabel,
                        style:
                            AppText.caption.copyWith(fontFamily: "monospace"))),
                SizedBox(
                    width: 52,
                    child: Align(
                        alignment: Alignment.topLeft,
                        child: _LevelBadge(level: record.level, color: color))),
                SizedBox(
                    width: 48,
                    child: Text(record.module, style: AppText.caption)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(record.message,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.bodySmall
                              .copyWith(fontWeight: FontWeight.w600)),
                      if (record.raw != record.message) ...[
                        const SizedBox(height: 3),
                        Text(
                            record.raw.contains(" | ")
                                ? record.raw.split(" | ").last
                                : "客户端运行记录",
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.caption
                                .copyWith(color: hintColor(context))),
                      ],
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded,
                    size: 19,
                    color: _hovered ? cs.primary : hintColor(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LevelBadge extends StatelessWidget {
  final String level;
  final Color color;

  const _LevelBadge({required this.level, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(level,
          style: AppText.caption.copyWith(
              color: color, fontSize: 10, fontWeight: FontWeight.w800)),
    );
  }
}
