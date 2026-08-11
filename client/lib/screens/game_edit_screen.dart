/// Full-screen game metadata editor — Playnite style.
/// Layout: cover right header, left metadata panel, right description, inline download buttons.

import "dart:async";
import "dart:convert";
import "dart:io" show File;
import "package:file_picker/file_picker.dart";

import "package:flutter/material.dart";
import "package:provider/provider.dart";
import "../services/logged_http.dart" as http;
import "package:path_provider/path_provider.dart";

import "../models/game.dart";
import "../utils/theme_utils.dart";
import "../providers/game_provider.dart";
import "../services/api_client.dart";
import "../services/scrape_service.dart";
import "../widgets/app_shell.dart";
import "../widgets/nsfw_image.dart";

class GameEditScreen extends StatefulWidget {
  final GameDetail game;
  const GameEditScreen({super.key, required this.game});

  @override
  State<GameEditScreen> createState() => _GameEditScreenState();
}

class _GameEditScreenState extends State<GameEditScreen> {
  late final TextEditingController _name,
      _dev,
      _desc,
      _date,
      _vndb,
      _steam,
      _bgm,
      _notes,
      _bgUrl;
  bool _saving = false;
  bool _isNsfw = false;
  String? _coverPath;
  String? _pendingCoverUrl;
  String? _pendingCoverFilePath;
  String? _pendingBgFilePath;
  late List<GameVersion> _versions;
  int _coverVersion = 0;
  int _bgVersion = 0;

  String get _baseUrl => context.read<GameProvider>().api.baseUrl;
  Map<String, String> get _authHeaders =>
      context.read<GameProvider>().api.headers;

