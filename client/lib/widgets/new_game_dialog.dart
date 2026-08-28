import "dart:math" as math;

import "package:flutter/material.dart";

import "../services/api_client.dart";
import "../utils/theme_utils.dart";
import "app_shell.dart";

Future<int?> showNewGameDialog(
  BuildContext context, {
  required ApiClient api,
  String? initialQuery,
  String title = "新建条目",
}) {
  return showDialog<int>(
    context: context,
    builder: (_) => NewGameDialog(
      api: api,
      initialQuery: initialQuery ?? "",
      title: title,
    ),
  );
}

class NewGameDialog extends StatefulWidget {
  final ApiClient api;
  final String initialQuery;
  final String title;

  const NewGameDialog({
    super.key,
    required this.api,
    required this.initialQuery,
    required this.title,
  });

  @override
  State<NewGameDialog> createState() => _NewGameDialogState();
}

class _NewGameDialogState extends State<NewGameDialog> {
  late final TextEditingController _searchCtrl;
  late final TextEditingController _manualNameCtrl;
  final _sources = const [
    _NewGameSource(
      key: "hikarinagi",
      label: "Hikarinagi",
      description: "中文 Galgame 资料站，适合优先补全中文简介、标签和分级。",
      icon: Icons.auto_awesome_rounded,
      color: Colors.pink,
    ),
    _NewGameSource(
      key: "vndb_kana",
      label: "VNDB",
      description: "视觉小说资料库，标签和发行信息覆盖较全。",
      icon: Icons.menu_book_rounded,
      color: Colors.indigo,
    ),
    _NewGameSource(
      key: "bangumi",
      label: "Bangumi",
      description: "中文 ACG 条目社区，中文标题与简介命中率较高。",
      icon: Icons.forum_rounded,
      color: Colors.blue,
    ),
    _NewGameSource(
      key: "steam",
      label: "Steam",
      description: "Steam 商店数据，适合已上架作品的图片和商店标签。",
      icon: Icons.sports_esports_rounded,
      color: Colors.teal,
    ),
  ];

