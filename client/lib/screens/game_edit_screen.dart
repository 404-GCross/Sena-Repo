/// Full-screen game metadata editor — Playnite style.
/// Layout: cover right header, left metadata panel, right description, inline download buttons.

import "dart:async";
import "dart:convert";

import "package:flutter/material.dart";
import "package:provider/provider.dart";
import "package:http/http.dart" as http;

import "../models/game.dart";
import "../utils/theme_utils.dart";
import "../providers/game_provider.dart";

class GameEditScreen extends StatefulWidget {
  final GameDetail game;
  const GameEditScreen({super.key, required this.game});

  @override
  State<GameEditScreen> createState() => _GameEditScreenState();
}

class _GameEditScreenState extends State<GameEditScreen> {
  late final TextEditingController _name, _dev, _desc, _date,
      _vndb, _steam, _bgm, _notes, _bgUrl;
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
    _bgUrl = TextEditingController(text: g.bgPath ?? "");
    _notes = TextEditingController();
  }

  Future<void> _save({bool popOnSave = true}) async {
    setState(() => _saving = true);
    try {
      final g = widget.game;
      final body = {"name": _name.text.trim(), "developer": _dev.text.trim(),
        "description": _desc.text.trim(), "release_date": _date.text.trim(),
        "bg_path": _bgUrl.text.trim(),
        "vndb_id": _vndb.text.trim(), "steam_id": _steam.text.trim(),
        "bangumi_id": _bgm.text.trim()};
      final resp = await http.put(Uri.parse("$_baseUrl/api/games/${g.id}"),
          headers: {"Content-Type": "application/json"}, body: jsonEncode(body));
      if (resp.statusCode != 200) { _showError("保存失败"); return; }
      // Also update background image if URL provided
      if (_bgUrl.text.trim().isNotEmpty && _bgUrl.text.trim().startsWith("http")) {
        await http.post(Uri.parse("$_baseUrl/api/games/${g.id}/background?bg_url=${Uri.encodeComponent(_bgUrl.text.trim())}"));
      }
      if (popOnSave && mounted) Navigator.pop(context, true);
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
    final picked = await showDialog<Object?>(
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
    final r = picked as Map<String, dynamic>;

    // Apply to form (mark dirty)
    setState(() {
      _name.text = (r["title"] ?? "").toString();
      _dev.text = (r["developer"] ?? "").toString();
      _desc.text = (r["description"] ?? "").toString();
      _date.text = (r["release_date"] ?? "").toString();
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
            Padding(padding: const EdgeInsets.all(16), child: Text("无结果",
                style: TextStyle(color: hintColor(context)))),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
          TextButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: const Text("创建新条目并移入"),
              onPressed: () async {
                final nameCtrl = TextEditingController();
                final newName = await showDialog<String>(
                  context: ctx, builder: (c) => AlertDialog(
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
                      TextButton(onPressed: () => Navigator.pop(c), child: const Text("取消")),
                      FilledButton(onPressed: () {
                        final name = nameCtrl.text.trim();
                        if (name.isEmpty) return;
                        Navigator.pop(c, name);
                      }, child: const Text("创建")),
                    ],
                  ),
                );
                if (newName == null || newName.isEmpty) return;
                try {
                  final r = await http.put(Uri.parse("$_baseUrl/api/games/quick-create"),
                    headers: {"Content-Type": "application/json"},
                    body: jsonEncode({"name": newName}),
                  );
                  if (r.statusCode == 200) {
                    Navigator.pop(ctx, jsonDecode(r.body)["id"] as int);
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
              style: TextStyle(fontSize: 12, color: hintColor(context))),
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
            Padding(padding: const EdgeInsets.all(16), child: Text("无结果",
                style: TextStyle(color: hintColor(context)))),
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

  Widget _field(String label, TextEditingController ctrl, {int maxLines = 1, IconData? icon, String? sourceId}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (icon != null) ...[
          Padding(padding: const EdgeInsets.only(top: 8),
            child: Icon(icon, size: 18, color: hintColor(context))),
          const SizedBox(width: 8),
        ],
        SizedBox(width: 80,
          child: Padding(padding: const EdgeInsets.only(top: 10),
            child: Text(label, style: TextStyle(color: subTextColor(context), fontSize: 14)))),
        Expanded(
          child: TextField(controller: ctrl, maxLines: maxLines,
            decoration: _dec(border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)), isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
            style: const TextStyle(fontSize: 15)),
        ),
        if (sourceId != null && sourceId.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 10, left: 6),
            child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: Colors.green.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.green.withValues(alpha: 0.3))),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.check_circle, size: 10, color: Colors.green[300]),
                const SizedBox(width: 4),
                Text(sourceId, style: TextStyle(color: Colors.green[300], fontSize: 11, fontWeight: FontWeight.w500)),
              ]))),
      ]),
    );
  }

  Widget _noCover() => const Icon(Icons.image, size: 36, color: Colors.grey);

  Widget _section(String t, [IconData? icon]) => Padding(
    padding: const EdgeInsets.only(bottom: 8, top: 4),
    child: Row(children: [
      if (icon != null) ...[
        Icon(icon, size: 18, color: sectionIconColor(context)),
        const SizedBox(width: 6),
      ],
      Text(t, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: sectionTextColor(context))),
    ]),
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
    child: Row(children: [
      Icon(Icons.info_outline, size: 18, color: hintColor(context)),
      const SizedBox(width: 8),
      Text(text, style: TextStyle(fontSize: 14, color: hintColor(context))),
    ]),
  );

  Color _platformColor(String platform) {
    switch (platform.toLowerCase()) {
      case "windows": return Colors.blue;
      case "android": return Colors.green;
      case "linux": return Colors.orange;
      case "mac": return Colors.grey;
      default: return Colors.white60;
    }
  }

  Widget _divider() => Divider(height: 1, thickness: 0.5, color: cardBorder(context));

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
        padding: const EdgeInsets.all(28),
        child: Center(
          child: SizedBox(width: 900,
            child: Column(children: [
              // ── Header: cover right, name left ──
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    TextField(controller: _name,
                      style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, height: 1.2),
                      decoration: _dec(border: InputBorder.none, isDense: true)),
                    const SizedBox(height: 6),
                    if (g.companyName != null && g.companyName!.isNotEmpty)
                      Text(g.companyName!, style: TextStyle(fontSize: 16, color: subTextColor(context)))
                    else
                      Text("无公司信息", style: TextStyle(fontSize: 14, color: Colors.grey[600])),
                    const SizedBox(height: 12),
                    Row(children: [
                      _sourceBadge("VNDB", g.vndbId),
                      _sourceBadge("Steam", g.steamId),
                      _sourceBadge("Bangumi", g.bangumiId),
                    ]),
                  ]),
                ),
                const SizedBox(width: 24),
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    decoration: BoxDecoration(
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 20, offset: const Offset(0, 8))],
                    ),
                    child: SizedBox(width: 200, height: 280,
                      child: hasCover
                          ? Image.network("$_baseUrl/api/files/covers${_coverPath!}",
                              fit: BoxFit.cover, errorBuilder: (_, __, ___) => _coverPlaceholder())
                          : _coverPlaceholder()),
                  ),
                ),
              ]),
              const SizedBox(height: 24),

              // ── Body: left metadata grid + right description ──
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Left: metadata grid
                Expanded(
                  flex: 5,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    _section("详细信息", Icons.info_outline),
                    _fieldCard(children: [
                      _field("开发商", _dev, icon: Icons.business, sourceId: g.vndbId),
                      _divider(),
                      _field("发售日", _date, icon: Icons.calendar_today, sourceId: g.vndbId),
                      _divider(),
                      _field("VNDB ID", _vndb, icon: Icons.tag,
                          sourceId: g.vndbId != null && g.vndbId!.isNotEmpty ? g.vndbId : null),
                      _divider(),
                      _field("Steam ID", _steam, icon: Icons.tag,
                          sourceId: g.steamId != null && g.steamId!.isNotEmpty ? g.steamId : null),
                      _divider(),
                      _field("Bangumi ID", _bgm, icon: Icons.tag,
                          sourceId: g.bangumiId != null && g.bangumiId!.isNotEmpty ? g.bangumiId : null),
                    ]),
                    const SizedBox(height: 20),
                    _section("版本", Icons.folder_outlined),
                    if (g.versions.isEmpty)
                      _hintCard("暂无版本信息")
                    else ...[
                      _fieldCard(children:
                        g.versions.asMap().entries.map((e) {
                          final v = e.value;
                          final isLast = e.key == g.versions.length - 1;
                          return Column(children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              child: Row(children: [
                                Icon(Icons.insert_drive_file_outlined, size: 18, color: hintColor(context)),
                                const SizedBox(width: 10),
                                Expanded(child: Text(v.filename, style: const TextStyle(fontSize: 14))),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    color: _platformColor(v.platform).withValues(alpha: 0.15),
                                  ),
                                  child: Text(v.platform, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: _platformColor(v.platform))),
                                ),
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
                            ),
                            if (!isLast) _divider(),
                          ]);
                        }).toList(),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.merge, size: 16),
                        label: const Text("合并到其他游戏..."),
                        onPressed: _mergeGameDialog,
                      ),
                    ],
                  ]),
                ),
                const SizedBox(width: 28),
                // Right: description + notes
                Expanded(
                  flex: 4,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    _section("简介", Icons.description_outlined),
                    TextField(controller: _desc, maxLines: 8,
                      decoration: _dec(
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        hintText: "游戏简介..."),
                      style: const TextStyle(fontSize: 15, height: 1.6)),
                    const SizedBox(height: 20),
                    _section("备注", Icons.note_outlined),
                    TextField(controller: _notes, maxLines: 4,
                      decoration: _dec(
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        hintText: "个人备注..."),
                      style: const TextStyle(fontSize: 15, height: 1.6)),
                    const SizedBox(height: 20),
                    _section("背景图 URL", Icons.image_outlined),
                    const SizedBox(height: 4),
                    TextField(controller: _bgUrl,
                      decoration: _dec(
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        hintText: "背景图片URL（可选）"),
                      style: const TextStyle(fontSize: 14)),
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
    decoration: BoxDecoration(
      color: placeholderBg(context),
      borderRadius: BorderRadius.circular(12),
    ),
    width: 200, height: 280,
    child: Center(child: Icon(Icons.image, size: 64, color: placeholderIcon(context))),
  );

  Widget _coverPlaceholderSmall() => Container(
    width: 90, height: 120,
    decoration: BoxDecoration(
      color: placeholderBg(context),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Center(child: Icon(Icons.image, size: 32, color: placeholderIcon(context))),
  );

  Widget _sourceBadge(String label, String? id) {
    final active = id != null && id.isNotEmpty;
    return Padding(padding: const EdgeInsets.only(right: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active ? Colors.green.withValues(alpha: 0.15) : cardBg(context),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: active ? Colors.green.withValues(alpha: 0.35) : Colors.white24)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (active)
            Padding(padding: const EdgeInsets.only(right: 4),
              child: Icon(Icons.check_circle, size: 12, color: Colors.green[300])),
          Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: active ? Colors.green[300] : Colors.grey)),
        ])));
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
    final picked = await showDialog<Object?>(
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
                    title: Text(r["title"] ?? "", style: const TextStyle(fontSize: 14)),
                    subtitle: Text([r["developer"], r["release_date"]]
                        .where((s) => s != null && s.toString().isNotEmpty).join(" · "),
                        maxLines: 1, style: TextStyle(fontSize: 12, color: hintColor(context))),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                    onTap: () => Navigator.pop(ctx, r),
                  );
                })),
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, "retry"), child: const Text("重新选择来源")),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
          ],
        ));
      },
    );
    if (picked == "retry") {
      await _downloadMetadata();
      return;
    }
    if (picked == null || !mounted) return;
    final r = picked as Map<String, dynamic>;

    // Step 3: Preload cover image before showing comparison
    final coverUrl = (r["cover_url"] ?? "").toString();
    if (coverUrl.isNotEmpty) {
      final preloadDone = Completer<void>();
      showDialog(context: context, barrierDismissible: false,
        builder: (_) => PopScope(canPop: false, child: AlertDialog(
          title: const Text("加载中..."),
          content: SizedBox(
            width: 200, height: 100,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Image.network(coverUrl, width: 90, height: 120, fit: BoxFit.cover,
                loadingBuilder: (_, child, progress) {
                  if (progress == null) { preloadDone.complete(); return child; }
                  return Column(mainAxisSize: MainAxisSize.min, children: [
                    CircularProgressIndicator(
                      value: progress.expectedTotalBytes != null
                          ? progress.cumulativeBytesLoaded / progress.expectedTotalBytes!
                          : null),
                    const SizedBox(height: 8),
                    Text("${(progress.cumulativeBytesLoaded / 1024).toStringAsFixed(0)} KB",
                        style: const TextStyle(fontSize: 12)),
                  ]);
                },
                errorBuilder: (_, __, ___) { preloadDone.complete(); return const SizedBox.shrink(); }),
            ]),
          ),
        )),
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
    final hasCoverDiff = coverUrl.isNotEmpty;
    // Build initial selection state (outside StatefulBuilder so it persists across rebuilds)
    final useSearch = <String, bool>{};
    for (final f in fields.keys) {
      useSearch[f] = incoming[f]!.isNotEmpty && incoming[f] != fields[f]!.text;
    }
    useSearch["封面"] = hasCoverDiff;

    final confirmed = await showDialog<Map<String, bool>?>(
      context: context, builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          final anyDiff = useSearch.values.any((v) => v);
          return AlertDialog(
          title: Row(children: [
            Icon(Icons.compare_arrows, size: 22, color: Colors.green[300]),
            const SizedBox(width: 8),
            Text("对比 - ${sources[src]}"),
          ]),
          content: SizedBox(width: 500,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 480),
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!anyDiff)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(children: [
                      Icon(Icons.info_outline, size: 18, color: hintColor(context)),
                      const SizedBox(width: 8),
                      Text("所有字段与现有数据一致，无需更新", style: TextStyle(fontSize: 13, color: hintColor(context))),
                    ]),
                  ),
                ...fields.keys.map((f) {
                  final cur = fields[f]!.text;
                  final inc = incoming[f] ?? "";
                  final hasDiff = inc.isNotEmpty && inc != cur;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: hasDiff ? cardBg(context) : cardBg(context),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: hasDiff ? Colors.green.withValues(alpha: 0.2) : cardBorder(context)),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Text(f, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey[300])),
                        const Spacer(),
                        if (hasDiff)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.green.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text("有变更", style: TextStyle(fontSize: 11, color: Colors.green[300])),
                          ),
                      ]),
                      const SizedBox(height: 10),
                      if (hasDiff)
                        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.red.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(cur.isEmpty ? "(空)" : cur,
                                  style: TextStyle(fontSize: 14, color: hintColor(context),
                                      decoration: TextDecoration.lineThrough)),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: Icon(Icons.arrow_forward, size: 18, color: Colors.green[400]),
                          ),
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.green.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(inc.length > 80 ? "${inc.substring(0, 80)}..." : inc,
                                  style: const TextStyle(fontSize: 14, color: Colors.green)),
                            ),
                          ),
                        ])
                      else
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: cardBg(context),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(cur.isEmpty ? "(空)" : cur, style: TextStyle(fontSize: 14, color: subTextColor(context))),
                        ),
                      if (hasDiff)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Row(children: [
                            SizedBox(
                              width: 20, height: 20,
                              child: Checkbox(
                                value: useSearch[f],
                                onChanged: (v) => setD(() => useSearch[f] = v ?? false),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                              ),
                            ),
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: () => setD(() => useSearch[f] = !(useSearch[f] ?? false)),
                              child: const Text("应用此项", style: TextStyle(fontSize: 13)),
                            ),
                          ]),
                        ),
                    ]),
                  );
                }),
                if (hasCoverDiff) ...[
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.green.withValues(alpha: 0.25)),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Text("封面", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey[300])),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.green.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text("有变更", style: TextStyle(fontSize: 11, color: Colors.green[300])),
                        ),
                      ]),
                      const SizedBox(height: 10),
                      Row(children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: _coverPath != null
                              ? Image.network("$_baseUrl/api/files/covers${_coverPath!}",
                                  width: 90, height: 120, fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => _coverPlaceholderSmall())
                              : _coverPlaceholderSmall(),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Icon(Icons.arrow_forward, size: 22, color: Colors.green[400]),
                        ),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(coverUrl, width: 90, height: 120, fit: BoxFit.cover,
                              loadingBuilder: (_, child, progress) {
                                if (progress == null) return child;
                                return Container(width: 90, height: 120,
                                  color: Colors.grey.withValues(alpha: 0.15),
                                  child: Center(child: CircularProgressIndicator(strokeWidth: 2,
                                    value: progress.expectedTotalBytes != null
                                        ? progress.cumulativeBytesLoaded / progress.expectedTotalBytes!
                                        : null)));
                              },
                              errorBuilder: (_, __, ___) => _coverPlaceholderSmall()),
                        ),
                      ]),
                      const SizedBox(height: 10),
                      Row(children: [
                        SizedBox(
                          width: 20, height: 20,
                          child: Checkbox(
                            value: useSearch["封面"],
                            onChanged: (v) => setD(() => useSearch["封面"] = v ?? false),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        GestureDetector(
                          onTap: () => setD(() => useSearch["封面"] = !(useSearch["封面"] ?? false)),
                          child: const Text("下载并替换封面", style: TextStyle(fontSize: 13)),
                        ),
                      ]),
                    ]),
                  ),
                ],
              ]),),),),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
            FilledButton.icon(
              onPressed: anyDiff ? () => Navigator.pop(ctx, useSearch) : null,
              icon: const Icon(Icons.check, size: 18),
              label: const Text("应用所选"),
            ),
          ],
        );}),
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
      final sf = {"vndb_kana": _vndb, "bangumi": _bgm, "steam": _steam};
      if (sf.containsKey(src) && (r["source_id"] ?? "").toString().isNotEmpty) {
        sf[src]!.text = r["source_id"].toString();
      }
    });
    // Download cover then auto-save
    if (apply["封面"] == true && coverUrl.isNotEmpty) {
      try {
        final resp = await http.post(Uri.parse("$_baseUrl/api/games/${widget.game.id}/cover?cover_url=${Uri.encodeComponent(coverUrl)}"));
        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body) as Map<String, dynamic>;
          final newPath = data["cover_path"];
          if (newPath != null) setState(() => _coverPath = newPath.toString());
        }
      } catch (_) {}
    }
    await _save(popOnSave: false);
  }

  @override
  void dispose() {
    _name.dispose(); _dev.dispose(); _desc.dispose(); _date.dispose();
    _vndb.dispose(); _steam.dispose(); _bgm.dispose(); _bgUrl.dispose(); _notes.dispose();
    super.dispose();
  }

  InputDecoration _dec({InputBorder? border, bool isDense = true, EdgeInsetsGeometry? contentPadding, String? hintText, String? labelText}) {
    return InputDecoration(
      filled: true, fillColor: cardBg(context),
      border: border, isDense: isDense,
      contentPadding: contentPadding, hintText: hintText, labelText: labelText,
    );
  }
}