  Future<List<Map<String, dynamic>>> _searchMetadataSource(
    String source,
    String query,
  ) async {
    if (source != "hikarinagi") {
      return ScrapeService.search(source, query);
    }

    final uri = Uri.parse("$_baseUrl/api/scrape/search").replace(
      queryParameters: {"q": query, "source": source},
    );
    final resp = await http.get(uri, headers: _authHeaders);
    if (resp.statusCode != 200) {
      throw Exception("Hikarinagi 搜索失败 (${resp.statusCode})");
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final results = (data["results"] as List?) ?? const [];
    return results
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    final g = widget.game;
    _versions = List<GameVersion>.from(g.versions);
    _coverPath = g.coverPath;
    _isNsfw = g.isNsfw;
    _coverVersion = DateTime.now().millisecondsSinceEpoch;
    _name = TextEditingController(text: g.name);
    _dev = TextEditingController(text: g.developer ?? "");
    _desc = TextEditingController(text: g.description ?? "");
    _date = TextEditingController(text: g.releaseDate ?? "");
    _vndb = TextEditingController(text: g.vndbId ?? "");
    _steam = TextEditingController(text: g.steamId ?? "");
    _bgm = TextEditingController(text: g.bangumiId ?? "");
    _bgUrl = TextEditingController(text: g.bgPath ?? "");
    _notes = TextEditingController();
    for (final controller in [
      _dev,
      _desc,
      _date,
      _vndb,
      _steam,
      _bgm,
      _bgUrl
    ]) {
      controller.addListener(_onMetadataEdited);
    }
  }

  void _onMetadataEdited() {
    if (mounted) setState(() {});
  }

  Future<void> _save({bool popOnSave = true}) async {
    setState(() => _saving = true);
    _showLoadingDialog();
    try {
      final g = widget.game;
      if (_pendingCoverFilePath != null) {
        final newPath = await _uploadLocalImage(
          _pendingCoverFilePath!,
          cover: true,
        );
        if (newPath != null) _coverPath = newPath;
        _pendingCoverUrl = null;
        _pendingCoverFilePath = null;
      }
      if (_pendingBgFilePath != null) {
        final newPath = await _uploadLocalImage(
          _pendingBgFilePath!,
          cover: false,
        );
        if (newPath != null) _bgUrl.text = newPath;
        _pendingBgFilePath = null;
      }
      final body = {
        "name": _name.text.trim(),
        "developer": _dev.text.trim(),
        "description": _desc.text.trim(),
        "release_date": _date.text.trim(),
        "bg_path": _bgUrl.text.trim(),
        "vndb_id": _vndb.text.trim(),
        "steam_id": _steam.text.trim(),
        "bangumi_id": _bgm.text.trim(),
        "is_nsfw": _isNsfw,
      };
      final resp = await http.put(
        Uri.parse("$_baseUrl/api/games/${g.id}"),
        headers: {"Content-Type": "application/json", ..._authHeaders},
        body: jsonEncode(body),
      );
      if (resp.statusCode != 200) {
        if (mounted) Navigator.pop(context);
        if (mounted) setState(() => _saving = false);
        _showError("保存失败 (${resp.statusCode}): ${resp.body}");
        return;
      }
      if (mounted) Navigator.pop(context); // close loading dialog
      if (popOnSave && mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) Navigator.pop(context); // close loading dialog
      _showError("$e");
    }
    if (mounted)
      setState(() {
        _saving = false;
        _coverVersion = DateTime.now().millisecondsSinceEpoch;
      });
  }

  void _showLoadingDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(strokeWidth: 3),
                  SizedBox(width: 16),
                  Text("保存中...", style: TextStyle(fontSize: 15)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _downloadFromSource(String source, String label) async {
    final ctrl = TextEditingController(text: _name.text);
    final q = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("搜索 $label"),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(labelText: "名称或 ID", hintText: "输入后回车搜索"),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text("搜索"),
          ),
        ],
      ),
    );
    if (q == null || q.isEmpty) return;

    List<Map<String, dynamic>> results = [];
    try {
      final resp = await http.get(
        Uri.parse(
          "$_baseUrl/api/scrape/search?q=${Uri.encodeComponent(q)}&source=$source",
        ),
        headers: await _authHeaders,
      );
      results = ((jsonDecode(resp.body) as Map)["results"] as List)
          .cast<Map<String, dynamic>>();
    } catch (_) {
      _showError("搜索失败");
      return;
    }
    if (results.isEmpty) {
      _showError("无结果");
      return;
    }

    // Show results
    final picked = await showDialog<Object?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("$label — 搜索结果"),
        content: SizedBox(
          width: 450,
          height: 400,
          child: ListView.builder(
            itemCount: results.length,
            itemBuilder: (_, i) {
              final r = results[i];
              return ListTile(
                leading: (r["cover_url"] ?? "").toString().isNotEmpty
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Image.network(
                          r["cover_url"].toString(),
                          width: 50,
                          height: 70,
                          key: ValueKey(r["cover_url"]),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _noCover(),
                        ),
                      )
                    : _noCover(),
                title: Text(
                  r["title"] ?? "",
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  [r["developer"], r["release_date"]]
                      .where((s) => s != null && s.toString().isNotEmpty)
                      .join(" · "),
                  style: const TextStyle(fontSize: 12),
                ),
                onTap: () => Navigator.pop(ctx, r),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("取消"),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    final r = picked as Map<String, dynamic>;

    // Apply to form (mark dirty)
    setState(() {
      _name.text = (r["title"] ?? "").toString();
      _dev.text = (r["developer"] ?? "").toString();
      _desc.text = (r["description"] ?? "").toString();
      _date.text = (r["release_date"] ?? "").toString();
      if (r["is_nsfw"] == true) _isNsfw = true;
    });
    _showMsg("已填入 $label 数据");
  }

  Future<void> _moveVersionDialog(version) async {
    final searchCtrl = TextEditingController();
    var results = <Map<String, dynamic>>[];
    final targetId = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text("移动「${version.filename}」"),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: searchCtrl,
                        autofocus: true,
                        decoration: const InputDecoration(
                          labelText: "搜索游戏名称",
                          isDense: true,
                        ),
                        onSubmitted: (v) async {
                          setD(() => results = []);
                          try {
                            final r = await http.get(
                              Uri.parse(
                                "$_baseUrl/api/games/search?q=${Uri.encodeComponent(v)}&page_size=10",
                              ),
                              headers: await _authHeaders,
                            );
                            if (r.statusCode == 200)
                              results = (jsonDecode(r.body) as List)
                                  .cast<Map<String, dynamic>>();
                          } catch (_) {}
                          setD(() {});
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      icon: const Icon(Icons.search, size: 18),
                      onPressed: () async {
                        setD(() => results = []);
                        try {
                          final r = await http.get(
                            Uri.parse(
                              "$_baseUrl/api/games/search?q=${Uri.encodeComponent(searchCtrl.text)}&page_size=10",
                            ),
                            headers: await _authHeaders,
                          );
                          if (r.statusCode == 200)
                            results = (jsonDecode(r.body) as List)
                                .cast<Map<String, dynamic>>();
                        } catch (_) {}
                        setD(() {});
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (results.isNotEmpty)
                  SizedBox(
                    height: 250,
                    child: ListView.builder(
                      itemCount: results.length,
                      itemBuilder: (_, i) {
                        final g = results[i];
                        return ListTile(
                          title: Text(
                            g["name"] ?? "",
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: Text(
                            "${g["company_name"] ?? ""} · ${g["platform_summary"] ?? ""}",
                            style: const TextStyle(fontSize: 11),
                          ),
                          onTap: () => Navigator.pop(ctx, g["id"] as int),
                        );
                      },
                    ),
                  ),
                if (results.isEmpty && searchCtrl.text.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      "无结果",
                      style: TextStyle(color: hintColor(context)),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("取消"),
            ),
            TextButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: const Text("创建新条目并移入"),
              onPressed: () async {
                final nameCtrl = TextEditingController();
                final newName = await showDialog<String>(
                  context: ctx,
                  builder: (c) => AlertDialog(
                    title: const Text("新建游戏条目"),
                    content: TextField(
                      controller: nameCtrl,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: "游戏名称",
                        hintText: "输入新游戏名称",
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(c),
                        child: const Text("取消"),
                      ),
                      FilledButton(
                        onPressed: () {
                          final name = nameCtrl.text.trim();
                          if (name.isEmpty) return;
                          Navigator.pop(c, name);
                        },
                        child: const Text("创建"),
                      ),
                    ],
                  ),
                );
                if (newName == null || newName.isEmpty) return;
                try {
                  final r = await http.put(
                    Uri.parse("$_baseUrl/api/games/quick-create"),
                    headers: {
                      "Content-Type": "application/json",
                      ..._authHeaders,
                    },
                    body: jsonEncode({"name": newName}),
                  );
                  if (r.statusCode == 200) {
                    Navigator.pop(ctx, jsonDecode(r.body)["id"] as int);
                  }
                } catch (_) {}
              },
            ),
          ],
        ),
      ),
    );
    if (targetId != null && targetId > 0) {
      try {
        final g = widget.game;
        await http.post(
          Uri.parse(
            "$_baseUrl/api/games/${g.id}/versions/${version.id}/move?to_game_id=$targetId",
          ),
          headers: _authHeaders,
        );
        if (mounted) Navigator.pop(context, true);
      } catch (e) {
        _showError("$e");
      }
    }
  }

  Future<void> _changeVersionPlatform(GameVersion version) async {
    const options = [
      {"label": "PC", "value": "PC"},
      {"label": "KR", "value": "KRKR"},
      {"label": "Ty", "value": "Ty"},
      {"label": "ONS", "value": "ONS"},
      {"label": "直装", "value": "直装"},
    ];
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("修改平台"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: options.map((item) {
            final value = item["value"]!;
            return RadioListTile<String>(
              value: value,
              groupValue: version.platform,
              title: Text(item["label"]!),
              onChanged: (v) => Navigator.pop(ctx, v),
            );
          }).toList(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("取消"),
          ),
        ],
      ),
    );
    if (selected == null || selected == version.platform) return;
    await _updateVersion(version, {"platform": selected});
  }

  Future<void> _changeVersionPassword(GameVersion version) async {
    final ctrl = TextEditingController(text: version.extractPassword ?? "");
    final password = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("预填解压密码"),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: "解压密码",
            helperText: "留空保存可清除预填密码",
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text("保存"),
          ),
        ],
      ),
    );
    if (password == null) return;
    await _updateVersion(version, {"extract_password": password});
  }

  Future<void> _updateVersion(
    GameVersion version,
    Map<String, dynamic> body,
  ) async {
    try {
      final resp = await http.put(
        Uri.parse(
          "$_baseUrl/api/games/${widget.game.id}/versions/${version.id}",
        ),
        headers: {"Content-Type": "application/json", ..._authHeaders},
        body: jsonEncode(body),
      );
      if (resp.statusCode != 200) {
        _showError("版本更新失败 (${resp.statusCode}): ${resp.body}");
        return;
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final updated = GameVersion.fromJson(
        data["version"] as Map<String, dynamic>,
      );
      if (!mounted) return;
      setState(() {
        final index = _versions.indexWhere((v) => v.id == updated.id);
        if (index >= 0) _versions[index] = updated;
      });
    } catch (e) {
      _showError("版本更新失败: $e");
    }
  }

  Future<void> _mergeGameDialog() async {
    final searchCtrl = TextEditingController();
    var results = <Map<String, dynamic>>[];
    final targetId = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text("合并到哪个游戏？"),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  "当前游戏的所有版本将移至目标游戏，当前游戏将被删除。",
                  style: AppText.label.copyWith(color: hintColor(context)),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: searchCtrl,
                        autofocus: true,
                        decoration: const InputDecoration(
                          labelText: "搜索游戏名称",
                          isDense: true,
                        ),
                        onSubmitted: (v) async {
                          setD(() => results = []);
                          try {
                            final r = await http.get(
                              Uri.parse(
                                "$_baseUrl/api/games/search?q=${Uri.encodeComponent(v)}&page_size=10",
                              ),
                              headers: await _authHeaders,
                            );
                            if (r.statusCode == 200)
                              results = (jsonDecode(r.body) as List)
                                  .cast<Map<String, dynamic>>();
                          } catch (_) {}
                          setD(() {});
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      icon: const Icon(Icons.search, size: 18),
                      onPressed: () async {
                        setD(() => results = []);
                        try {
                          final r = await http.get(
                            Uri.parse(
                              "$_baseUrl/api/games/search?q=${Uri.encodeComponent(searchCtrl.text)}&page_size=10",
                            ),
                            headers: await _authHeaders,
                          );
                          if (r.statusCode == 200)
                            results = (jsonDecode(r.body) as List)
                                .cast<Map<String, dynamic>>();
                        } catch (_) {}
                        setD(() {});
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (results.isNotEmpty)
                  SizedBox(
                    height: 250,
                    child: ListView.builder(
                      itemCount: results.length,
                      itemBuilder: (_, i) {
                        final g = results[i];
                        return ListTile(
                          title: Text(
                            g["name"] ?? "",
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: Text(
                            "${g["company_name"] ?? ""} · ${g["platform_summary"] ?? ""}",
                            style: const TextStyle(fontSize: 11),
                          ),
                          onTap: () => Navigator.pop(ctx, g["id"] as int),
                        );
                      },
                    ),
                  ),
                if (results.isEmpty && searchCtrl.text.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      "无结果",
                      style: TextStyle(color: hintColor(context)),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("取消"),
            ),
            if (searchCtrl.text.trim().isNotEmpty)
              TextButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text("创建新条目并合并"),
                onPressed: () async {
                  try {
                    final r = await http.put(
                      Uri.parse("$_baseUrl/api/games/quick-create"),
                      headers: {
                        "Content-Type": "application/json",
                        ..._authHeaders,
                      },
                      body: jsonEncode({"name": searchCtrl.text.trim()}),
                    );
                    if (r.statusCode == 200) {
                      final newId = jsonDecode(r.body)["id"] as int;
                      Navigator.pop(ctx, newId);
                    }
                  } catch (_) {}
                },
              ),
          ],
        ),
      ),
    );
    if (targetId != null && targetId > 0) {
      try {
        final g = widget.game;
        await http.post(
          Uri.parse("$_baseUrl/api/games/${g.id}/merge/$targetId"),
          headers: _authHeaders,
        );
        if (mounted) Navigator.pop(context, true);
      } catch (e) {
        _showError("$e");
      }
    }
  }

  Future<void> _reloadGame() async {
    try {
      final resp = await http.get(
        Uri.parse("$_baseUrl/api/games/${widget.game.id}"),
      );
      if (resp.statusCode == 200) {
        final fresh = GameDetail.fromJson(
          jsonDecode(resp.body) as Map<String, dynamic>,
        );
        if (mounted)
          setState(() {
            _coverPath = fresh.coverPath;
            _coverVersion = DateTime.now().millisecondsSinceEpoch;
          });
      }
    } catch (_) {}
  }

  void _showMsg(String m) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("提示"),
        content: Text(m),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("确定"),
          ),
        ],
      ),
    );
  }

  void _showError(String m) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("错误"),
        content: Text(m),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("关闭"),
          ),
        ],
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController ctrl, {
    int maxLines = 1,
    IconData? icon,
    String? sourceId,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Icon(icon, size: 18, color: hintColor(context)),
            ),
            const SizedBox(width: 8),
          ],
          SizedBox(
            width: 80,
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                label,
                style: TextStyle(color: subTextColor(context), fontSize: 14),
              ),
            ),
          ),
          Expanded(
            child: TextField(
              controller: ctrl,
              maxLines: maxLines,
              decoration: _dec(
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
              style: const TextStyle(fontSize: 15),
            ),
          ),
          if (sourceId != null && sourceId.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10, left: 6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: Colors.green.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.check_circle,
                      size: 10,
                      color: Colors.green[300],
                    ),
                    const SizedBox(width: 4),
                    Text(
                      sourceId,
                      style: AppText.caption.copyWith(
                        color: Colors.green[300],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _noCover() => const Icon(Icons.image, size: 36, color: Colors.grey);

  Widget _section(String t, [IconData? icon]) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 18, color: sectionIconColor(context)),
              const SizedBox(width: 6),
            ],
            Text(
              t,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: sectionTextColor(context),
              ),
            ),
          ],
        ),
      );

  Widget _fieldCard({required List<Widget> children}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        decoration: BoxDecoration(
          color: cardBg(context),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cardBorder(context)),
        ),
        child: Column(children: children),
      );

  Widget _hintCard(String text) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cardBg(context),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cardBorder(context)),
        ),
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 18, color: hintColor(context)),
            const SizedBox(width: 8),
            Text(
              text,
              style: AppText.bodyMedium.copyWith(color: hintColor(context)),
            ),
          ],
        ),
      );

  Widget _editCompletenessCard() {
    final score = _editCompleteness();
    final missing = _editMissingLabels();
    final color = score >= 80
        ? Colors.green
        : score >= 55
            ? Colors.orange
            : Colors.red;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.fact_check_outlined, size: 20, color: color),
              const SizedBox(width: AppGap.sm),
              Expanded(
                child: Text(
                  "资料完整度",
                  style: AppText.bodyMedium.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                "$score%",
                style: AppText.title.copyWith(
                  color: color,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppGap.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: score / 100,
              minHeight: 7,
              backgroundColor: cardBorder(context).withValues(alpha: 0.45),
              color: color,
            ),
          ),
          if (missing.isNotEmpty) ...[
            const SizedBox(height: AppGap.md),
            Wrap(
              spacing: AppGap.sm,
              runSpacing: AppGap.sm,
              children: missing
                  .map(
                    (label) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: Colors.orange.withValues(alpha: 0.22),
                        ),
                      ),
                      child: Text(
                        label,
                        style: AppText.caption.copyWith(
                          color: Colors.orange,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  int _editCompleteness() {
    final checks = <bool>[
      _coverPath?.isNotEmpty == true || _pendingCoverFilePath != null,
      _bgUrl.text.trim().isNotEmpty || _pendingBgFilePath != null,
      _desc.text.trim().isNotEmpty,
      _dev.text.trim().isNotEmpty,
      _date.text.trim().isNotEmpty,
      _versions.isNotEmpty,
      _vndb.text.trim().isNotEmpty ||
          _steam.text.trim().isNotEmpty ||
          _bgm.text.trim().isNotEmpty,
    ];
    return ((checks.where((value) => value).length / checks.length) * 100)
        .round();
  }

  List<String> _editMissingLabels() {
    final missing = <String>[];
    if (_coverPath?.isNotEmpty != true && _pendingCoverFilePath == null) {
      missing.add("封面");
    }
    if (_bgUrl.text.trim().isEmpty && _pendingBgFilePath == null) {
      missing.add("背景");
    }
    if (_desc.text.trim().isEmpty) missing.add("简介");
    if (_dev.text.trim().isEmpty) missing.add("开发商");
    if (_date.text.trim().isEmpty) missing.add("发售日");
    if (_versions.isEmpty) missing.add("版本");
    if (_vndb.text.trim().isEmpty &&
        _steam.text.trim().isEmpty &&
        _bgm.text.trim().isEmpty) {
      missing.add("来源ID");
    }
    return missing;
  }

  Color _platformColor(String platform) {
    switch (platform.toLowerCase()) {
      case "windows":
        return Colors.blue;
      case "android":
        return Colors.green;
      case "linux":
        return Colors.orange;
      case "mac":
        return Colors.grey;
      default:
        return Colors.blueGrey;
    }
  }

  Widget _divider() =>
      Divider(height: 1, thickness: 0.5, color: cardBorder(context));

  @override
  Widget build(BuildContext context) {
    final g = widget.game;
    final hasCover = _coverPath != null && _coverPath!.isNotEmpty;
    final isWide = MediaQuery.of(context).size.width > 600;

    return AppScaffold(
      title: "编辑游戏",
      subtitle: g.name,
      leading: const Icon(Icons.edit_note_outlined, size: 24),
      scrollable: false,
      padding: EdgeInsets.zero,
      maxWidth: 1280,
      actions: [
        AppActionButton(
          icon: Icons.cloud_download_outlined,
          label: "下载元数据",
          onPressed: _downloadMetadata,
        ),
        AppActionButton(
          icon: Icons.delete_outline,
          label: "删除",
          color: Colors.red,
          onPressed: () async {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text("确认删除"),
                content: Text("确定删除「${widget.game.name}」吗？\n不会删除本地文件。"),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text("取消"),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text("删除"),
                  ),
                ],
              ),
            );
            if (confirmed == true && context.mounted) {
              await context.read<GameProvider>().deleteGame(widget.game.id);
              if (context.mounted) Navigator.pop(context, true);
            }
          },
        ),
        AppActionButton(
          icon: Icons.save_outlined,
          label: "保存",
          filled: true,
          busy: _saving,
          onPressed: _saving ? null : _save,
        ),
      ],
      child: SingleChildScrollView(
        padding: EdgeInsets.all(isWide ? 28 : 12),
        child: Column(
          children: [
            // ── Hero banner (landscape) full width ──
            Padding(
              padding: EdgeInsets.fromLTRB(0, 0, 0, 4),
              child: NsfwImage(
                isNsfw: _isNsfw,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(isWide ? 14 : 0),
                  child: _bgHeroPreview(),
                ),
              ),
            ),
            Center(
              child: TextButton.icon(
                onPressed: _pickLocalBg,
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 14),
                label: const Text("上传背景", style: TextStyle(fontSize: 12)),
              ),
            ),
            Center(
              child: TextButton.icon(
                onPressed: () => _promptImageUrl(cover: false),
                icon: const Icon(Icons.link, size: 14),
                label: const Text("URL", style: TextStyle(fontSize: 12)),
              ),
            ),
            const SizedBox(height: 12),
            // ── Content area ──
            Center(
              child: SizedBox(
                width: 900,
                child: Column(
                  children: [
                    // ── Header: cover right, name left ──
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              TextField(
                                controller: _name,
                                style: const TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.bold,
                                  height: 1.2,
                                ),
                                decoration: _dec(
                                  border: InputBorder.none,
                                  isDense: true,
                                ),
                              ),
                              const SizedBox(height: 6),
                              if (g.companyName != null &&
                                  g.companyName!.isNotEmpty)
                                Text(
                                  g.companyName!,
                                  style: TextStyle(
                                    fontSize: 16,
                                    color: subTextColor(context),
                                  ),
                                )
                              else
                                Text(
                                  "无公司信息",
                                  style: AppText.bodyMedium.copyWith(
                                    color: Colors.grey[600],
                                  ),
                                ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  _sourceBadge("VNDB", g.vndbId),
                                  _sourceBadge("Steam", g.steamId),
                                  _sourceBadge("Bangumi", g.bangumiId),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 24),
                        Column(
                          children: [
                            Container(
                              width: isWide ? 200 : 130,
                              height: isWide ? 280 : 182,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                boxShadow: [
                                  BoxShadow(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary
                                        .withValues(alpha: 0.2),
                                    blurRadius: 20,
                                    offset: const Offset(0, 8),
                                  ),
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.15),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                                border: Border.all(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outlineVariant
                                      .withValues(alpha: 0.5),
                                ),
                              ),
                              child: NsfwImage(
                                isNsfw: _isNsfw,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(14),
                                  child: _pendingCoverFilePath != null
                                      ? Image.file(
                                          File(_pendingCoverFilePath!),
                                          key: ValueKey(
                                            "pending_cover_$_pendingCoverFilePath",
                                          ),
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) =>
                                              _coverPlaceholder(),
                                        )
                                      : hasCover
                                          ? Image.network(
                                              "$_baseUrl/api/files/covers${_coverPath!}?v=$_coverVersion",
                                              key: ValueKey(
                                                  "cover_$_coverVersion"),
                                              headers: mediaAuthHeaders,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, __, ___) =>
                                                  _coverPlaceholder(),
                                            )
                                          : _coverPlaceholder(),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: () => _pickLocalCover(),
                              icon: const Icon(
                                Icons.add_photo_alternate_outlined,
                                size: 16,
                              ),
                              label: const Text(
                                "本地上传",
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                            TextButton.icon(
                              onPressed: () => _promptImageUrl(cover: true),
                              icon: const Icon(Icons.link, size: 16),
                              label: const Text(
                                "URL",
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _editCompletenessCard(),
                    const SizedBox(height: 24),

                    // ── Body: responsive — wide: Row, narrow: Column ──
                    if (isWide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Left: metadata grid
                          Expanded(
                            flex: 5,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _section("详细信息", Icons.info_outline),
                                _fieldCard(
                                  children: [
                                    _field(
                                      "开发商",
                                      _dev,
                                      icon: Icons.business,
                                      sourceId: g.vndbId,
                                    ),
                                    _divider(),
                                    _field(
                                      "发售日",
                                      _date,
                                      icon: Icons.calendar_today,
                                      sourceId: g.vndbId,
                                    ),
                                    _divider(),
                                    _field(
                                      "VNDB ID",
                                      _vndb,
                                      icon: Icons.tag,
                                      sourceId: g.vndbId != null &&
                                              g.vndbId!.isNotEmpty
                                          ? g.vndbId
                                          : null,
                                    ),
                                    _divider(),
                                    _field(
                                      "Steam ID",
                                      _steam,
                                      icon: Icons.tag,
                                      sourceId: g.steamId != null &&
                                              g.steamId!.isNotEmpty
                                          ? g.steamId
                                          : null,
                                    ),
                                    _divider(),
                                    _field(
                                      "Bangumi ID",
                                      _bgm,
                                      icon: Icons.tag,
                                      sourceId: g.bangumiId != null &&
                                              g.bangumiId!.isNotEmpty
                                          ? g.bangumiId
                                          : null,
                                    ),
                                    _divider(),
                                    SwitchListTile.adaptive(
                                      contentPadding: EdgeInsets.zero,
                                      secondary: const Icon(
                                        Icons.visibility_off_outlined,
                                      ),
                                      title: const Text("NSFW 内容"),
                                      subtitle: const Text("启用后封面和背景默认模糊"),
                                      value: _isNsfw,
                                      onChanged: (value) =>
                                          setState(() => _isNsfw = value),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 20),
                                _section("版本", Icons.folder_outlined),
                                if (_versions.isEmpty)
                                  _hintCard("暂无版本信息")
                                else ...[
                                  _fieldCard(
                                    children: _versions.asMap().entries.map((
                                      e,
                                    ) {
                                      final v = e.value;
                                      final isLast =
                                          e.key == _versions.length - 1;
                                      return Column(
                                        children: [
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 10,
                                            ),
                                            child: Row(
                                              children: [
                                                Icon(
                                                  Icons
                                                      .insert_drive_file_outlined,
                                                  size: 18,
                                                  color: hintColor(context),
                                                ),
                                                const SizedBox(width: 10),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Text(
                                                        v.filename,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: const TextStyle(
                                                          fontSize: 14,
                                                        ),
                                                      ),
                                                      const SizedBox(height: 2),
                                                      Text(
                                                        _versionSourceDetail(v),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: AppText.caption
                                                            .copyWith(
                                                          color: hintColor(
                                                              context),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    horizontal: 10,
                                                    vertical: 4,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                      12,
                                                    ),
                                                    color: _platformColor(
                                                      v.platform,
                                                    ).withValues(alpha: 0.15),
                                                  ),
                                                  child: Text(
                                                    v.platform,
                                                    style:
                                                        AppText.label.copyWith(
                                                      fontWeight:
                                                          FontWeight.w500,
                                                      color: _platformColor(
                                                        v.platform,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                PopupMenuButton<String>(
                                                  icon: const Icon(
                                                    Icons.more_vert,
                                                    size: 18,
                                                  ),
                                                  onSelected: (action) {
                                                    if (action == "move")
                                                      _moveVersionDialog(v);
                                                    if (action == "platform")
                                                      _changeVersionPlatform(v);
                                                    if (action == "password")
                                                      _changeVersionPassword(v);
                                                  },
                                                  itemBuilder: (_) => const [
                                                    PopupMenuItem(
                                                      value: "platform",
                                                      child: Text("修改平台"),
                                                    ),
                                                    PopupMenuItem(
                                                      value: "password",
                                                      child: Text("预填解压密码"),
                                                    ),
                                                    PopupMenuItem(
                                                      value: "move",
                                                      child: Text("移动到其他游戏..."),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                          if (!isLast) _divider(),
                                        ],
                                      );
                                    }).toList(),
                                  ),
                                  const SizedBox(height: 8),
                                  OutlinedButton.icon(
                                    icon: const Icon(Icons.merge, size: 16),
                                    label: const Text("合并到其他游戏..."),
                                    onPressed: _mergeGameDialog,
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(width: 28),
                          // Right: description + notes
                          Expanded(
                            flex: 4,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _section("简介", Icons.description_outlined),
                                TextField(
                                  controller: _desc,
                                  maxLines: 8,
                                  decoration: _dec(
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    hintText: "游戏简介...",
                                  ),
                                  style: AppText.body.copyWith(height: 1.6),
                                ),
                                const SizedBox(height: 20),
                                _section("备注", Icons.note_outlined),
                                TextField(
                                  controller: _notes,
                                  maxLines: 4,
                                  decoration: _dec(
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    hintText: "个人备注...",
                                  ),
                                  style: AppText.body.copyWith(height: 1.6),
                                ),
                                // hero moved to top,
                              ],
                            ),
                          ),
                        ],
                      )
                    else
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _section("简介", Icons.description_outlined),
                          TextField(
                            controller: _desc,
                            maxLines: 8,
                            decoration: _dec(
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              hintText: "游戏简介...",
                            ),
                            style: AppText.body.copyWith(height: 1.6),
                          ),
                          const SizedBox(height: 20),
                          _section("详细信息", Icons.info_outline),
                          _fieldCard(
                            children: [
                              _field(
                                "开发商",
                                _dev,
                                icon: Icons.business,
                                sourceId: g.vndbId,
                              ),
                              _divider(),
                              _field(
                                "发售日",
                                _date,
                                icon: Icons.calendar_today,
                                sourceId: g.vndbId,
                              ),
                              _divider(),
                              _field(
                                "VNDB ID",
                                _vndb,
                                icon: Icons.tag,
                                sourceId:
                                    g.vndbId != null && g.vndbId!.isNotEmpty
                                        ? g.vndbId
                                        : null,
                              ),
                              _divider(),
                              _field(
                                "Steam ID",
                                _steam,
                                icon: Icons.tag,
                                sourceId:
                                    g.steamId != null && g.steamId!.isNotEmpty
                                        ? g.steamId
                                        : null,
                              ),
                              _divider(),
                              _field(
                                "Bangumi ID",
                                _bgm,
                                icon: Icons.tag,
                                sourceId: g.bangumiId != null &&
                                        g.bangumiId!.isNotEmpty
                                    ? g.bangumiId
                                    : null,
                              ),
                              _divider(),
                              SwitchListTile.adaptive(
                                contentPadding: EdgeInsets.zero,
                                secondary: const Icon(
                                  Icons.visibility_off_outlined,
                                ),
                                title: const Text("NSFW 内容"),
                                subtitle: const Text("启用后封面和背景默认模糊"),
                                value: _isNsfw,
                                onChanged: (value) =>
                                    setState(() => _isNsfw = value),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          _section("版本", Icons.folder_outlined),
                          if (_versions.isEmpty)
                            _hintCard("暂无版本信息")
                          else ...[
                            _fieldCard(
                              children: _versions.asMap().entries.map((e) {
                                final v = e.value;
                                final isLast = e.key == _versions.length - 1;
                                return Column(
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 10,
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.insert_drive_file_outlined,
                                            size: 18,
                                            color: hintColor(context),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  v.filename,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 14,
                                                  ),
                                                ),
                                                const SizedBox(height: 2),
                                                Text(
                                                  _versionSourceDetail(v),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style:
                                                      AppText.caption.copyWith(
                                                    color: hintColor(context),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              color: _platformColor(
                                                v.platform,
                                              ).withValues(alpha: 0.15),
                                            ),
                                            child: Text(
                                              v.platform,
                                              style: AppText.label.copyWith(
                                                fontWeight: FontWeight.w500,
                                                color: _platformColor(
                                                  v.platform,
                                                ),
                                              ),
                                            ),
                                          ),
                                          PopupMenuButton<String>(
                                            icon: const Icon(
                                              Icons.more_vert,
                                              size: 18,
                                            ),
                                            onSelected: (action) {
                                              if (action == "move")
                                                _moveVersionDialog(v);
                                              if (action == "platform")
                                                _changeVersionPlatform(v);
                                              if (action == "password")
                                                _changeVersionPassword(v);
                                            },
                                            itemBuilder: (_) => const [
                                              PopupMenuItem(
                                                value: "platform",
                                                child: Text("修改平台"),
                                              ),
                                              PopupMenuItem(
                                                value: "password",
                                                child: Text("预填解压密码"),
                                              ),
                                              PopupMenuItem(
                                                value: "move",
                                                child: Text("移动到其他游戏..."),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (!isLast) _divider(),
                                  ],
                                );
                              }).toList(),
                            ),
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                              icon: const Icon(Icons.merge, size: 16),
                              label: const Text("合并到其他游戏..."),
                              onPressed: _mergeGameDialog,
                            ),
                          ],
                          const SizedBox(height: 20),
                          _section("备注", Icons.note_outlined),
                          TextField(
                            controller: _notes,
                            maxLines: 4,
                            decoration: _dec(
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              hintText: "个人备注...",
                            ),
                            style: AppText.body.copyWith(height: 1.6),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bgHeroPreview() {
    if (_pendingBgFilePath != null) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: Image.file(
          File(_pendingBgFilePath!),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            color: placeholderBg(context),
            child: Center(
              child: Icon(
                Icons.broken_image,
                size: 48,
                color: placeholderIcon(context),
              ),
            ),
          ),
        ),
      );
    }
    if (_bgUrl.text.isEmpty) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          color: placeholderBg(context),
          child: Center(
            child: Icon(Icons.image, size: 48, color: placeholderIcon(context)),
          ),
        ),
      );
    }
    final url = _bgUrl.text.startsWith("http")
        ? _bgUrl.text
        : "$_baseUrl/api/files/backgrounds/${_bgUrl.text.split("/").last}?v=$_bgVersion";
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Image.network(
        url,
        headers: url.contains("/api/files/") ? mediaAuthHeaders : null,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          color: placeholderBg(context),
          child: Center(
            child: Icon(
              Icons.broken_image,
              size: 48,
              color: placeholderIcon(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _coverPlaceholder() => Container(
        decoration: BoxDecoration(
          color: placeholderBg(context),
          borderRadius: BorderRadius.circular(12),
        ),
        width: 200,
        height: 280,
        child: Center(
          child: Icon(Icons.image, size: 64, color: placeholderIcon(context)),
        ),
      );

  Widget _coverPlaceholderSmall() => Container(
        width: 90,
        height: 120,
        decoration: BoxDecoration(
          color: placeholderBg(context),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Icon(Icons.image, size: 32, color: placeholderIcon(context)),
        ),
      );

  String _versionSourceLabel(GameVersion version) {
    final type = version.sourceType.trim().toLowerCase();
    return switch (type) {
      "openlist" => "OpenList",
      "local" => "本地",
      "steam_patch" => "Steam 补丁库",
      "" => "本地",
      _ => version.sourceType,
    };
  }

  String _versionSourceDetail(GameVersion version) {
    final label = _versionSourceLabel(version);
    final path = version.sourcePath?.trim();
    if (path != null && path.isNotEmpty) return "$label · $path";
    return label;
  }

  Widget _sourceBadge(String label, String? id) {
    final active = id != null && id.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color:
              active ? Colors.green.withValues(alpha: 0.15) : cardBg(context),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color:
                active ? Colors.green.withValues(alpha: 0.35) : Colors.white24,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (active)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(
                  Icons.check_circle,
                  size: 12,
                  color: Colors.green[300],
                ),
              ),
            Text(
              label,
              style: AppText.label.copyWith(
                fontWeight: FontWeight.w500,
                color: active ? Colors.green[300] : Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Single unified download: search all sources → show results → compare → apply ──

  // ── Single unified download: search all sources → show results → compare → apply ──

  String _imageExtFrom(String url, String? contentType) {
    final type = (contentType ?? "").toLowerCase();
    if (type.contains("png")) return ".png";
    if (type.contains("webp")) return ".webp";
    if (type.contains("gif")) return ".gif";
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? "";
    for (final ext in [".jpg", ".jpeg", ".png", ".webp", ".gif"]) {
      if (path.endsWith(ext)) return ext;
    }
    return ".jpg";
  }

  Future<void> _promptImageUrl({required bool cover}) async {
    final ctrl = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(cover ? "封面 URL" : "背景 URL"),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: "图片 URL",
            hintText: "https://example.com/image.jpg",
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text("下载"),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    await _stageImageFromUrl(url, cover: cover);
  }

  Future<void> _stageImageFromUrl(String url, {required bool cover}) async {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != "http" && uri.scheme != "https")) {
      _showError("请输入 http 或 https 图片链接");
      return;
    }
    _showLoadingDialog();
    try {
      final resp = await http.get(uri).timeout(const Duration(seconds: 30));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception("HTTP ${resp.statusCode}");
      }
      final contentType = resp.headers["content-type"] ?? "";
      if (contentType.isNotEmpty &&
          !contentType.toLowerCase().startsWith("image/")) {
        throw Exception("链接返回的不是图片");
      }
      if (resp.bodyBytes.length > 20 * 1024 * 1024) {
        throw Exception("图片不能超过 20 MB");
      }
      final dir = await getTemporaryDirectory();
      final ext = _imageExtFrom(url, contentType);
      final file = File(
        "${dir.path}/sena_${widget.game.id}_${cover ? "cover" : "bg"}_${DateTime.now().millisecondsSinceEpoch}$ext",
      );
      await file.writeAsBytes(resp.bodyBytes, flush: true);
      if (!mounted) return;
      setState(() {
        if (cover) {
          _pendingCoverUrl = url;
          _pendingCoverFilePath = file.path;
          _coverVersion = DateTime.now().millisecondsSinceEpoch;
        } else {
          _pendingBgFilePath = file.path;
          _bgVersion = DateTime.now().millisecondsSinceEpoch;
        }
      });
      Navigator.pop(context);
    } catch (e) {
      if (mounted) Navigator.pop(context);
      _showError("图片下载失败: $e");
    }
  }

  Future<String?> _uploadLocalImage(String path, {required bool cover}) async {
    final endpoint = cover ? "cover" : "background";
    final field = cover ? "cover_path" : "bg_path";
    final request = http.MultipartRequest(
      "POST",
      Uri.parse("$_baseUrl/api/games/${widget.game.id}/$endpoint/upload"),
    );
    _authHeaders.forEach((k, v) => request.headers[k] = v);
    request.files.add(await http.MultipartFile.fromPath("file", path));
    final streamed = await request.send();
    final text = await streamed.stream.bytesToString();
    if (streamed.statusCode != 200) {
      throw Exception("图片上传失败 (${streamed.statusCode}): $text");
    }
    final data = jsonDecode(text) as Map<String, dynamic>;
    return data[field]?.toString();
  }

  Future<void> _pickLocalBg() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      if (result == null ||
          result.files.isEmpty ||
          result.files.first.path == null) return;
      final request = http.MultipartRequest(
        "POST",
        Uri.parse("$_baseUrl/api/games/${widget.game.id}/background/upload"),
      );
      _authHeaders.forEach((k, v) => request.headers[k] = v);
      request.files.add(
        await http.MultipartFile.fromPath("file", result.files.first.path!),
      );
      final streamed = await request.send();
      if (streamed.statusCode == 200) {
        final data = jsonDecode(await streamed.stream.bytesToString())
            as Map<String, dynamic>;
        if (data["bg_path"] != null) {
          setState(() {
            _bgUrl.text = data["bg_path"];
            _bgVersion = DateTime.now().millisecondsSinceEpoch;
          });
        }
        _showMsg("大图上传成功");
      } else {
        _showError("上传失败");
      }
    } catch (e) {
      _showError("上传失败: $e");
    }
  }

  Future<void> _pickLocalCover() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      if (result == null ||
          result.files.isEmpty ||
          result.files.first.path == null) return;
      final request = http.MultipartRequest(
        "POST",
        Uri.parse("$_baseUrl/api/games/${widget.game.id}/cover/upload"),
      );
      _authHeaders.forEach((k, v) => request.headers[k] = v);
      request.files.add(
        await http.MultipartFile.fromPath("file", result.files.first.path!),
      );
      final streamed = await request.send();
      if (streamed.statusCode == 200) {
        final data = jsonDecode(await streamed.stream.bytesToString())
            as Map<String, dynamic>;
        if (data["cover_path"] != null) {
          setState(() {
            _coverPath = data["cover_path"];
            _coverVersion = DateTime.now().millisecondsSinceEpoch;
          });
        }
        _showMsg("封面上传成功");
      }
    } catch (e) {
      _showError("上传失败: $e");
    }
  }

  Future<void> _downloadMetadata() async {
    // Step 1: Pick source
    final sources = {
      "vndb_kana": "VNDB Kana v2",
      "bangumi": "Bangumi",
      "steam": "Steam",
      "hikarinagi": "Hikarinagi",
    };
    final src = await showDialog<String>(
      context: context,
      builder: (ctx) => _MetadataSourceDialog(sources: sources),
    );
    if (src == null || !mounted) return;

    // Step 2: Search with inline loading + results
    final picked = await showDialog<Object?>(
      context: context,
      builder: (ctx) => _MetadataSearchDialog(
        sourceName: sources[src] ?? src,
        initialQuery: _name.text,
        onSearch: (query) => _searchMetadataSource(src, query),
      ),
    );
    if (picked == "retry") {
      await _downloadMetadata();
      return;
    }
    if (picked == null || !mounted) return;
    final r = picked as Map<String, dynamic>;

    // Step 2.5: If multiple screenshots, let user pick hero image.
    final screenshots =
        (r["screenshots"] as List<dynamic>?)?.cast<String>() ?? [];
    if (screenshots.length > 1) {
      final pickedHero = await _pickHeroImage(
        screenshots,
        sourceName: sources[src] ?? src,
      );
      if (pickedHero != null) {
        r["hero_url"] = pickedHero;
      }
    }

    // Step 3: Preload cover image before showing comparison
    final coverUrl = (r["cover_url"] ?? "").toString();
    if (coverUrl.isNotEmpty) {
      final preloadDone = Completer<void>();
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
          canPop: false,
          child: AlertDialog(
            title: const Text("加载中..."),
            content: SizedBox(
              width: 200,
              height: 100,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Image.network(
                    coverUrl,
                    width: 90,
                    height: 120,
                    fit: BoxFit.cover,
                    loadingBuilder: (_, child, progress) {
                      if (progress == null) {
                        preloadDone.complete();
                        return child;
                      }
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(
                            value: progress.expectedTotalBytes != null
                                ? progress.cumulativeBytesLoaded /
                                    progress.expectedTotalBytes!
                                : null,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            "${(progress.cumulativeBytesLoaded / 1024).toStringAsFixed(0)} KB",
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      );
                    },
                    errorBuilder: (_, __, ___) {
                      preloadDone.complete();
                      return const SizedBox.shrink();
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await preloadDone.future;
      if (mounted) Navigator.pop(context);
    }

    // Step 4: Per-field comparison
    final fields = {"名称": _name, "开发商": _dev, "日期": _date, "简介": _desc};
    final incoming = {
      "名称": (r["title"] ?? "").toString(),
      "开发商": (r["developer"] ?? "").toString(),
      "日期": (r["release_date"] ?? "").toString(),
      "简介": (r["description"] ?? "").toString(),
    };
    final heroUrl = (r["hero_url"] ?? "").toString();
    final hasCoverDiff = coverUrl.isNotEmpty;
    final hasHeroDiff = heroUrl.isNotEmpty && heroUrl != _bgUrl.text;
    // Build initial selection state (outside StatefulBuilder so it persists across rebuilds)
    final useSearch = <String, bool>{};
    for (final f in fields.keys) {
      useSearch[f] = incoming[f]!.isNotEmpty && incoming[f] != fields[f]!.text;
    }
    useSearch["封面"] = hasCoverDiff;
    useSearch["背景"] = hasHeroDiff;

    final currentCoverUrl = _coverPath != null
        ? "$_baseUrl/api/files/covers${_coverPath!}?v=$_coverVersion"
        : "";
    final currentHeroUrl = _bgUrl.text.isEmpty
        ? ""
        : _bgUrl.text.startsWith("http")
            ? _bgUrl.text
            : "$_baseUrl/api/files/backgrounds/${_bgUrl.text.split("/").last}?v=$_bgVersion";

    final confirmed = await showDialog<Map<String, bool>?>(
      context: context,
      builder: (ctx) => _MetadataApplyDialog(
        sourceName: sources[src] ?? src,
        currentFields: {
          for (final entry in fields.entries) entry.key: entry.value.text,
        },
        incomingFields: incoming,
        initialSelection: useSearch,
        imageComparisons: [
          if (hasCoverDiff)
            _MetadataApplyImage(
              key: "封面",
              title: "封面",
              currentLabel: "当前封面",
              sourceLabel: "${sources[src] ?? src} 封面",
              currentUrl: currentCoverUrl,
              sourceUrl: coverUrl,
              currentHeaders: mediaAuthHeaders,
              aspectRatio: 3 / 4,
              icon: Icons.image_outlined,
            ),
          if (hasHeroDiff)
            _MetadataApplyImage(
              key: "背景",
              title: "背景",
              currentLabel: "当前背景",
              sourceLabel: "${sources[src] ?? src} 背景",
              currentUrl: currentHeroUrl,
              sourceUrl: heroUrl,
              currentHeaders: currentHeroUrl.contains("/api/files/")
                  ? mediaAuthHeaders
                  : null,
              aspectRatio: 16 / 9,
              icon: Icons.wallpaper_outlined,
            ),
        ],
      ),
    );
    if (confirmed == null || !mounted) return;

    if (confirmed is! Map<String, bool>) return;
    // Apply only selected fields to form
    final apply = confirmed as Map<String, bool>;
    setState(() {
      if (apply["名称"] == true) _name.text = incoming["名称"]!;
      if (apply["开发商"] == true) _dev.text = incoming["开发商"]!;
      if (apply["日期"] == true) _date.text = incoming["日期"]!;
      if (apply["简介"] == true) _desc.text = incoming["简介"]!;
      if (r["is_nsfw"] == true) _isNsfw = true;
      final sf = {"vndb_kana": _vndb, "bangumi": _bgm, "steam": _steam};
      if (sf.containsKey(src) && (r["source_id"] ?? "").toString().isNotEmpty) {
        sf[src]!.text = r["source_id"].toString();
      }
    });
    if (apply["背景"] == true && heroUrl.isNotEmpty) {
      await _stageImageFromUrl(heroUrl, cover: false);
    }
    if (apply["封面"] == true && coverUrl.isNotEmpty) {
      await _stageImageFromUrl(coverUrl, cover: true);
    }
    if (mounted) setState(() {});
    // Don't auto-save — user may want to edit further before committing
  }

  @override
  void dispose() {
    for (final controller in [
      _dev,
      _desc,
      _date,
      _vndb,
      _steam,
      _bgm,
      _bgUrl
    ]) {
      controller.removeListener(_onMetadataEdited);
    }
    _name.dispose();
    _dev.dispose();
    _desc.dispose();
    _date.dispose();
    _vndb.dispose();
    _steam.dispose();
    _bgm.dispose();
    _bgUrl.dispose();
    _notes.dispose();
    super.dispose();
  }

  InputDecoration _dec({
    InputBorder? border,
    bool isDense = true,
    EdgeInsetsGeometry? contentPadding,
    String? hintText,
    String? labelText,
  }) {
    return InputDecoration(
      filled: true,
      fillColor: cardBg(context),
      border: border,
      isDense: isDense,
      contentPadding: contentPadding,
      hintText: hintText,
      labelText: labelText,
    );
  }

  Future<String?> _pickHeroImage(
    List<String> screenshots, {
    required String sourceName,
  }) {
    final isCompact = MediaQuery.sizeOf(context).width < 600;
    if (isCompact) {
      return showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => _HeroBackgroundPickerSheet(
          screenshots: screenshots,
          sourceName: sourceName,
        ),
      );
    }
    return showDialog<String>(
      context: context,
      builder: (ctx) => _HeroBackgroundPickerDialog(
        screenshots: screenshots,
        sourceName: sourceName,
      ),
    );
  }
}

class _MetadataSourceDialog extends StatelessWidget {
  final Map<String, String> sources;

  const _MetadataSourceDialog({required this.sources});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width > 540
        ? 500.0
        : MediaQuery.sizeOf(context).width - 32;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: SizedBox(
        width: width,
        child: AppSurface(
          radius: AppRadius.xl,
          blur: true,
          padding: EdgeInsets.zero,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
                child: Row(
                  children: [
                    _MetadataDialogIcon(
                      icon: Icons.travel_explore_rounded,
                      color: cs.primary,
                    ),
                    const SizedBox(width: AppGap.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("选择元数据来源", style: AppText.headline),
                          const SizedBox(height: 4),
                          Text(
                            "从可用来源中选择一个，然后搜索游戏条目。",
                            style: AppText.bodySmall.copyWith(
                              color: hintColor(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                    AppStatusPill(
                      icon: Icons.hub_outlined,
                      label: "${sources.length} 个来源",
                      color: cs.primary,
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: cardBorder(context)),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  itemCount: sources.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(height: AppGap.sm),
                  itemBuilder: (context, index) {
                    final entry = sources.entries.elementAt(index);
                    return _MetadataSourceTile(
                      label: entry.value,
                      selected: false,
                      onTap: () => Navigator.pop<String>(context, entry.key),
                    );
                  },
                ),
              ),
              Divider(height: 1, color: cardBorder(context)),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    AppActionButton(
                      icon: Icons.close_rounded,
                      label: "取消",
                      color: hintColor(context),
                      onPressed: () => Navigator.pop(context),
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

class _MetadataSearchDialog extends StatefulWidget {
  final String sourceName;
  final String initialQuery;
  final Future<List<Map<String, dynamic>>> Function(String) onSearch;

  const _MetadataSearchDialog({
    required this.sourceName,
    required this.initialQuery,
    required this.onSearch,
  });

  @override
  State<_MetadataSearchDialog> createState() => _MetadataSearchDialogState();
}

class _MetadataSearchDialogState extends State<_MetadataSearchDialog> {
  late final TextEditingController _controller;
  List<Map<String, dynamic>> _results = const [];
  bool _loading = false;
  bool _searched = false;
  String? _error;
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery.trim());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _controller.text.trim().isEmpty) return;
      _search();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty) {
      setState(() {
        _searched = true;
        _loading = false;
        _results = const [];
        _error = "请输入搜索关键词";
      });
      return;
    }

    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _searched = true;
      _results = const [];
      _error = null;
    });

    try {
      final results = await widget.onSearch(query);
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _error = "搜索失败，请稍后重试";
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final width = size.width > 680 ? 620.0 : size.width - 32;
    final height = size.height > 640 ? 560.0 : size.height - 32;
    final statusLabel = _loading
        ? "搜索中"
        : _error != null
            ? "失败"
            : _results.isNotEmpty
                ? "${_results.length} 项"
                : widget.sourceName;
    final statusColor = _error != null
        ? cs.error
        : _results.isNotEmpty
            ? Colors.green
            : cs.primary;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: SizedBox(
        width: width,
        height: height,
        child: AppSurface(
          radius: AppRadius.xl,
          blur: true,
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
                child: Row(
                  children: [
                    _MetadataDialogIcon(
                      icon: Icons.search_rounded,
                      color: cs.primary,
                    ),
                    const SizedBox(width: AppGap.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("搜索 ${widget.sourceName}", style: AppText.headline),
                          const SizedBox(height: 4),
                          Text(
                            "输入名称或 ID，选择要导入的匹配条目。",
                            style: AppText.bodySmall.copyWith(
                              color: hintColor(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                    AppStatusPill(
                      icon: _loading
                          ? Icons.sync_rounded
                          : _error != null
                              ? Icons.error_outline_rounded
                              : Icons.manage_search_rounded,
                      label: statusLabel,
                      color: statusColor,
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: cardBorder(context)),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  enabled: !_loading,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: cardBg(context),
                    labelText: "名称或 ID",
                    hintText: "输入后回车搜索",
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: IconButton(
                      tooltip: "搜索",
                      icon: const Icon(Icons.arrow_forward_rounded),
                      onPressed: _loading ? null : _search,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    isDense: true,
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                  child: _buildBody(context),
                ),
              ),
              Divider(height: 1, color: cardBorder(context)),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    AppActionButton(
                      icon: Icons.close_rounded,
                      label: "取消",
                      color: hintColor(context),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: AppGap.sm),
                    AppActionButton(
                      icon: Icons.swap_horiz_rounded,
                      label: "更换来源",
                      color: Colors.orange,
                      onPressed: _loading
                          ? null
                          : () => Navigator.pop<Object?>(context, "retry"),
                    ),
                    const SizedBox(width: AppGap.sm),
                    AppActionButton(
                      icon: Icons.search_rounded,
                      label: "搜索",
                      filled: true,
                      busy: _loading,
                      onPressed: _loading ? null : _search,
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

  Widget _buildBody(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loading) {
      return const _MetadataStateMessage(
        icon: Icons.sync_rounded,
        title: "正在搜索",
        message: "请稍候，正在获取候选元数据。",
        showProgress: true,
      );
    }
    if (_error != null) {
      return _MetadataStateMessage(
        icon: Icons.error_outline_rounded,
        title: "搜索失败",
        message: _error!,
        color: cs.error,
        action: AppActionButton(
          icon: Icons.refresh_rounded,
          label: "重试搜索",
          filled: true,
          onPressed: _search,
        ),
      );
    }
    if (!_searched) {
      return _MetadataStateMessage(
        icon: Icons.travel_explore_rounded,
        title: "准备搜索",
        message: "确认关键词后开始搜索 ${widget.sourceName}。",
      );
    }
    if (_results.isEmpty) {
      return const _MetadataStateMessage(
        icon: Icons.search_off_rounded,
        title: "没有结果",
        message: "未找到匹配条目，请调整关键词后重试。",
      );
    }

    return ListView.separated(
      itemCount: _results.length,
      separatorBuilder: (_, __) => const SizedBox(height: AppGap.sm),
      itemBuilder: (context, index) => _MetadataResultTile(
        result: _results[index],
        onTap: () => Navigator.pop<Object?>(
          context,
          _results[index],
        ),
      ),
    );
  }
}

class _MetadataSourceTile extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _MetadataSourceTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: selected ? cs.primary.withValues(alpha: 0.12) : cardBg(context),
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: cardBorder(context)),
          ),
          child: Row(
            children: [
              Icon(Icons.public_rounded, size: 20, color: cs.primary),
              const SizedBox(width: AppGap.md),
              Expanded(
                child: Text(
                  label,
                  style: AppText.bodyMedium.copyWith(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: hintColor(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetadataResultTile extends StatelessWidget {
  final Map<String, dynamic> result;
  final VoidCallback onTap;

  const _MetadataResultTile({
    required this.result,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final title = _metadataText(result, const ["title", "name"]);
    final developer = _metadataText(result, const ["developer", "brand"]);
    final releaseDate = _metadataText(
      result,
      const ["release_date", "date", "released"],
    );
    final coverUrl = _metadataText(result, const ["cover_url", "image", "image_url"]);

    return Material(
      color: cardBg(context),
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: cardBorder(context)),
          ),
          child: Row(
            children: [
              _MetadataCoverThumb(url: coverUrl),
              const SizedBox(width: AppGap.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title.isEmpty ? "未命名条目" : title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.bodyMedium.copyWith(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: AppGap.sm,
                      runSpacing: AppGap.xs,
                      children: [
                        if (developer.isNotEmpty)
                          _MetadataMiniPill(
                            icon: Icons.business_rounded,
                            label: developer,
                          ),
                        if (releaseDate.isNotEmpty)
                          _MetadataMiniPill(
                            icon: Icons.event_rounded,
                            label: releaseDate,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppGap.sm),
              Icon(Icons.chevron_right_rounded, color: hintColor(context)),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetadataCoverThumb extends StatelessWidget {
  final String url;

  const _MetadataCoverThumb({required this.url});

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: 58,
      height: 78,
      color: placeholderBg(context),
      alignment: Alignment.center,
      child: Icon(
        Icons.image_not_supported_outlined,
        color: placeholderIcon(context),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: url.isEmpty
          ? fallback
          : Image.network(
              url,
              key: ValueKey(url),
              width: 58,
              height: 78,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => fallback,
            ),
    );
  }
}

class _MetadataMiniPill extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MetadataMiniPill({
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: hintColor(context)),
          const SizedBox(width: 4),
          Text(
            label,
            style: AppText.caption.copyWith(color: hintColor(context)),
          ),
        ],
      ),
    );
  }
}

class _MetadataStateMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Color? color;
  final Widget? action;
  final bool showProgress;

  const _MetadataStateMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.color,
    this.action,
    this.showProgress = false,
  });

  @override
  Widget build(BuildContext context) {
    final base = color ?? Theme.of(context).colorScheme.primary;
    return Center(
      child: AppSurface(
        radius: AppRadius.lg,
        padding: const EdgeInsets.all(AppGap.lg),
        color: cardBg(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showProgress)
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.4, color: base),
              )
            else
              Icon(icon, size: 30, color: base),
            const SizedBox(height: AppGap.md),
            Text(
              title,
              style: AppText.title.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: AppGap.xs),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppText.bodySmall.copyWith(
                color: hintColor(context),
                height: 1.35,
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: AppGap.md),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

class _MetadataDialogIcon extends StatelessWidget {
  final IconData icon;
  final Color color;

  const _MetadataDialogIcon({
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Icon(icon, color: color, size: 21),
    );
  }
}

String _metadataText(Map<String, dynamic> result, List<String> keys) {
  for (final key in keys) {
    final value = result[key];
    if (value == null) continue;
    final text = value.toString().trim();
    if (text.isNotEmpty) return text;
  }
  return "";
}

class _MetadataApplyImage {
  final String key;
  final String title;
  final String currentLabel;
  final String sourceLabel;
  final String currentUrl;
  final String sourceUrl;
  final Map<String, String>? currentHeaders;
  final Map<String, String>? sourceHeaders;
  final double aspectRatio;
  final IconData icon;

  const _MetadataApplyImage({
    required this.key,
    required this.title,
    required this.currentLabel,
    required this.sourceLabel,
    required this.currentUrl,
    required this.sourceUrl,
    this.currentHeaders,
    this.sourceHeaders,
    required this.aspectRatio,
    required this.icon,
  });
}

class _MetadataApplyDialog extends StatefulWidget {
  final String sourceName;
  final Map<String, String> currentFields;
  final Map<String, String> incomingFields;
  final Map<String, bool> initialSelection;
  final List<_MetadataApplyImage> imageComparisons;

  const _MetadataApplyDialog({
    required this.sourceName,
    required this.currentFields,
    required this.incomingFields,
    required this.initialSelection,
    required this.imageComparisons,
  });

  @override
  State<_MetadataApplyDialog> createState() => _MetadataApplyDialogState();
}

class _MetadataApplyDialogState extends State<_MetadataApplyDialog> {
  late final Map<String, bool> _selection;

  @override
  void initState() {
    super.initState();
    _selection = Map<String, bool>.from(widget.initialSelection);
  }

  int get _selectedCount => _selection.values.where((value) => value).length;

  bool get _hasChanges {
    for (final key in widget.currentFields.keys) {
      if (_fieldHasDiff(key)) return true;
    }
    return widget.imageComparisons.isNotEmpty;
  }

  bool _fieldHasDiff(String key) {
    final current = widget.currentFields[key] ?? "";
    final incoming = widget.incomingFields[key] ?? "";
    return incoming.isNotEmpty && incoming != current;
  }

  void _setSelected(String key, bool value) {
    setState(() => _selection[key] = value);
  }

  Future<void> _showFullDescription(String title, String text) {
    final compact = MediaQuery.sizeOf(context).width < 640;
    if (compact) {
      return showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => _MetadataDescriptionSheet(
          title: title,
          description: text,
        ),
      );
    }
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: SizedBox(
          width: 620,
          height: 540,
          child: _MetadataDescriptionSurface(
            title: title,
            description: text,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final width = size.width > 980 ? 920.0 : size.width - 32;
    final height = size.height > 760 ? 700.0 : size.height - 32;
    final selectedCount = _selectedCount;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: SizedBox(
        width: width,
        height: height,
        child: AppSurface(
          radius: AppRadius.xl,
          blur: true,
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
                child: Row(
                  children: [
                    _MetadataDialogIcon(
                      icon: Icons.rule_rounded,
                      color: cs.primary,
                    ),
                    const SizedBox(width: AppGap.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "应用 ${widget.sourceName} 元数据",
                            style: AppText.headline,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            "对比当前字段和来源字段，勾选要写入编辑表单的项目。",
                            style: AppText.bodySmall.copyWith(
                              color: hintColor(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                    AppStatusPill(
                      icon: selectedCount > 0
                          ? Icons.check_circle_rounded
                          : Icons.info_outline_rounded,
                      label: selectedCount > 0
                          ? "已选 $selectedCount 项"
                          : _hasChanges
                              ? "未选择"
                              : "无变更",
                      color: selectedCount > 0
                          ? Colors.green
                          : _hasChanges
                              ? cs.primary
                              : hintColor(context),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: cardBorder(context)),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    if (!_hasChanges) ...[
                      const _MetadataStateMessage(
                        icon: Icons.check_circle_outline_rounded,
                        title: "没有可应用的变更",
                        message: "来源字段与当前编辑内容一致，或来源未提供可写入内容。",
                      ),
                      const SizedBox(height: AppGap.md),
                    ],
                    ...widget.currentFields.keys.map(
                      (key) => _MetadataApplyFieldRow(
                        field: key,
                        currentValue: widget.currentFields[key] ?? "",
                        sourceValue: widget.incomingFields[key] ?? "",
                        sourceName: widget.sourceName,
                        selected: _selection[key] ?? false,
                        enabled: _fieldHasDiff(key),
                        onChanged: (value) => _setSelected(key, value),
                        onShowDescription: _showFullDescription,
                      ),
                    ),
                    if (widget.imageComparisons.isNotEmpty) ...[
                      const SizedBox(height: AppGap.sm),
                      Text(
                        "图片资源",
                        style: AppText.section.copyWith(
                          color: sectionTextColor(context),
                        ),
                      ),
                      const SizedBox(height: AppGap.md),
                      ...widget.imageComparisons.map(
                        (image) => _MetadataApplyImageCard(
                          comparison: image,
                          selected: _selection[image.key] ?? false,
                          onChanged: (value) => _setSelected(image.key, value),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Divider(height: 1, color: cardBorder(context)),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    AppActionButton(
                      icon: Icons.close_rounded,
                      label: "取消",
                      color: hintColor(context),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: AppGap.sm),
                    AppActionButton(
                      icon: Icons.check_rounded,
                      label: "应用所选",
                      filled: true,
                      onPressed: selectedCount == 0
                          ? null
                          : () => Navigator.pop<Map<String, bool>>(
                                context,
                                Map<String, bool>.from(_selection),
                              ),
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

class _MetadataApplyFieldRow extends StatelessWidget {
  final String field;
  final String currentValue;
  final String sourceValue;
  final String sourceName;
  final bool selected;
  final bool enabled;
  final ValueChanged<bool> onChanged;
  final void Function(String title, String text) onShowDescription;

  const _MetadataApplyFieldRow({
    required this.field,
    required this.currentValue,
    required this.sourceValue,
    required this.sourceName,
    required this.selected,
    required this.enabled,
    required this.onChanged,
    required this.onShowDescription,
  });

  bool get _isDescription => field == "简介";

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: AppGap.md),
      padding: const EdgeInsets.all(AppGap.md),
      decoration: BoxDecoration(
        color: cardBg(context),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: enabled
              ? Colors.green.withValues(alpha: 0.25)
              : cardBorder(context),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  field,
                  style: AppText.bodyMedium.copyWith(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              AppStatusPill(
                icon: enabled
                    ? Icons.compare_arrows_rounded
                    : Icons.check_circle_outline_rounded,
                label: enabled ? "有变更" : "一致",
                color: enabled ? Colors.green : hintColor(context),
              ),
              const SizedBox(width: AppGap.sm),
              _MetadataApplyCheckbox(
                label: "应用",
                value: selected,
                enabled: enabled,
                onChanged: onChanged,
              ),
            ],
          ),
          const SizedBox(height: AppGap.md),
          _MetadataComparePanels(
            current: _MetadataTextPanel(
              label: "当前",
              text: currentValue,
              emptyText: "(空)",
              isDescription: _isDescription,
              onShowFull: currentValue.trim().isEmpty
                  ? null
                  : () => onShowDescription("当前简介", currentValue),
            ),
            source: _MetadataTextPanel(
              label: sourceName,
              text: sourceValue,
              emptyText: "(来源未提供)",
              isDescription: _isDescription,
              highlighted: enabled,
              onShowFull: sourceValue.trim().isEmpty
                  ? null
                  : () => onShowDescription("$sourceName 简介", sourceValue),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetadataApplyImageCard extends StatelessWidget {
  final _MetadataApplyImage comparison;
  final bool selected;
  final ValueChanged<bool> onChanged;

  const _MetadataApplyImageCard({
    required this.comparison,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: AppGap.md),
      padding: const EdgeInsets.all(AppGap.md),
      decoration: BoxDecoration(
        color: cardBg(context),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: Colors.green.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(comparison.icon, size: 20, color: cs.primary),
              const SizedBox(width: AppGap.sm),
              Expanded(
                child: Text(
                  comparison.title,
                  style: AppText.bodyMedium.copyWith(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              AppStatusPill(
                icon: Icons.compare_arrows_rounded,
                label: "有变更",
                color: Colors.green,
              ),
              const SizedBox(width: AppGap.sm),
              _MetadataApplyCheckbox(
                label: "应用",
                value: selected,
                enabled: true,
                onChanged: onChanged,
              ),
            ],
          ),
          const SizedBox(height: AppGap.md),
          _MetadataComparePanels(
            current: _MetadataImagePanel(
              label: comparison.currentLabel,
              url: comparison.currentUrl,
              headers: comparison.currentHeaders,
              aspectRatio: comparison.aspectRatio,
            ),
            source: _MetadataImagePanel(
              label: comparison.sourceLabel,
              url: comparison.sourceUrl,
              headers: comparison.sourceHeaders,
              aspectRatio: comparison.aspectRatio,
              highlighted: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetadataComparePanels extends StatelessWidget {
  final Widget current;
  final Widget source;

  const _MetadataComparePanels({
    required this.current,
    required this.source,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 560;
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              current,
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppGap.sm),
                child: Icon(
                  Icons.arrow_downward_rounded,
                  color: Colors.green.withValues(alpha: 0.8),
                ),
              ),
              source,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: current),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 36, 12, 0),
              child: Icon(
                Icons.arrow_forward_rounded,
                color: Colors.green.withValues(alpha: 0.8),
              ),
            ),
            Expanded(child: source),
          ],
        );
      },
    );
  }
}

class _MetadataTextPanel extends StatelessWidget {
  final String label;
  final String text;
  final String emptyText;
  final bool isDescription;
  final bool highlighted;
  final VoidCallback? onShowFull;

  const _MetadataTextPanel({
    required this.label,
    required this.text,
    required this.emptyText,
    required this.isDescription,
    this.highlighted = false,
    this.onShowFull,
  });

  @override
  Widget build(BuildContext context) {
    final value = text.trim().isEmpty ? emptyText : text.trim();
    final preview = isDescription ? _metadataPreview(value, 120) : value;
    final baseColor = highlighted ? Colors.green : hintColor(context);
    return Container(
      padding: const EdgeInsets.all(AppGap.md),
      decoration: BoxDecoration(
        color: highlighted
            ? Colors.green.withValues(alpha: 0.06)
            : Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: highlighted
              ? Colors.green.withValues(alpha: 0.18)
              : cardBorder(context),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: AppText.caption.copyWith(
              color: baseColor,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: AppGap.sm),
          Text(
            preview,
            maxLines: isDescription ? 4 : 3,
            overflow: TextOverflow.ellipsis,
            style: AppText.bodySmall.copyWith(
              color: highlighted
                  ? Colors.green
                  : Theme.of(context).colorScheme.onSurface,
              height: 1.4,
            ),
          ),
          if (isDescription && onShowFull != null) ...[
            const SizedBox(height: AppGap.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: AppActionButton(
                icon: Icons.open_in_full_rounded,
                label: "查看完整简介",
                onPressed: onShowFull,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MetadataImagePanel extends StatelessWidget {
  final String label;
  final String url;
  final Map<String, String>? headers;
  final double aspectRatio;
  final bool highlighted;

  const _MetadataImagePanel({
    required this.label,
    required this.url,
    required this.headers,
    required this.aspectRatio,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final baseColor = highlighted ? Colors.green : hintColor(context);
    return Container(
      padding: const EdgeInsets.all(AppGap.sm),
      decoration: BoxDecoration(
        color: highlighted
            ? Colors.green.withValues(alpha: 0.06)
            : Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: highlighted
              ? Colors.green.withValues(alpha: 0.18)
              : cardBorder(context),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: AppText.caption.copyWith(
              color: baseColor,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: AppGap.sm),
          AspectRatio(
            aspectRatio: aspectRatio,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: url.isEmpty
                  ? _MetadataImagePlaceholder(aspectRatio: aspectRatio)
                  : Image.network(
                      url,
                      headers: headers,
                      fit: BoxFit.cover,
                      loadingBuilder: (_, child, progress) {
                        if (progress == null) return child;
                        return Container(
                          color: placeholderBg(context),
                          child: Center(
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              value: progress.expectedTotalBytes != null
                                  ? progress.cumulativeBytesLoaded /
                                      progress.expectedTotalBytes!
                                  : null,
                            ),
                          ),
                        );
                      },
                      errorBuilder: (_, __, ___) =>
                          _MetadataImagePlaceholder(aspectRatio: aspectRatio),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetadataImagePlaceholder extends StatelessWidget {
  final double aspectRatio;

  const _MetadataImagePlaceholder({required this.aspectRatio});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: placeholderBg(context),
      alignment: Alignment.center,
      child: Icon(
        Icons.image_not_supported_outlined,
        color: placeholderIcon(context),
        size: aspectRatio > 1 ? 34 : 28,
      ),
    );
  }
}

class _MetadataApplyCheckbox extends StatelessWidget {
  final String label;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _MetadataApplyCheckbox({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final color = enabled ? Theme.of(context).colorScheme.primary : hintColor(context);
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: enabled ? () => onChanged(!value) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: Checkbox(
                value: enabled ? value : false,
                onChanged: enabled ? (checked) => onChanged(checked ?? false) : null,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: AppText.bodySmall.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetadataDescriptionSheet extends StatelessWidget {
  final String title;
  final String description;

  const _MetadataDescriptionSheet({
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.82;
    return SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          height: height,
          child: _MetadataDescriptionSurface(
            title: title,
            description: description,
            sheet: true,
          ),
        ),
      ),
    );
  }
}

class _MetadataDescriptionSurface extends StatelessWidget {
  final String title;
  final String description;
  final bool sheet;

  const _MetadataDescriptionSurface({
    required this.title,
    required this.description,
    this.sheet = false,
  });

  @override
  Widget build(BuildContext context) {
    final radius = sheet ? 28.0 : AppRadius.xl;
    return AppSurface(
      radius: radius,
      blur: true,
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: sheet
            ? const BorderRadius.vertical(top: Radius.circular(28))
            : BorderRadius.circular(AppRadius.xl),
        child: Column(
          children: [
            if (sheet) ...[
              const SizedBox(height: AppGap.sm),
              Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
              child: Row(
                children: [
                  _MetadataDialogIcon(
                    icon: Icons.description_outlined,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: AppGap.md),
                  Expanded(
                    child: Text(
                      title,
                      style: AppText.title.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  AppActionButton(
                    icon: Icons.close_rounded,
                    label: "关闭",
                    color: hintColor(context),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: cardBorder(context)),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: SelectableText(
                  description.trim().isEmpty ? "(空)" : description.trim(),
                  style: AppText.body.copyWith(height: 1.65),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _metadataPreview(String text, int maxLength) {
  final normalized = text.trim().replaceAll(RegExp(r"\s+"), " ");
  if (normalized.length <= maxLength) return normalized;
  return "${normalized.substring(0, maxLength)}...";
}

class _HeroBackgroundPickerDialog extends StatefulWidget {
  final List<String> screenshots;
  final String sourceName;

  const _HeroBackgroundPickerDialog({
    required this.screenshots,
    required this.sourceName,
  });

  @override
  State<_HeroBackgroundPickerDialog> createState() =>
      _HeroBackgroundPickerDialogState();
}

class _HeroBackgroundPickerDialogState
    extends State<_HeroBackgroundPickerDialog> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final dialogWidth = size.width > 1008 ? 960.0 : size.width - 48;
    final dialogHeight = size.height > 728 ? 680.0 : size.height - 48;
    final selectedUrl = widget.screenshots[_selectedIndex];

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: AppSurface(
          radius: AppRadius.xl,
          blur: true,
          padding: EdgeInsets.zero,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
                  child: Row(
                    children: [
                      _HeroPickerIcon(color: cs.primary),
                      const SizedBox(width: AppGap.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "选择 ${widget.sourceName} 背景",
                              style: AppText.headline,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              "预览裁切效果，再选择要应用的背景。",
                              style: AppText.bodySmall.copyWith(
                                color: hintColor(context),
                              ),
                            ),
                          ],
                        ),
                      ),
                      AppStatusPill(
                        icon: Icons.collections_rounded,
                        label: "${widget.screenshots.length} 张",
                        color: Colors.green,
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: cardBorder(context)),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          flex: 3,
                          child: _HeroPreviewCard(
                            url: selectedUrl,
                            label: "当前预览：背景 ${_selectedIndex + 1}",
                            fillHeight: true,
                          ),
                        ),
                        const SizedBox(width: AppGap.lg),
                        SizedBox(
                          width: 286,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      "候选背景",
                                      style: AppText.section.copyWith(
                                        color: cs.onSurface,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    "点击切换预览",
                                    style: AppText.caption.copyWith(
                                      color: hintColor(context),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: AppGap.md),
                              Expanded(
                                child: ListView.separated(
                                  itemCount: widget.screenshots.length,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(height: AppGap.sm),
                                  itemBuilder: (context, index) =>
                                      _HeroCandidateTile(
                                    url: widget.screenshots[index],
                                    label: "背景 ${index + 1}",
                                    selected: index == _selectedIndex,
                                    onTap: () =>
                                        setState(() => _selectedIndex = index),
                                  ),
                                ),
                              ),
                              const SizedBox(height: AppGap.md),
                              const _HeroPickerHint(),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Divider(height: 1, color: cardBorder(context)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      AppActionButton(
                        icon: Icons.close_rounded,
                        label: "跳过",
                        color: hintColor(context),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const SizedBox(width: AppGap.sm),
                      AppActionButton(
                        icon: Icons.check_rounded,
                        label: "应用所选背景",
                        filled: true,
                        onPressed: () => Navigator.pop(context, selectedUrl),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroBackgroundPickerSheet extends StatefulWidget {
  final List<String> screenshots;
  final String sourceName;

  const _HeroBackgroundPickerSheet({
    required this.screenshots,
    required this.sourceName,
  });

  @override
  State<_HeroBackgroundPickerSheet> createState() =>
      _HeroBackgroundPickerSheetState();
}

class _HeroBackgroundPickerSheetState
    extends State<_HeroBackgroundPickerSheet> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final sheetHeight = size.height * (size.height < 720 ? 0.88 : 0.78);
    final selectedUrl = widget.screenshots[_selectedIndex];

    return SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Container(
            height: sheetHeight,
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
              border: Border(
                top: BorderSide(color: cardBorder(context)),
              ),
              boxShadow: [
                BoxShadow(
                  color: softShadowColor(context),
                  blurRadius: 30,
                  offset: const Offset(0, -10),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
              child: Column(
                children: [
                  const SizedBox(height: AppGap.sm),
                  Container(
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(
                      color: cs.outlineVariant,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
                    child: Row(
                      children: [
                        _HeroPickerIcon(color: cs.primary),
                        const SizedBox(width: AppGap.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "选择 ${widget.sourceName} 背景",
                                style: AppText.title.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                "预览裁切效果，再选择要应用的背景。",
                                style: AppText.caption.copyWith(
                                  color: hintColor(context),
                                ),
                              ),
                            ],
                          ),
                        ),
                        AppStatusPill(
                          icon: Icons.collections_rounded,
                          label: "${widget.screenshots.length} 张",
                          color: Colors.green,
                        ),
                      ],
                    ),
                  ),
                  Divider(height: 1, color: cardBorder(context)),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _HeroPreviewCard(
                            url: selectedUrl,
                            label: "当前预览：背景 ${_selectedIndex + 1}",
                          ),
                          const SizedBox(height: AppGap.lg),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  "候选背景",
                                  style: AppText.section.copyWith(
                                    color: cs.onSurface,
                                  ),
                                ),
                              ),
                              Text(
                                "横向滑动查看更多",
                                style: AppText.caption.copyWith(
                                  color: hintColor(context),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: AppGap.md),
                          SizedBox(
                            height: 92,
                            child: ListView.separated(
                              scrollDirection: Axis.horizontal,
                              itemCount: widget.screenshots.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(width: AppGap.sm),
                              itemBuilder: (context, index) =>
                                  _HeroCandidateTile(
                                url: widget.screenshots[index],
                                label: "背景 ${index + 1}",
                                selected: index == _selectedIndex,
                                width: 132,
                                onTap: () =>
                                    setState(() => _selectedIndex = index),
                              ),
                            ),
                          ),
                          const SizedBox(height: AppGap.md),
                          const _HeroPickerHint(),
                        ],
                      ),
                    ),
                  ),
                  Divider(height: 1, color: cardBorder(context)),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: AppActionButton(
                            icon: Icons.close_rounded,
                            label: "跳过",
                            color: hintColor(context),
                            onPressed: () => Navigator.pop(context),
                          ),
                        ),
                        const SizedBox(width: AppGap.sm),
                        Expanded(
                          flex: 2,
                          child: AppActionButton(
                            icon: Icons.check_rounded,
                            label: "应用所选背景",
                            filled: true,
                            onPressed: () =>
                                Navigator.pop(context, selectedUrl),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroPickerIcon extends StatelessWidget {
  final Color color;

  const _HeroPickerIcon({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Icon(Icons.wallpaper_rounded, color: color, size: 21),
    );
  }
}

class _HeroPreviewCard extends StatelessWidget {
  final String url;
  final String label;
  final bool fillHeight;

  const _HeroPreviewCard({
    required this.url,
    required this.label,
    this.fillHeight = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final image = ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: _HeroNetworkImage(url: url),
    );
    return AppSurface(
      radius: AppRadius.lg,
      padding: const EdgeInsets.all(AppGap.sm),
      color: cardBg(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (fillHeight)
            Expanded(child: image)
          else
            AspectRatio(aspectRatio: 16 / 9, child: image),
          const SizedBox(height: AppGap.sm),
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: AppText.caption.copyWith(
                    color: cs.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                "16:9 裁切",
                style: AppText.caption.copyWith(color: hintColor(context)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroCandidateTile extends StatelessWidget {
  final String url;
  final String label;
  final bool selected;
  final double? width;
  final VoidCallback onTap;

  const _HeroCandidateTile({
    required this.url,
    required this.label,
    required this.selected,
    required this.onTap,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: Material(
        color: selected ? cs.primary.withValues(alpha: 0.12) : cardBg(context),
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: onTap,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            curve: AppMotion.curve,
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: selected ? cs.primary : cardBorder(context),
                width: selected ? 1.4 : 1,
              ),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: SizedBox(
                    width: 64,
                    height: 52,
                    child: _HeroNetworkImage(url: url),
                  ),
                ),
                const SizedBox(width: AppGap.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.bodySmall.copyWith(
                          color: selected ? cs.primary : cs.onSurface,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        "候选背景",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption.copyWith(
                          color: hintColor(context),
                        ),
                      ),
                    ],
                  ),
                ),
                if (selected) ...[
                  const SizedBox(width: AppGap.xs),
                  Icon(Icons.check_circle_rounded, size: 18, color: cs.primary),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroNetworkImage extends StatelessWidget {
  final String url;

  const _HeroNetworkImage({required this.url});

  @override
  Widget build(BuildContext context) {
    return Image.network(
      url,
      key: ValueKey(url),
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      loadingBuilder: (_, child, progress) {
        if (progress == null) return child;
        return Container(
          color: placeholderBg(context).withValues(alpha: 0.36),
          child: Center(
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: progress.expectedTotalBytes != null
                  ? progress.cumulativeBytesLoaded /
                      progress.expectedTotalBytes!
                  : null,
            ),
          ),
        );
      },
      errorBuilder: (_, __, ___) => Container(
        color: placeholderBg(context),
        alignment: Alignment.center,
        child: Icon(
          Icons.broken_image_rounded,
          color: placeholderIcon(context),
        ),
      ),
    );
  }
}

class _HeroPickerHint extends StatelessWidget {
  const _HeroPickerHint();

  @override
  Widget build(BuildContext context) {
    return AppSurface(
      radius: AppRadius.md,
      padding: const EdgeInsets.all(AppGap.md),
      color: cardBg(context),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.visibility_off_outlined,
            color: hintColor(context),
            size: 18,
          ),
          const SizedBox(width: AppGap.sm),
          Expanded(
            child: Text(
              "NSFW 条目保存后仍按设置模糊显示。应用后也可以回到编辑页手动上传或输入 URL 替换。",
              style: AppText.caption.copyWith(
                color: hintColor(context),
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
