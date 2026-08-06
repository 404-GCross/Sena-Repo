/// Beautify settings: accent color picker.

import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../providers/theme_provider.dart";
import "../utils/theme_utils.dart";
import "../widgets/app_shell.dart";

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

    return AppScaffold(
      title: "美化",
      subtitle: "调整客户端强调色和界面观感",
      leading: const Icon(Icons.palette_outlined, size: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppSurface(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AppSectionTitle(
                  icon: Icons.color_lens_outlined,
                  title: "主题色",
                  subtitle: "选择一个更适合当前壁纸和界面的强调色",
                ),
                const SizedBox(height: AppGap.lg),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: _presets
                      .map(
                        (c) => _ColorSwatch(
                          color: c,
                          selected: theme.accentColor.value == c.value,
                          onTap: () => theme.setAccentColor(c),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppGap.lg),
          AppSurface(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AppSectionTitle(
                  icon: Icons.tune_outlined,
                  title: "自定义颜色",
                  subtitle: "输入 6 位十六进制颜色值",
                ),
                const SizedBox(height: AppGap.lg),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        decoration: const InputDecoration(
                          hintText: "7C3AED",
                          isDense: true,
                          prefixText: "#",
                        ),
                        onSubmitted: (v) {
                          final hex = v.replaceFirst("#", "");
                          final c = int.tryParse(hex, radix: 16);
                          if (c != null) {
                            theme.setAccentColor(Color(c | 0xFF000000));
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: AppGap.md),
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: theme.accentColor,
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        border: Border.all(color: cardBorder(context)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppGap.lg),
                AppActionButton(
                  icon: Icons.restore,
                  label: "恢复默认",
                  onPressed: () {
                    theme.setAccentColor(const Color(0xFF7C3AED));
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _ColorSwatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message:
          "#${color.value.toRadixString(16).padLeft(8, "0").substring(2).toUpperCase()}",
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.onSurface
                  : Colors.white,
              width: selected ? 3 : 1,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: 0.35),
                      blurRadius: 12,
                      offset: const Offset(0, 5),
                    )
                  ]
                : [],
          ),
          child: selected
              ? const Icon(Icons.check_rounded, color: Colors.white, size: 18)
              : null,
        ),
      ),
    );
  }
}
