/// Full-screen game metadata editor — Playnite style.

import "dart:convert";

import "package:flutter/material.dart";
import "package:file_picker/file_picker.dart";
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
  late final TextEditingController _name;
  late final TextEditingController _dev;
  late final TextEditingController _desc;
  late final TextEditingController _date;
  late final TextEditingController _vndb;
  late final TextEditingController _steam;
  late final TextEditingController _bgm;
  late final TextEditingController _coverUrl;
  late final TextEditingController _bgUrl;
  bool _saving = false;

  String get _baseUrl => context.read<GameProvider>().api.baseUrl;

  @override
  void initState() {
    super.initState();
    final g = widget.game;
    _name = TextEditingController(text: g.name);
    _dev = TextEditingController(text: g.developer ?? "");
    _desc = TextEditingController(text: g.description ?? "");
    _date = TextEditingController(text: g.releaseDate ?? "");
    _vndb = TextEditingController(text: g.vndbId ?? "");
    _steam = TextEditingController(text: g.steamId ?? "");
    _bgm = TextEditingController(text: g.bangumiId ?? "");
    _coverUrl = TextEditingController();
    _bgUrl = TextEditingController(text: g.bgPath ?? "");
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final g = widget.game;
      final body = {
        "name": _name.text.trim(), "developer": _dev.text.trim(),
        "description": _desc.text.trim(), "release_date": _date.text.trim(),
        "vndb_id": _vndb.text.trim(), "steam_id": _steam.text.trim(),
        "bangumi_id": _bgm.text.trim(),
      };
      final resp = await http.put(
        Uri.parse("$_baseUrl/api/games/${g.id}"),
        headers: {"Content-Type": "application/json"}, body: jsonEncode(body),
      );
      if (resp.statusCode != 200) {
        _showError("保存失败");
        return;
      }
      // Cover
      if (_coverUrl.text.trim().isNotEmpty) {
        final u = _coverUrl.text.trim();
        u.startsWith("http")
            ? await http.post(Uri.parse("$_baseUrl/api/games/${g.id}/cover?cover_url=${Uri.encodeComponent(u)}"))
            : null;
      }
      // BG
      if (_bgUrl.text.trim().isNotEmpty && _bgUrl.text.trim() != (g.bgPath ?? "")) {
        final u = _bgUrl.text.trim();
        u.startsWith("http")
            ? await http.post(Uri.parse("$_baseUrl/api/games/${g.id}/background?bg_url=${Uri.encodeComponent(u)}"))
            : null;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("已保存")));
        Navigator.pop(context, true);
      }
    } catch (e) {
      _showError("$e");
    }
    setState(() => _saving = false);
  }

  void _showError(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _pickImage(TextEditingController ctrl) async {
    final r = await FilePicker.platform.pickFiles(type: FileType.image);
    if (r != null && r.files.single.path != null) ctrl.text = r.files.single.path!;
  }

  Widget _field(String label, TextEditingController ctrl, {int maxLines = 1, Widget? suffix}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 80, child: Text(label, style: TextStyle(color: Colors.grey[400], fontSize: 13, height: 2.4))),
        Expanded(child: TextField(controller: ctrl, maxLines: maxLines, decoration: InputDecoration(isDense: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))))),
        if (suffix != null) ...[const SizedBox(width: 4), suffix],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.game;
    final hasCover = g.coverPath != null && g.coverPath!.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text("编辑 — ${g.name}"),
        actions: [
          FilledButton.icon(onPressed: _saving ? null : _save,
            icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save, size: 18),
            label: const Text("保存")),
          const SizedBox(width: 8),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: SizedBox(
            width: 800,
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // ── Left: Cover ──
              SizedBox(
                width: 240,
                child: Column(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: hasCover
                        ? Image.network("$_baseUrl/api/files/covers${g.coverPath!}",
                            width: 240, fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _coverPlaceholder())
                        : _coverPlaceholder(),
                  ),
                  const SizedBox(height: 12),
                  _field("封面 URL", _coverUrl, suffix: IconButton(icon: const Icon(Icons.folder_open, size: 20), onPressed: () => _pickImage(_coverUrl))),
                  _field("背景 URL", _bgUrl, suffix: IconButton(icon: const Icon(Icons.folder_open, size: 20), onPressed: () => _pickImage(_bgUrl))),
                ]),
              ),
              const SizedBox(width: 32),
              // ── Right: Form ──
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _section("基本信息"),
                  _field("游戏名", _name),
                  _field("开发商", _dev),
                  _field("发行日期", _date),
                  _field("简介", _desc, maxLines: 4),
                  const SizedBox(height: 8),
                  _section("刮削源 ID"),
                  _field("VNDB ID", _vndb),
                  _field("Steam App ID", _steam),
                  _field("Bangumi ID", _bgm),
                  const SizedBox(height: 8),
                  _section("版本"),
                  ...g.versions.map((v) => ListTile(
                    dense: true, contentPadding: EdgeInsets.zero,
                    title: Text(v.filename, style: const TextStyle(fontSize: 13)),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(4)),
                      child: Text(v.platform, style: const TextStyle(fontSize: 12)),
                    ),
                  )),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _coverPlaceholder() {
    return Container(
      width: 240, height: 340,
      decoration: BoxDecoration(color: Colors.grey[850], borderRadius: BorderRadius.circular(12)),
      child: Center(child: Icon(Icons.image, size: 64, color: Colors.grey[700])),
    );
  }

  Widget _section(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(t, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
  );

  @override
  void dispose() {
    _name.dispose(); _dev.dispose(); _desc.dispose(); _date.dispose();
    _vndb.dispose(); _steam.dispose(); _bgm.dispose();
    _coverUrl.dispose(); _bgUrl.dispose();
    super.dispose();
  }
}
