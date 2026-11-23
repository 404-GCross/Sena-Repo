// Client log viewer with searchable, structured log records.

import "dart:async";
import "dart:convert";
import "dart:io";

import "package:file_picker/file_picker.dart";
import "package:flutter/material.dart";
import '../widgets/app_dialog.dart';
import "package:flutter/services.dart";
import "package:provider/provider.dart";

import "../models/log_models.dart";
import "../providers/game_provider.dart";
import "../services/api_client.dart";
import "../services/logger_service.dart";
import "../utils/theme_utils.dart";
import "../widgets/app_shell.dart";
import "../widgets/feedback_dialog.dart";

class LogScreen extends StatelessWidget {
  final LoggerService? logger;
  const LogScreen({super.key, this.logger});

  @override
  Widget build(BuildContext context) {
    final api = context.select<GameProvider, ApiClient>((p) => p.api);
    return ValueListenableBuilder<int>(
        valueListenable: logAccessChanges,
        builder: (_, __, ___) {
          final access = api.logViewerAccess;
          return _ScopedLogs(
              key: ValueKey((api, api.sessionScope, access)),
              api: api,
              scope: api.sessionScope,
              access: access,
              logger: logger ?? LoggerService());
        });
  }
}

class _ScopedLogs extends StatefulWidget {
  final ApiClient api;
  final (int, int) scope;
  final LogViewerAccess? access;
  final LoggerService logger;
  const _ScopedLogs(
      {super.key,
      required this.api,
      required this.scope,
      required this.access,
      required this.logger});

  @override
  State<_ScopedLogs> createState() => _LogScreenState();
}

class _LogScreenState extends State<_ScopedLogs> {
  static const int _initialVisibleLimit = 80;
  static const int _loadMoreStep = 80;

  final _searchController = TextEditingController();
  LoggerService get _logger => widget.logger;

