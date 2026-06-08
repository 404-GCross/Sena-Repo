/// Beautify settings: accent color picker + custom background.

import "dart:io";

import "package:flutter/material.dart";
import "package:file_picker/file_picker.dart";
import "package:provider/provider.dart";

import "../providers/theme_provider.dart";

class BeautifyScreen extends StatefulWidget {
  const BeautifyScreen({super.key});

  @override
  State<BeautifyScreen> createState() => _BeautifyScreenState();
}

class _BeautifyScreenState extends State<BeautifyScreen> {
  final _bgUrlCtrl = TextEditingController();
  final _bgColorCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final theme = context.read<ThemeProvider>();
    _bgUrlCtrl.text = theme.backgroundUrl ?? "";
  }

  // Preset accent colors
  static const _presets = [
    Color(0xFF7C3AED), // Deep purple
    Color(0xFF3B82F6), // Blue
    Color(0xFF10B981), // Emerald
    Color(0xFFF59E0B), // Amber
    Color(0xFFEF4444), // Red
    Color(0xFFEC4899), // Pink
    Color(0xFF06B6D4), // Cyan
    Color(0xFF8B5CF6), // Violet
    Color(0xFF22C55E), // Green
    Color(0xFFF97316), // Orange
    Color(0xFFA855F7), // Purple
    Color(0xFF14B8A6), // Teal
  ];

  Future<void> _pickLocalImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
    );
    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      _bgUrlCtrl.text = path;
      context.read<ThemeProvider>().setBackgroundUrl("file://$path");
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text("美化")),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Accent Color ──
          const Text("主题色", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10, runSpacing: 10,
            children: _presets.map((c) => GestureDetector(
              onTap: () => theme.setAccentColor(c),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: theme.accentColor.value == c.value
                      ? Border.all(color: Colors.white, width: 3)
                      : Border.all(color: Colors.white24, width: 1),
                  boxShadow: theme.accentColor.value == c.value
                      ? [BoxShadow(color: c.withValues(alpha: 0.5), blurRadius: 12, spreadRadius: 2)]
                      : [],
                ),
              ),
            )).toList(),
          ),
          const SizedBox(height: 24),

          // ── Custom Accent ──
          const Text("自定义颜色", style: TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                decoration: const InputDecoration(
                  hintText: "FF7C3AED", isDense: true,
                  prefixText: "#",
                ),
                onSubmitted: (v) {
                  final hex = v.replaceFirst("#", "");
                  final c = int.tryParse(hex, radix: 16);
                  if (c != null) theme.setAccentColor(Color(c | 0xFF000000));
                },
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: theme.accentColor,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ]),
          const SizedBox(height: 32),

          // ── Background ──
          const Text("应用背景", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          if (theme.backgroundUrl != null && theme.backgroundUrl!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(theme.backgroundUrl!, height: 120, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink()),
              ),
            ),
          TextField(
            controller: _bgUrlCtrl,
            decoration: InputDecoration(
              labelText: "背景图片 URL",
              hintText: "https://example.com/bg.jpg",
              suffixIcon: _bgUrlCtrl.text.isNotEmpty
                  ? IconButton(icon: const Icon(Icons.clear),
                      onPressed: () { _bgUrlCtrl.clear(); theme.setBackgroundUrl(null); })
                  : null,
            ),
            onSubmitted: (v) => theme.setBackgroundUrl(v.trim().isEmpty ? null : v.trim()),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: () => theme.setBackgroundUrl(_bgUrlCtrl.text.trim().isEmpty ? null : _bgUrlCtrl.text.trim()),
                icon: const Icon(Icons.check),
                label: const Text("应用"),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _pickLocalImage,
              icon: const Icon(Icons.image),
              label: const Text("本地"),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () { _bgUrlCtrl.clear(); theme.setBackgroundUrl(null); },
              child: const Text("清除"),
            ),
          ]),
          const SizedBox(height: 12),

          // ── Solid bg color ──
          const Text("或使用纯色背景"),
          const SizedBox(height: 8),
          TextField(
            decoration: const InputDecoration(
              hintText: "FF1A1A2E", isDense: true, prefixText: "#",
              labelText: "背景纯色",
            ),
            onSubmitted: (v) {
              final hex = v.replaceFirst("#", "");
              final c = int.tryParse(hex, radix: 16);
              if (c != null) {
                theme.setBackgroundUrl(null);
                theme.setBgColor(Color(c | 0xFF000000));
              }
            },
          ),
          const SizedBox(height: 32),

          // ── Reset ──
          OutlinedButton.icon(
            onPressed: () {
              theme.setAccentColor(const Color(0xFF7C3AED));
              theme.setBackgroundUrl(null);
              theme.setBgColor(null);
              _bgUrlCtrl.clear();
            },
            icon: const Icon(Icons.restore),
            label: const Text("恢复默认"),
          ),
        ],
      ),
    );
  }
}
