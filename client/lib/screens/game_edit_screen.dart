/// Full-screen game metadata editor — Playnite style.
/// Layout: cover right header, left metadata panel, right description, inline download buttons.

import "dart:convert";

import "package:flutter/material.dart";
import "package:provider/provider.dart";
import "package:http/http.dart" as http;

import "../models/game.dart";
import "../providers/game_provider.dart";

class GameEditScreen extends StatefulWidget {
  final GameDetail game;
  const GameEditScreen({super.key, required this.game});

  @override
  State<GameEditScreen> createState() => _GameEditScreenState();
}

class _GameEditScreenState extends State<GameEditScreen> {
  late final TextEditingController _name, _dev, _desc, _date,
      _vndb, _steam, _bgm, _notes;
  bool _saving = false;
  String? _coverPath;

  String get _baseUrl => context.read<GameProvider>().api.baseUrl;

  @override
  void initState() {
    super.initState();
    final g = widget.game;
    _coverPath = g.coverPath;
    _name = TextEditingController(text: g.name);
    _dev = TextEditingController(text: g.developer ?? "");
    _desc = TextEditingController(text: g.description ?? "");
    _date = TextEditingController(text: g.releaseDate ?? "");
    _vndb = TextEditingController(text: g.vndbId ?? "");
    _steam = TextEditingController(text: g.steamId ?? "");
    _bgm = TextEditingController(text: g.bangumiId ?? "");
    _notes = TextEditingController();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final g = widget.game;
      final body = {"name": _name.text.trim(), "developer": _dev.text.trim(),
        "description": _desc.text.trim(), "release_date": _date.text.trim(),
        "vndb_id": _vndb.text.trim(), "steam_id": _steam.text.trim(),
        "bangumi_id": _bgm.text.trim()};
      final resp = await http.put(Uri.parse("$_baseUrl/api/games/${g.id}"),
          headers: {"Content-Type": "application/json"}, body: jsonEncode(body));
      if (resp.statusCode != 200) { _showError("保存失败"); return; }
      if (mounted) Navigator.pop(context, true);
    } catch (e) { _showError("$e"); }
    setState(() => _saving = false);
  }

  Future<void> _downloadFromSource(String source, String label) async {
    final ctrl = TextEditingController(text: _name.text);
    final q = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("搜索 $label"),
        content: TextField(controller: ctrl, autofocus: true,
          decoration: InputDecoration(labelText: "名称或 ID", hintText: "输入后回车搜索")),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text("搜索")),
        ],
      ),
    );
    if (q == null || q.isEmpty) return;

    List<Map<String, dynamic>> results = [];
    try {
      final resp = await http.get(Uri.parse(
          "$_baseUrl/api/scrape/search?q=${Uri.encodeComponent(q)}&source=$source"));
      results = ((jsonDecode(resp.body) as Map)["results"] as List).cast<Map<String, dynamic>>();
    } catch (_) { _showError("搜索失败"); return; }
    if (results.isEmpty) { _showError("无结果"); return; }

    // Show results
    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("$label — 搜索结果"),
        content: SizedBox(width: 450, height: 400,
          child: ListView.builder(
            itemCount: results.length,
            itemBuilder: (_, i) {
              final r = results[i];
              return ListTile(
                leading: (r["cover_url"] ?? "").toString().isNotEmpty
                    ? ClipRRect(borderRadius: BorderRadius.circular(4),
                        child: Image.network(r["cover_url"].toString(), width: 50, height: 70,
                            fit: BoxFit.cover, errorBuilder: (_, __, ___) => _noCover()))
                    : _noCover(),
                title: Text(r["title"] ?? "", style: const TextStyle(fontSize: 13)),
                subtitle: Text([r["developer"], r["release_date"]]
                    .where((s) => s != null && s.toString().isNotEmpty).join(" · "),
                    style: const TextStyle(fontSize: 12)),
                onTap: () => Navigator.pop(ctx, r),
              );
            },
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消"))],
      ),
    );
    if (picked == null || !mounted) return;

    // Apply to form (mark dirty)
    setState(() {
      _name.text = (picked["title"] ?? "").toString();
      _dev.text = (picked["developer"] ?? "").toString();
      _desc.text = (picked["description"] ?? "").toString();
      _date.text = (picked["release_date"] ?? "").toString();
    });
    _showMsg("已填入 $label 数据");
  }

  Future<void> _moveVersionDialog(version) async {
    final searchCtrl = TextEditingController();
    var results = <Map<String, dynamic>>[];
    final targetId = await showDialog<int>(
      context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: Text("移动「${version.filename}」"),
        content: SizedBox(width: 400, child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(child: TextField(controller: searchCtrl, autofocus: true,
              decoration: const InputDecoration(labelText: "搜索游戏名称", isDense: true),
              onSubmitted: (v) async {
                setD(() => results = []);
                try {
                  final r = await http.get(Uri.parse("$_baseUrl/api/games/search?q=${Uri.encodeComponent(v)}&page_size=10"));
                  if (r.statusCode == 200) results = (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
                } catch (_) {}
                setD(() {});
              })),
            const SizedBox(width: 8),
            IconButton.filled(icon: const Icon(Icons.search, size: 18), onPressed: () async {
              setD(() => results = []);
              try {
                final r = await http.get(Uri.parse("$_baseUrl/api/games/search?q=${Uri.encodeComponent(searchCtrl.text)}&page_size=10"));
                if (r.statusCode == 200) results = (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
              } catch (_) {}
              setD(() {});
            }),
          ]),
          const SizedBox(height: 8),
          if (results.isNotEmpty)
            SizedBox(height: 250, child: ListView.builder(itemCount: results.length, itemBuilder: (_, i) {
              final g = results[i];
              return ListTile(
                title: Text(g["name"] ?? "", style: const TextStyle(fontSize: 13)),
                subtitle: Text("${g["company_name"] ?? ""} · ${g["platform_summary"] ?? ""}",
                    style: const TextStyle(fontSize: 11)),
                onTap: () => Navigator.pop(ctx, g["id"] as int),
              );
            })),
          if (results.isEmpty && searchCtrl.text.isNotEmpty)
            Padding(padding: const EdgeInsets.all(16), child: Text("无结果，可创建新条目",
                style: TextStyle(color: Colors.grey[500]))),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
          if (searchCtrl.text.trim().isNotEmpty)
            TextButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: const Text("创建新条目并移入"),
              onPressed: () async {
                // Create new game with version filename as name
                try {
                  final r = await http.put(Uri.parse("$_baseUrl/api/games/quick-create"),
                    headers: {"Content-Type": "application/json"},
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
      )),
    );
    if (targetId != null && targetId > 0) {
      try {
        final g = widget.game;
        await http.post(Uri.parse("$_baseUrl/api/games/${g.id}/versions/${version.id}/move?to_game_id=$targetId"));
        if (mounted) Navigator.pop(context, true);
      } catch (e) { _showError("$e"); }
    }
  }

  Future<void> _mergeGameDialog() async {
    final searchCtrl = TextEditingController();
    var results = <Map<String, dynamic>>[];
    final targetId = await showDialog<int>(
      context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
        title: const Text("合并到哪个游戏？"),
        content: SizedBox(width: 400, child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text("当前游戏的所有版本将移至目标游戏，当前游戏将被删除。",
              style: TextStyle(fontSize: 12, color: Colors.grey[500])),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(controller: searchCtrl, autofocus: true,
              decoration: const InputDecoration(labelText: "搜索游戏名称", isDense: true),
              onSubmitted: (v) async {
                setD(() => results = []);
                try {
                  final r = await http.get(Uri.parse("$_baseUrl/api/games/search?q=${Uri.encodeComponent(v)}&page_size=10"));
                  if (r.statusCode == 200) results = (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
                } catch (_) {}
                setD(() {});
              })),
            const SizedBox(width: 8),
            IconButton.filled(icon: const Icon(Icons.search, size: 18), onPressed: () async {
              setD(() => results = []);
              try {
                final r = await http.get(Uri.parse("$_baseUrl/api/games/search?q=${Uri.encodeComponent(searchCtrl.text)}&page_size=10"));
                if (r.statusCode == 200) results = (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
              } catch (_) {}
              setD(() {});
            }),
          ]),
          const SizedBox(height: 8),
          if (results.isNotEmpty)
            SizedBox(height: 250, child: ListView.builder(itemCount: results.length, itemBuilder: (_, i) {
              final g = results[i];
              return ListTile(
                title: Text(g["name"] ?? "", style: const TextStyle(fontSize: 13)),
                subtitle: Text("${g["company_name"] ?? ""} · ${g["platform_summary"] ?? ""}",
                    style: const TextStyle(fontSize: 11)),
                onTap: () => Navigator.pop(ctx, g["id"] as int),
              );
            })),
          if (results.isEmpty && searchCtrl.text.isNotEmpty)
            Padding(padding: const EdgeInsets.all(16), child: Text("无结果，可创建新条目",
                style: TextStyle(color: Colors.grey[500]))),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
          if (searchCtrl.text.trim().isNotEmpty)
            TextButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: const Text("创建新条目并合并"),
              onPressed: () async {
                try {
                  final r = await http.put(Uri.parse("$_baseUrl/api/games/quick-create"),
                    headers: {"Content-Type": "application/json"},
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
      )),
    );
    if (targetId != null && targetId > 0) {
      try {
        final g = widget.game;
        await http.post(Uri.parse("$_baseUrl/api/games/${g.id}/merge/$targetId"));
        if (mounted) Navigator.pop(context, true);
      } catch (e) { _showError("$e"); }
    }
  }

  Future<void> _reloadGame() async {
    try {
      final resp = await http.get(Uri.parse("$_baseUrl/api/games/${widget.game.id}"));
      if (resp.statusCode == 200) {
        final fresh = GameDetail.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
        if (mounted) setState(() => _coverPath = fresh.coverPath);
      }
    } catch (_) {}
  }

  void _showMsg(String m) {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text("提示"), content: Text(m),
      actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text("确定"))],
    ));
  }
  void _showError(String m) {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text("错误"), content: Text(m),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("关闭"))],
    ));
  }

  Widget _field(String label, TextEditingController ctrl, {int maxLines = 1, String? sourceId}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 90,
          child: Padding(padding: const EdgeInsets.only(top: 8),
            child: Text(label, style: TextStyle(color: Colors.grey[400], fontSize: 12)))),
        Expanded(
          child: TextField(controller: ctrl, maxLines: maxLines,
            decoration: _dec(border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)), isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
            style: const TextStyle(fontSize: 13)),
        ),
        if (sourceId != null && sourceId.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 10, left: 4),
            child: Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(4)),
              child: Text(sourceId, style: TextStyle(color: Colors.grey[500], fontSize: 10)))),
      ]),
    );
  }

  Widget _noCover() => const Icon(Icons.image, size: 36, color: Colors.grey);

  @override
  Widget build(BuildContext context) {
    final g = widget.game;
    final hasCover = _coverPath != null && _coverPath!.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text("编辑游戏"),
        actions: [
          OutlinedButton.icon(icon: const Icon(Icons.cloud_download, size: 16),
            label: const Text("下载元数据"), onPressed: _downloadMetadata),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            tooltip: "删除游戏",
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context, builder: (ctx) => AlertDialog(
                  title: const Text("确认删除"),
                  content: Text("确定删除「${widget.game.name}」吗？\n不会删除本地文件。"),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("取消")),
                    TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("删除")),
                  ],
                ),
              );
              if (confirmed == true && context.mounted) {
                await context.read<GameProvider>().deleteGame(widget.game.id);
                if (context.mounted) Navigator.pop(context, true);
              }
            },
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving ? const SizedBox(width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save, size: 16),
            label: const Text("保存")),
          const SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: SizedBox(width: 900,
            child: Column(children: [
              // ── Header: cover right, name left ──
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    TextField(controller: _name,
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                      decoration: _dec(border: InputBorder.none, isDense: true)),
                    const SizedBox(height: 4),
                    Text(g.companyName ?? "", style: TextStyle(fontSize: 15, color: Colors.grey[400])),
                    const SizedBox(height: 8),
                    Row(children: [
                      _sourceBadge("VNDB", g.vndbId),
                      _sourceBadge("Steam", g.steamId),
                      _sourceBadge("Bangumi", g.bangumiId),
                    ]),
                  ]),
                ),
                const SizedBox(width: 24),
                ClipRRect(borderRadius: BorderRadius.circular(10),
                  child: SizedBox(width: 200, height: 280,
                    child: hasCover
                        ? Image.network("$_baseUrl/api/files/covers${_coverPath!}",
                            fit: BoxFit.cover, errorBuilder: (_, __, ___) => _coverPlaceholder())
                        : _coverPlaceholder())),
              ]),
              const SizedBox(height: 20),

              // ── Body: left metadata grid + right description ──
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Left: metadata grid
                Expanded(
                  flex: 5,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    _section("详细信息"),
                    _field("开发商", _dev,
                        sourceId: g.vndbId),
                    _field("发售日", _date,
                        sourceId: g.vndbId),
                    _field("VNDB ID", _vndb,
                        sourceId: g.vndbId != null && g.vndbId!.isNotEmpty ? g.vndbId : null),
                    _field("Steam ID", _steam,
                        sourceId: g.steamId != null && g.steamId!.isNotEmpty ? g.steamId : null),
                    _field("Bangumi ID", _bgm,
                        sourceId: g.bangumiId != null && g.bangumiId!.isNotEmpty ? g.bangumiId : null),
                    const SizedBox(height: 12),
                    _section("版本"),
                    if (g.versions.isEmpty)
                      Text("无", style: TextStyle(color: Colors.grey[500], fontSize: 13))
                    else ...[
                      ...g.versions.map((v) => Container(
                        margin: const EdgeInsets.only(bottom: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(6)),
                        child: Row(children: [
                          Expanded(child: Text(v.filename, style: const TextStyle(fontSize: 13))),
                          Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(4)),
                            child: Text(v.platform, style: const TextStyle(fontSize: 11))),
                          PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert, size: 18),
                            onSelected: (action) {
                              if (action == "move") _moveVersionDialog(v);
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: "move", child: Text("移动到其他游戏...")),
                            ],
                          ),
                        ]),
                      )),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.merge, size: 16),
                        label: const Text("合并到其他游戏..."),
                        onPressed: _mergeGameDialog,
                      ),
                    ],
                  ]),
                ),
                const SizedBox(width: 24),
                // Right: description + notes
                Expanded(
                  flex: 4,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    _section("简介"),
                    TextField(controller: _desc, maxLines: 8,
                      decoration: _dec(
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        hintText: "游戏简介..."),
                      style: const TextStyle(fontSize: 13)),
                    const SizedBox(height: 16),
                    _section("备注"),
                    TextField(controller: _notes, maxLines: 4,
                      decoration: _dec(
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        hintText: "个人备注..."),
                      style: const TextStyle(fontSize: 13)),
                  ]),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _coverPlaceholder() => Container(
    width: 200, height: 280, color: Colors.grey[850],
    child: Center(child: Icon(Icons.image, size: 64, color: Colors.grey[700])),
  );

  Widget _section(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 6, top: 4),
    child: Text(t, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
  );

  Widget _sourceBadge(String label, String? id) {
    final active = id != null && id.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: active ? Colors.green.withValues(alpha: 0.2) : Colors.white10,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: active ? Colors.green.withValues(alpha: 0.4) : Colors.white24)),
        child: Text(label, style: TextStyle(fontSize: 11, color: active ? Colors.green : Colors.grey)),
      ),
    );
  }

  // ── Single unified download: search all sources → show results → compare → apply ──

  // ── Single unified download: search all sources → show results → compare → apply ──

  Future<void> _downloadMetadata() async {
    // Step 1: Pick source
    final sources = {"vndb_kana": "VNDB Kana v2", "bangumi": "Bangumi", "steam": "Steam", "dlsite": "DLsite"};
    final src = await showDialog<String>(
      context: context, builder: (ctx) => AlertDialog(
        title: const Text("选择数据来源"),
        content: Column(mainAxisSize: MainAxisSize.min,
          children: sources.entries.map((e) => ListTile(
            title: Text(e.value), trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pop(ctx, e.key),
          )).toList()),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消"))],
      ),
    );
    if (src == null || !mounted) return;

    // Step 2: Search with inline loading + results
    final ctrl = TextEditingController(text: _name.text);
    final picked = await showDialog<Map<String, dynamic>>(
      context: context, builder: (ctx) {
        var results = <Map<String, dynamic>>[];
        var searching = false;
        var error = "";
        return StatefulBuilder(builder: (ctx, setD) => AlertDialog(
          title: Text("${sources[src]} - 搜索"),
          content: SizedBox(width: 440, child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(child: TextField(controller: ctrl, autofocus: true,
                decoration: _dec(labelText: "名称/ID", hintText: "游戏名 或 VNDB/Steam/Bangumi ID"),
                onSubmitted: (v) async {
                  setD(() { searching = true; results = []; error = ""; });
                  try {
                    final r = await http.get(Uri.parse(
                        "$_baseUrl/api/scrape/search?q=${Uri.encodeComponent(v)}&source=$src"));
                    results = ((jsonDecode(r.body) as Map)["results"] as List).cast<Map<String, dynamic>>();
                  } catch (e) { error = "$e"; }
                  setD(() => searching = false);
                })),
              const SizedBox(width: 8),
              IconButton.filled(icon: const Icon(Icons.search, size: 18),
                onPressed: () async {
                  setD(() { searching = true; results = []; error = ""; });
                  try {
                    final r = await http.get(Uri.parse(
                        "$_baseUrl/api/scrape/search?q=${Uri.encodeComponent(ctrl.text)}&source=$src"));
                    results = ((jsonDecode(r.body) as Map)["results"] as List).cast<Map<String, dynamic>>();
                  } catch (e) { error = "$e"; }
                  setD(() => searching = false);
                }),
            ]),
            const SizedBox(height: 8),
            if (searching) const Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()),
            if (error.isNotEmpty) Text(error, style: const TextStyle(color: Colors.red)),
            if (!searching && results.isEmpty && error.isEmpty)
              const Padding(padding: EdgeInsets.all(16), child: Text("无结果", style: TextStyle(color: Colors.grey))),
            if (results.isNotEmpty)
              SizedBox(height: 350,
                child: ListView.builder(itemCount: results.length, itemBuilder: (_, i) {
                  final r = results[i];
                  return ListTile(
                    leading: (r["cover_url"] ?? "").toString().isNotEmpty
                        ? ClipRRect(borderRadius: BorderRadius.circular(4),
                            child: Image.network(r["cover_url"].toString(), width: 50, height: 70,
                                fit: BoxFit.cover, errorBuilder: (_, __, ___) => _noCover()))
                        : _noCover(),
                    title: Text(r["title"] ?? "", style: const TextStyle(fontSize: 13)),
                    subtitle: Text("${r["developer"] ?? ""} . ${r["release_date"] ?? ""}",
                        maxLines: 2, style: const TextStyle(fontSize: 11)),
                    onTap: () => Navigator.pop(ctx, r),
                  );
                })),
          ])),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消"))],
        ));
      },
    );
    if (picked == null || !mounted) return;

    // Step 3: Per-field comparison (Playnite style)
    final coverUrl = (picked["cover_url"] ?? "").toString();
    final fields = {"名称": _name, "开发商": _dev, "日期": _date, "简介": _desc, "封面": _name}; // cover uses _name as dummy ctrl
    final incoming = {
      "名称": (picked["title"] ?? "").toString(),
      "开发商": (picked["developer"] ?? "").toString(),
      "日期": (picked["release_date"] ?? "").toString(),
      "简介": (picked["description"] ?? "").toString(),
      "封面": coverUrl.isNotEmpty ? "下载并替换当前封面" : "",
    };
    final useSearch = <String, bool>{};
    for (final f in fields.keys) {
      useSearch[f] = incoming[f]!.isNotEmpty && incoming[f] != fields[f]!.text;
    }
    final confirmed = await showDialog<Map<String, bool>?>(
      context: context, builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text("对比 - ${sources[src]}"),
          content: SizedBox(width: 480, child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
              children: fields.keys.map((f) {
                final cur = fields[f]!.text;
                final inc = incoming[f] ?? "";
                final hasDiff = inc.isNotEmpty && inc != cur;
                final isCover = f == "封面" && inc.isNotEmpty;
                return Padding(padding: const EdgeInsets.only(bottom: 6),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(f, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
                        isCover
                            ? (_coverPath != null
                                ? ClipRRect(borderRadius: BorderRadius.circular(4),
                                    child: Image.network("$_baseUrl/api/files/covers${_coverPath!}",
                                        width: 80, height: 110, fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => const Icon(Icons.image, size: 40)))
                                : Text("(无)", style: TextStyle(fontSize: 13, color: Colors.grey)))
                            : Text(cur.isEmpty ? "(空)" : cur, style: TextStyle(fontSize: 13,
                                color: !useSearch[f]! || !hasDiff ? Colors.white : Colors.grey,
                                decoration: useSearch[f]! && hasDiff ? TextDecoration.lineThrough : null)),
                      ])),
                      if (hasDiff && !isCover) ...[
                        const Padding(padding: EdgeInsets.symmetric(horizontal: 6),
                            child: Icon(Icons.arrow_forward, size: 16, color: Colors.green)),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(sources[src]!, style: TextStyle(fontSize: 10, color: Colors.green[300])),
                          Text(inc.length > 60 ? "${inc.substring(0, 60)}..." : inc,
                              style: TextStyle(fontSize: 13, color: useSearch[f]! ? Colors.green : Colors.grey)),
                        ])),
                      ],
                      if (hasDiff && isCover) ...[
                        const Padding(padding: EdgeInsets.symmetric(horizontal: 6),
                            child: Icon(Icons.arrow_forward, size: 16, color: Colors.green)),
                        ClipRRect(borderRadius: BorderRadius.circular(4),
                          child: Image.network(coverUrl, width: 80, height: 110, fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Icon(Icons.image, size: 40))),
                      ],
                    ]),
                    if (hasDiff)
                      Padding(padding: const EdgeInsets.only(top: 4),
                        child: Row(children: [
                          Text("使用搜索结果", style: TextStyle(fontSize: 11, color: Colors.grey[500])),
                          const Spacer(),
                          SizedBox(height: 24, child: Switch(
                            value: useSearch[f] ?? false,
                            onChanged: (v) => setD(() => useSearch[f] = v)),
                          ),
                        ])),
                  ]),
                );
              }).toList())),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, {"retry": true}), child: const Text("重新选择来源")),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
            FilledButton(onPressed: () => Navigator.pop(ctx, useSearch), child: const Text("应用所选")),
          ],
        ),
      ),
    );
    if (confirmed == null || !mounted) return;
    if (confirmed is Map && (confirmed as Map)["retry"] == true) {
      _downloadMetadata();
      return;
    }

    if (confirmed is! Map<String, bool>) return;
    // Apply only selected fields
    final apply = confirmed as Map<String, bool>;
    setState(() {
      if (apply["名称"] == true) _name.text = incoming["名称"]!;
      if (apply["开发商"] == true) _dev.text = incoming["开发商"]!;
      if (apply["日期"] == true) _date.text = incoming["日期"]!;
      if (apply["简介"] == true) _desc.text = incoming["简介"]!;
      final sf = {"vndb_kana": _vndb, "bangumi": _bgm, "steam": _steam};
      if (sf.containsKey(src) && (picked["source_id"] ?? "").toString().isNotEmpty) {
        sf[src]!.text = picked["source_id"].toString();
      }
    });
    // Download cover if selected
    if (apply["封面"] == true && coverUrl.isNotEmpty) {
      try {
        await http.post(Uri.parse("$_baseUrl/api/games/${widget.game.id}/cover?cover_url=${Uri.encodeComponent(coverUrl)}"));
      } catch (_) {}
    }
    // Refresh game data to show updated cover
    await _reloadGame();
    _showMsg("已应用所选字段，核对后保存");
  }

  @override
  void dispose() {
    _name.dispose(); _dev.dispose(); _desc.dispose(); _date.dispose();
    _vndb.dispose(); _steam.dispose(); _bgm.dispose(); _notes.dispose();
    super.dispose();
  }

  InputDecoration _dec({InputBorder? border, bool isDense = true, EdgeInsetsGeometry? contentPadding, String? hintText, String? labelText}) {
    return InputDecoration(
      filled: true, fillColor: Colors.white.withValues(alpha: 0.04),
      border: border, isDense: isDense,
      contentPadding: contentPadding, hintText: hintText, labelText: labelText,
    );
  }
}