  List<LogFileInfo> _files = const [];
  List<LogRecord> _entries = const [];
  LogFileInfo? _selectedFile;
  LogViewerAccess? get _access => widget.access;
  bool get _current =>
      mounted &&
      widget.scope == widget.api.sessionScope &&
      identical(_access, widget.api.logViewerAccess);
  int _request = 0;
  bool _reading = false;
  String? _error;
  String _level = "全部";
  String _module = "全部模块";
  bool _loading = true;
  bool _live = true;
  bool _mobileFiltersExpanded = false;
  int _visibleLimit = _initialVisibleLimit;
  int _readLimit = 500;
  Timer? _liveTimer;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onFilterChanged);
    _load(verify: _access == null);
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
      if (_current && !_reading && _access != null) _load(quiet: true);
    });
  }

  Future<void> _load(
      {bool quiet = false,
      bool verify = false,
      bool interactive = false,
      LogFileInfo? select}) async {
    if (!_current) return;
    final request = ++_request;
    _reading = true;
    if (!quiet) setState(() => _loading = true);
    try {
      if (verify) {
        if (widget.api.accessToken == null) await ApiClient.restoreToken();
        if (!_current || request != _request) return;
        await widget.api.refreshLogContext();
      }
      if (!_current || request != _request) return;
      final access = _access;
      if (access == null || !access.isUsable) return;
      final files = await _logger.listFiles(access);
      if (!_current || request != _request) return;

      LogFileInfo? selected;
      final wanted = select ?? _selectedFile;
      if (wanted != null) {
        for (final file in files) {
          if (file.path == wanted.path) selected = file;
        }
      }
      selected ??= files.isEmpty ? null : files.first;
      if (select != null) _readLimit = 500;
      var fresh = selected == null
          ? <LogRecord>[]
          : await _logger.readEntries(access, selected, limit: _readLimit);
      if (!_current || request != _request) return;
      if (wanted == null && fresh.isEmpty) {
        for (final file in files.skip(1)) {
          fresh = await _logger.readEntries(access, file, limit: _readLimit);
          if (!_current || request != _request) return;
          if (fresh.isNotEmpty) {
            selected = file;
            break;
          }
        }
        if (fresh.isEmpty) selected = null;
      }
      setState(() {
        _files = selected == null ? const [] : files;
        _selectedFile = selected;
        _entries = fresh;
        if (select != null) _clearFilters();
        if (!_modules.contains(_module)) _module = '全部模块';
        _error = null;
      });
    } on LogReadException catch (e) {
      if (_current && request == _request) {
        setState(() => _error = e.message);
        if (interactive &&
            mounted &&
            ModalRoute.of(context)?.isCurrent == true) {
          await showFeedbackDialog(context, e.message,
              title: '日志读取失败', error: true);
        }
      }
    } finally {
      if (_current && request == _request) {
        _reading = false;
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _selectFile(LogFileInfo file) async {
    setState(() {
      _selectedFile = file;
      _entries = const [];
    });
    await _load(select: file, interactive: true);
  }

  void _clearFilters() {
    _level = '全部';
    _module = '全部模块';
    _visibleLimit = _initialVisibleLimit;
    _searchController.clear();
  }

  List<LogRecord> get _filteredEntries {
    if (!_current || _access == null || _error != null) return const [];
    final query = _searchController.text.trim().toLowerCase();
    return _entries.where((entry) {
      final levelMatch = _level == "全部" || entry.levelLabel == _level;
      final moduleMatch = _module == "全部模块" || entry.module == _module;
      final queryMatch =
          query.isEmpty || entry.raw.toLowerCase().contains(query);
      return _access!.canRead(entry) && levelMatch && moduleMatch && queryMatch;
    }).toList();
  }

  int _count(String level) =>
      _entries.where((entry) => entry.levelLabel == level).length;

  List<String> get _modules {
    final values = _entries.map((entry) => entry.module).toSet().toList()
      ..sort();
    return ["全部模块", ...values];
  }

  Future<void> _copyVisibleLogs() async {
    if (!_current) return;
    final text = _filteredEntries.reversed.map((entry) => entry.raw).join("\n");
    if (text.isEmpty) {
      _message("当前没有可复制的日志");
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _message("已复制 ${_filteredEntries.length} 条日志");
  }

  Future<void> _exportLogs() async {
    if (!_current) return;
    final visible = _filteredEntries.reversed.toList();
    if (visible.isEmpty) {
      _message("当前没有可导出的日志");
      return;
    }
    final original = _selectedFile?.name ?? "sena.log";
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
    if (path == null || path.isEmpty || !_current) return;
    try {
      await File(path).writeAsString(content);
      _message("日志已导出");
    } catch (e) {
      _message("导出失败: $e");
    }
  }

  Future<void> _cleanOldLogs() async {
    final confirmed = await confirmDestructiveAction(context,
        section: '日志管理',
        title: '清理旧日志？',
        message: '删除 7 天前的客户端日志，当前日志不会受到影响。',
        action: '清理日志');
    if (!_current || confirmed != true) return;
    try {
      await _logger.cleanOldLogs(access: _access!);
      if (!_current) return;
      await _load();
      await _message("旧日志已清理");
    } on LogReadException catch (e) {
      if (mounted && _current) await showFeedbackDialog(context, e.message, error: true);
    }
  }

  void _toggleLive(bool value) {
    setState(() => _live = value);
    _startLiveRefresh();
  }

  Future<void> _loadEarlierEntries() async {
    if (!_current || _reading) return;
    if (_visibleLimit < _filteredEntries.length) {
      setState(() => _visibleLimit += _loadMoreStep);
      return;
    }
    _readLimit += 500;
    _visibleLimit += _loadMoreStep;
    await _load();
  }

  Future<void> _message(String message) async {
    if (!_current) return;
    await showFeedbackDialog(context, message);
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
          onPressed: _filteredEntries.isEmpty ? null : _copyVisibleLogs,
        ),
        AppActionButton(
          icon: Icons.file_download_outlined,
          label: "导出",
          onPressed: _filteredEntries.isEmpty ? null : _exportLogs,
        ),
        AppActionButton(
          icon: Icons.refresh_rounded,
          label: "刷新",
          onPressed:
              _loading ? null : () => _load(verify: true, interactive: true),
          busy: _loading,
        ),
      ],
      scrollable: false,
      child: ValueListenableBuilder<String?>(
          valueListenable: _logger.storageStatus,
          builder: (_, __, ___) => _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_access == null) {
      if (_loading) return const AppStateView.loading(title: '正在确认账号');
      return AppStateView(
          icon: Icons.person_outline,
          title: '尚未确认当前账号',
          message: '请检查登录状态后重试',
          action: _retryButton(verify: true));
    }
    if (_loading && _files.isEmpty) {
      return const AppStateView.loading(title: '正在读取日志');
    }
    final problem =
        _error ?? (_files.isEmpty ? _logger.storageStatus.value : null);
    if (problem != null) {
      return AppStateView(
          icon: Icons.error_outline,
          title: _error != null ? '日志读取失败' : '日志存储异常',
          message: problem,
          action: _retryButton());
    }
    if (_files.isEmpty) {
      return AppStateView(
          icon: Icons.article_outlined,
          title: '当前账号暂无日志',
          action: _retryButton());
    }
    return LayoutBuilder(
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
    );
  }

  Widget _retryButton({bool verify = false}) => AppActionButton(
        icon: Icons.refresh_rounded,
        label: '重试',
        onPressed: () => _load(verify: verify, interactive: true),
      );

  Widget _buildMobilePage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildMobileHeader(),
        _storageWarning(),
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
        "$_viewLabel · ${_entries.length} 条 · INFO ${_count("INFO")} · WARN ${_count("WARN")} · ERROR ${_count("ERROR")}";
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

  String get _viewLabel => _access?.management == true ? "管理员视图" : "个人视图";

  Widget _storageWarning() {
    final message = _logger.storageStatus.value;
    if (message == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(message,
          style: AppText.caption.copyWith(color: Colors.orange[700])),
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
            Text("$_viewLabel · 查看客户端运行记录和错误信息",
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
          _storageWarning(),
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
        child: DropdownButton<LogFileInfo>(
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
    final hasMore =
        filtered.length > visible.length || _entries.length >= _readLimit;
    return AppSurface(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildConsoleHeader(visible.length),
          const Divider(height: 1),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: SingleChildScrollView(
                        child: _entries.isEmpty
                            ? const AppStateView(
                                icon: Icons.article_outlined,
                                title: '此文件没有当前账号可查看的记录')
                            : AppStateView(
                                icon: Icons.search_off_rounded,
                                title: '没有符合筛选条件的日志',
                                action: AppActionButton(
                                    label: '清除筛选',
                                    icon: Icons.filter_alt_off_outlined,
                                    onPressed: () => setState(_clearFilters)))))
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
    final name = _selectedFile?.name ?? "日志";
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
    if (!_current || _access?.canRead(record) != true) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => ValueListenableBuilder<int>(
          valueListenable: logAccessChanges,
          builder: (_, __, ___) {
            if (!_current || _access?.canRead(record) != true) {
              final route = ModalRoute.of(sheetContext);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (route != null && route.isActive) {
                  route.navigator?.removeRoute(route);
                }
              });
              return const SizedBox.shrink();
            }
            return SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("日志详情", style: AppText.title),
                    const SizedBox(height: 12),
                    _detailRow("时间", record.timestamp.toString()),
                    _detailRow("级别", record.levelLabel),
                    _detailRow("模块", record.module),
                    const SizedBox(height: 8),
                    SelectableText(record.raw,
                        style: AppText.label.copyWith(fontFamily: "monospace")),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () async {
                        if (!_current || _access?.canRead(record) != true) {
                          return;
                        }
                        await Clipboard.setData(
                            ClipboardData(text: record.raw));
                        if (sheetContext.mounted) Navigator.pop(sheetContext);
                        _message("日志内容已复制");
                      },
                      icon: const Icon(Icons.copy_outlined, size: 17),
                      label: const Text("复制这条日志"),
                    ),
                  ],
                ),
              ),
            );
          }),
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
  final LogFileInfo file;
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
    final name = file.name;
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
                        child: _LevelBadge(
                            level: record.levelLabel, color: color))),
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
