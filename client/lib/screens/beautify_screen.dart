/// Beautify settings: accent color picker.

import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../providers/theme_provider.dart";

class BeautifyScreen extends StatefulWidget {
  const BeautifyScreen({super.key});

  @override
  State<BeautifyScreen> createState() => _BeautifyScreenState();
}

class _BeautifyScreenState extends State<BeautifyScreen> {
  static const _presets = [
    Color(0xFF7C3AED),
    Color(0xFF3B82F6),
    Color(0xFF10B981),
    Color(0xFFF59E0B),
    Color(0xFFEF4444),
    Color(0xFFEC4899),
    Color(0xFF06B6D4),
    Color(0xFF8B5CF6),
    Color(0xFF22C55E),
    Color(0xFFF97316),
    Color(0xFFA855F7),
    Color(0xFF14B8A6),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text("美化")),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
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

          OutlinedButton.icon(
            onPressed: () {
              theme.setAccentColor(const Color(0xFF7C3AED));
            },
            icon: const Icon(Icons.restore),
            label: const Text("恢复默认"),
          ),
        ],
      ),
    );
  }

}