  int _modeIndex = 0;
  String _source = "hikarinagi";
  List<Map<String, dynamic>> _results = const [];
  Map<String, dynamic>? _selected;
  bool _loading = false;
  bool _creating = false;
  bool _searched = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialQuery.trim();
    _searchCtrl = TextEditingController(text: initial);
    _manualNameCtrl = TextEditingController(text: initial);
    if (initial.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _search();
      });
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _manualNameCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _searchCtrl.text.trim();
    if (query.isEmpty) {
      setState(() {
        _searched = true;
        _results = const [];
        _selected = null;
        _error = "请输入名称或 ID";
      });
      return;
    }
    setState(() {
      _loading = true;
      _searched = true;
      _results = const [];
      _selected = null;
      _error = null;
    });
    try {
      final results = await widget.api.searchMetadataCandidates(
        source: _source,
        query: query,
      );
      if (!mounted) return;
      setState(() {
        _results = results;
        _loading = false;
        _error = results.isEmpty ? "没有找到匹配条目" : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = "搜索失败：$e";
      });
    }
  }

  Future<void> _createManual() async {
    final name = _manualNameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = "请输入游戏名称");
      return;
    }
    await _create({"name": name, "entry_source": "manual"});
  }

  Future<void> _createFromSelected() async {
    final result = _selected;
    if (result == null) {
      setState(() => _error = "请先选择一个元数据条目");
      return;
    }
    await _create(_payloadFromResult(result));
  }

  Future<void> _create(Map<String, dynamic> payload) async {
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final data = await widget.api.createGame(payload);
      final rawId = data["id"];
      final id = rawId is int ? rawId : int.tryParse(rawId?.toString() ?? "");
      if (id == null || id <= 0) {
        throw Exception("服务器没有返回有效游戏 ID");
      }
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _creating = false;
        _error = "创建失败：$e";
      });
    }
  }

  Map<String, dynamic> _payloadFromResult(Map<String, dynamic> result) {
    final title = _string(result["title"]).isNotEmpty
        ? _string(result["title"])
        : _searchCtrl.text.trim();
    final payload = <String, dynamic>{
      "name": title,
      "entry_source": "metadata",
      "source": _source,
      "source_id": _string(result["source_id"]),
      "developer": _string(result["developer"]),
      "description": _string(result["description"]),
      "release_date": _string(result["release_date"]),
      "cover_url": _string(result["cover_url"]),
      "hero_url": _string(result["hero_url"]),
      "tags": _tagsFromResult(result["tags"]),
    };
    final isNsfw = result["is_nsfw"];
    if (isNsfw is bool) payload["is_nsfw"] = isNsfw;
    final length = _intValue(result["length"]);
    final lengthMinutes = _intValue(result["length_minutes"]);
    if (length != null) payload["length"] = length;
    if (lengthMinutes != null) payload["length_minutes"] = lengthMinutes;
    payload.removeWhere((_, value) => value is String && value.trim().isEmpty);
    return payload;
  }

  List<Map<String, dynamic>> _tagsFromResult(Object? raw) {
    if (raw is! List) return const [];
    final tags = <Map<String, dynamic>>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final name = _string(item["name"]);
      if (name.isEmpty) continue;
      tags.add({
        "name": name,
        "rating": _doubleValue(item["rating"]) ?? 0.0,
        "is_spoiler": item["is_spoiler"] == true || item["spoiler"] == true,
      });
    }
    return tags;
  }

  String _string(Object? value) => value?.toString().trim() ?? "";

  int? _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? "");
  }

  double? _doubleValue(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? "");
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final compact = size.width < 560;
    final width = math.min(size.width - 24, compact ? 520.0 : 720.0);
    final height = math.min(size.height - 24, compact ? 680.0 : 640.0);
    final selectedSource = _sources.firstWhere((item) => item.key == _source);
    final status = _creating
        ? "创建中"
        : _loading
            ? "搜索中"
            : _selected != null
                ? "已选择"
                : _results.isNotEmpty
                    ? "${_results.length} 项"
                    : "可搜索";

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(12),
      child: SizedBox(
        width: width,
        height: height,
        child: AppSurface(
          radius: AppRadius.xl,
          blur: true,
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              _Header(
                title: widget.title,
                subtitle: "从元数据直接创建，或只创建一个手动条目。",
                status: status,
                busy: _loading || _creating,
              ),
              Divider(height: 1, color: cardBorder(context)),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  compact ? 14 : 20,
                  14,
                  compact ? 14 : 20,
                  10,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: AppSegmentedTabs(
                    selectedIndex: _modeIndex,
                    tabs: const [
                      AppSegmentedTab(0, Icons.travel_explore_rounded, "元数据"),
                      AppSegmentedTab(1, Icons.edit_note_rounded, "手动"),
                    ],
                    onChanged: _creating || _loading
                        ? (_) {}
                        : (index) => setState(() {
                              _modeIndex = index;
                              _error = null;
                            }),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 14 : 20,
                    0,
                    compact ? 14 : 20,
                    12,
                  ),
                  child: AnimatedSwitcher(
                    duration: AppMotion.fast,
                    child: _modeIndex == 0
                        ? _buildMetadataMode(context, selectedSource, compact)
                        : _buildManualMode(context),
                  ),
                ),
              ),
              if (_error != null && _error!.isNotEmpty)
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 14 : 20,
                    0,
                    compact ? 14 : 20,
                    12,
                  ),
                  child: _InlineError(message: _error!),
                ),
              Divider(height: 1, color: cardBorder(context)),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  compact ? 14 : 20,
                  12,
                  compact ? 14 : 20,
                  16,
                ),
                child: Wrap(
                  spacing: AppGap.sm,
                  runSpacing: AppGap.sm,
                  alignment: WrapAlignment.end,
                  children: [
                    AppActionButton(
                      icon: Icons.close_rounded,
                      label: "取消",
                      color: hintColor(context),
                      onPressed:
                          _creating ? null : () => Navigator.pop(context),
                    ),
                    if (_modeIndex == 0)
                      AppActionButton(
                        icon: Icons.search_rounded,
                        label: "搜索",
                        busy: _loading,
                        onPressed: (_creating || _loading) ? null : _search,
                      ),
                    AppActionButton(
                      icon: _modeIndex == 0
                          ? Icons.add_circle_outline_rounded
                          : Icons.add_rounded,
                      label: _modeIndex == 0 ? "导入选中" : "创建条目",
                      filled: true,
                      busy: _creating,
                      onPressed: _creating
                          ? null
                          : _modeIndex == 0
                              ? _createFromSelected
                              : _createManual,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMetadataMode(
    BuildContext context,
    _NewGameSource selectedSource,
    bool compact,
  ) {
    final sourcePicker = DropdownButtonFormField<String>(
      value: _source,
      decoration: InputDecoration(
        labelText: "元数据来源",
        prefixIcon: Icon(selectedSource.icon, color: selectedSource.color),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        isDense: true,
      ),
      items: [
        for (final source in _sources)
          DropdownMenuItem(
            value: source.key,
            child: Text(source.label),
          ),
      ],
      onChanged: _loading || _creating
          ? null
          : (value) {
              if (value == null) return;
              setState(() {
                _source = value;
                _results = const [];
                _selected = null;
                _searched = false;
                _error = null;
              });
            },
    );
    final searchField = TextField(
      controller: _searchCtrl,
      autofocus: true,
      enabled: !_loading && !_creating,
      textInputAction: TextInputAction.search,
      onSubmitted: (_) => _search(),
      decoration: InputDecoration(
        labelText: "名称或 ID",
        hintText: "输入后回车搜索",
        prefixIcon: const Icon(Icons.search_rounded),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        isDense: true,
      ),
    );

    return Column(
      key: const ValueKey("metadata"),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        compact
            ? Column(
                children: [
                  sourcePicker,
                  const SizedBox(height: AppGap.sm),
                  searchField,
                ],
              )
            : Row(
                children: [
                  SizedBox(width: 210, child: sourcePicker),
                  const SizedBox(width: AppGap.md),
                  Expanded(child: searchField),
                ],
              ),
        const SizedBox(height: AppGap.sm),
        _SourceHint(source: selectedSource),
        const SizedBox(height: AppGap.md),
        Expanded(child: _buildResultBody(context)),
      ],
    );
  }

  Widget _buildManualMode(BuildContext context) {
    return Column(
      key: const ValueKey("manual"),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _manualNameCtrl,
          autofocus: true,
          enabled: !_creating,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _createManual(),
          decoration: InputDecoration(
            labelText: "游戏名称",
            hintText: "只创建条目，不绑定实体目录",
            prefixIcon: const Icon(Icons.edit_note_rounded),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
          ),
        ),
        const SizedBox(height: AppGap.md),
        AppSurface(
          padding: const EdgeInsets.all(14),
          radius: AppRadius.md,
          color: Theme.of(context)
              .colorScheme
              .primary
              .withValues(alpha: 0.08),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: AppGap.sm),
              Expanded(
                child: Text(
                  "手动条目会标记为 manual，不参与根目录孤儿清理；后续可在编辑页补图片、简介、ID 和标签。",
                  style: AppText.bodySmall.copyWith(
                    color: subTextColor(context),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildResultBody(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loading) {
      return const AppStateView.loading(
        title: "正在搜索",
        message: "正在从所选来源获取候选条目。",
      );
    }
    if (!_searched) {
      return AppStateView(
        icon: Icons.travel_explore_rounded,
        title: "先搜索一个条目",
        message: "支持名称和来源 ID，选中结果后即可直接创建。",
      );
    }
    if (_results.isEmpty) {
      return AppStateView(
        icon: Icons.search_off_rounded,
        title: "没有匹配结果",
        message: "换一个名称、ID 或来源试试。",
        action: AppActionButton(
          icon: Icons.refresh_rounded,
          label: "重新搜索",
          filled: true,
          color: cs.primary,
          onPressed: _search,
        ),
      );
    }
    return ListView.separated(
      itemCount: _results.length,
      separatorBuilder: (_, __) => const SizedBox(height: AppGap.sm),
      itemBuilder: (context, index) {
        final result = _results[index];
        return _MetadataCandidateTile(
          result: result,
          selected: identical(result, _selected),
          onTap: () => setState(() {
            _selected = result;
            _error = null;
          }),
        );
      },
    );
  }
}

class _NewGameSource {
  final String key;
  final String label;
  final String description;
  final IconData icon;
  final Color color;

  const _NewGameSource({
    required this.key,
    required this.label,
    required this.description,
    required this.icon,
    required this.color,
  });
}

class _Header extends StatelessWidget {
  final String title;
  final String subtitle;
  final String status;
  final bool busy;

  const _Header({
    required this.title,
    required this.subtitle,
    required this.status,
    required this.busy,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Icon(Icons.add_circle_outline_rounded, color: cs.primary),
          ),
          const SizedBox(width: AppGap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppText.headline),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: AppText.bodySmall.copyWith(color: hintColor(context)),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppGap.sm),
          AppStatusPill(
            icon: busy ? Icons.sync_rounded : Icons.add_task_rounded,
            label: status,
            color: busy ? Colors.orange : cs.primary,
          ),
        ],
      ),
    );
  }
}

class _SourceHint extends StatelessWidget {
  final _NewGameSource source;

  const _SourceHint({required this.source});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(source.icon, size: 16, color: source.color),
        const SizedBox(width: AppGap.xs),
        Expanded(
          child: Text(
            source.description,
            style: AppText.caption.copyWith(color: hintColor(context)),
          ),
        ),
      ],
    );
  }
}

class _InlineError extends StatelessWidget {
  final String message;

  const _InlineError({required this.message});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: cs.error.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, size: 17, color: cs.error),
          const SizedBox(width: AppGap.sm),
          Expanded(
            child: Text(
              message,
              style: AppText.bodySmall.copyWith(color: cs.error),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetadataCandidateTile extends StatelessWidget {
  final Map<String, dynamic> result;
  final bool selected;
  final VoidCallback onTap;

  const _MetadataCandidateTile({
    required this.result,
    required this.selected,
    required this.onTap,
  });

  String _string(Object? value) => value?.toString().trim() ?? "";

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final title = _string(result["title"]);
    final developer = _string(result["developer"]);
    final releaseDate = _string(result["release_date"]);
    final description = _string(result["description"]);
    final coverUrl = _string(result["cover_url"]);
    final sourceId = _string(result["source_id"]);
    final rawTags = result["tags"];
    final tagCount = rawTags is List ? rawTags.length : 0;
    final isNsfw = result["is_nsfw"] == true;
    final borderColor = selected
        ? cs.primary.withValues(alpha: 0.72)
        : cardBorder(context);
    return Material(
      color: selected
          ? cs.primary.withValues(alpha: 0.10)
          : cardBg(context),
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.md),
                child: SizedBox(
                  width: 64,
                  height: 90,
                  child: coverUrl.isNotEmpty
                      ? Image.network(
                          coverUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              const _CoverPlaceholder(),
                        )
                      : const _CoverPlaceholder(),
                ),
              ),
              const SizedBox(width: AppGap.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title.isNotEmpty ? title : "(无标题)",
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.bodyMedium.copyWith(
                              color: cs.onSurface,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        if (selected) ...[
                          const SizedBox(width: AppGap.sm),
                          Icon(
                            Icons.check_circle_rounded,
                            color: cs.primary,
                            size: 20,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      [
                        if (developer.isNotEmpty) developer,
                        if (releaseDate.isNotEmpty) releaseDate,
                        if (sourceId.isNotEmpty) "ID $sourceId",
                      ].join(" · "),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(
                        color: hintColor(context),
                      ),
                    ),
                    if (description.isNotEmpty) ...[
                      const SizedBox(height: AppGap.sm),
                      Text(
                        description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.bodySmall.copyWith(
                          color: subTextColor(context),
                          height: 1.35,
                        ),
                      ),
                    ],
                    const SizedBox(height: AppGap.sm),
                    Wrap(
                      spacing: AppGap.xs,
                      runSpacing: AppGap.xs,
                      children: [
                        if (isNsfw)
                          const _MiniChip(
                            label: "NSFW",
                            icon: Icons.visibility_off_rounded,
                            color: Colors.red,
                          ),
                        if (tagCount > 0)
                          _MiniChip(
                            label: "$tagCount 标签",
                            icon: Icons.local_offer_outlined,
                            color: Colors.deepPurple,
                          ),
                        _MiniChip(
                          label: selected ? "将导入" : "点击选择",
                          icon: selected
                              ? Icons.check_rounded
                              : Icons.touch_app_rounded,
                          color: selected ? cs.primary : hintColor(context),
                        ),
                      ],
                    ),
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

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: placeholderBg(context),
      child: Icon(
        Icons.image_not_supported_outlined,
        color: placeholderIcon(context),
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;

  const _MiniChip({
    required this.label,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: AppText.caption.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
