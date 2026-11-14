/// Beautify settings: accent color and per-device background image.

import "dart:io";
import "dart:ui";

import "package:file_picker/file_picker.dart";
import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../providers/theme_provider.dart";
import "../services/background_image_store.dart";
import "../utils/theme_utils.dart";
import "../widgets/app_shell.dart";
import "../widgets/feedback_dialog.dart";

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

  bool _mobile = false;
  bool _deviceInitialized = false;
  bool _backgroundBusy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_deviceInitialized) {
      _mobile = context.read<ThemeProvider>().isMobilePlatform;
      _deviceInitialized = true;
    }
  }

  Future<void> _pickLocalImage(ThemeProvider theme) async {
    if (_backgroundBusy) return;
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    final sourcePath = result?.files.single.path;
    if (sourcePath == null) return;
    if (!mounted) return;
    setState(() => _backgroundBusy = true);
    try {
      final stored = await BackgroundImageStore.importFile(
        sourcePath,
        slot: _mobile ? "mobile" : "desktop",
      );
      await theme.setBackgroundImage(mobile: _mobile, path: stored);
      if (mounted) _notice("背景图片已更新");
    } catch (e) {
      if (mounted) _notice("图片导入失败: $e");
    } finally {
      if (mounted) setState(() => _backgroundBusy = false);
    }
  }

  Future<void> _promptImageUrl(ThemeProvider theme) async {
    final current = theme.backgroundFor(_mobile).path ?? "";
    final controller = TextEditingController(
      text: current.startsWith("http") ? current : "",
    );
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          "使用图片网址",
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: "图片网址",
            hintText: "https://example.com/background.jpg",
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("取消"),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              final uri = Uri.tryParse(value);
              if (uri == null ||
                  !(uri.scheme == "http" || uri.scheme == "https") ||
                  uri.host.isEmpty) {
                return;
              }
              Navigator.pop(ctx, value);
            },
            child: const Text("使用"),
          ),
        ],
      ),
    );
    if (url == null || !mounted) return;
    setState(() => _backgroundBusy = true);
    try {
      final stored = await BackgroundImageStore.importUrl(
        url,
        slot: _mobile ? "mobile" : "desktop",
      );
      await theme.setBackgroundImage(mobile: _mobile, path: stored);
      if (mounted) _notice("背景图片已更新");
    } catch (e) {
      if (mounted) _notice("图片下载失败: $e");
    } finally {
      if (mounted) setState(() => _backgroundBusy = false);
    }
  }

  Future<void> _notice(String message) async {
    if (!mounted) return;
    await showFeedbackDialog(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeProvider>();
    final background = theme.backgroundFor(_mobile);

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
                  label: "恢复默认强调色",
                  onPressed: () {
                    theme.setAccentColor(const Color(0xFF7C3AED));
                  },
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
                  icon: Icons.wallpaper_outlined,
                  title: "界面背景",
                  subtitle: "手机竖屏与 PC 横屏分别保存，仅影响当前设备",
                ),
                const SizedBox(height: AppGap.lg),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                      value: true,
                      label: Text("手机"),
                      icon: Icon(Icons.smartphone, size: 18),
                    ),
                    ButtonSegment(
                      value: false,
                      label: Text("PC"),
                      icon: Icon(Icons.desktop_windows, size: 18),
                    ),
                  ],
                  selected: {_mobile},
                  onSelectionChanged: (selection) {
                    setState(() => _mobile = selection.first);
                  },
                ),
                const SizedBox(height: AppGap.lg),
                _BackgroundPreview(settings: background, mobile: _mobile),
                const SizedBox(height: AppGap.lg),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    OutlinedButton.icon(
                      onPressed:
                          _backgroundBusy ? null : () => _pickLocalImage(theme),
                      icon: const Icon(Icons.folder_open, size: 18),
                      label: const Text("选择本地图片"),
                    ),
                    OutlinedButton.icon(
                      onPressed:
                          _backgroundBusy ? null : () => _promptImageUrl(theme),
                      icon: const Icon(Icons.link, size: 18),
                      label: const Text("使用图片网址"),
                    ),
                    TextButton.icon(
                      onPressed: _backgroundBusy || !background.hasImage
                          ? null
                          : () => theme.clearBackground(_mobile),
                      icon: const Icon(Icons.restore, size: 18),
                      label: const Text("恢复默认背景"),
                    ),
                  ],
                ),
                if (_backgroundBusy)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          "正在处理图片…",
                          style: TextStyle(
                            fontSize: 12,
                            color: hintColor(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: AppGap.lg),
                _SettingSlider(
                  label: "图片不透明度",
                  value: background.opacity,
                  min: 0.05,
                  max: 1,
                  divisions: 19,
                  display: "${(background.opacity * 100).round()}%",
                  onChanged: (v) => theme.setBackgroundOpacity(_mobile, v),
                ),
                _SettingSlider(
                  label: "背景模糊",
                  value: background.blur,
                  min: 0,
                  max: 24,
                  divisions: 24,
                  display: background.blur.round().toString(),
                  onChanged: (v) => theme.setBackgroundBlur(_mobile, v),
                ),
                _SettingSlider(
                  label: "水平位置",
                  value: background.alignX,
                  min: -1,
                  max: 1,
                  divisions: 20,
                  display: _alignmentLabel(background.alignX),
                  onChanged: (v) =>
                      theme.setBackgroundAlignment(_mobile, v, background.alignY),
                ),
                _SettingSlider(
                  label: "垂直位置",
                  value: background.alignY,
                  min: -1,
                  max: 1,
                  divisions: 20,
                  display: _alignmentLabel(background.alignY),
                  onChanged: (v) =>
                      theme.setBackgroundAlignment(_mobile, background.alignX, v),
                ),
                const SizedBox(height: 4),
                Text(
                  "图片会复制到应用目录，重启后仍然可用。恢复默认会删除已导入的本地图片。",
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.6,
                    color: hintColor(context),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _alignmentLabel(double value) {
    if (value.abs() < 0.05) return "居中";
    return value < 0 ? "靠左/上" : "靠右/下";
  }
}

class _SettingSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final ValueChanged<double> onChanged;

  const _SettingSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: TextStyle(fontSize: 12.5, color: subTextColor(context)),
          ),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 52,
          child: Text(
            display,
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 12, color: hintColor(context)),
          ),
        ),
      ],
    );
  }
}

class _BackgroundPreview extends StatelessWidget {
  final BackgroundSettings settings;
  final bool mobile;

  const _BackgroundPreview({required this.settings, required this.mobile});

  @override
  Widget build(BuildContext context) {
    final path = settings.path ?? "";
    final alignment = Alignment(settings.alignX, settings.alignY);
    final Widget? image = path.isEmpty
        ? null
        : path.startsWith("http")
            ? Image.network(
                path,
                fit: BoxFit.cover,
                alignment: alignment,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              )
            : Image.file(
                File(path),
                fit: BoxFit.cover,
                alignment: alignment,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              );

    Widget? layer = image == null
        ? null
        : Opacity(opacity: settings.opacity, child: image);
    if (layer != null && settings.blur > 0) {
      layer = ClipRect(
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(
            sigmaX: settings.blur,
            sigmaY: settings.blur,
            tileMode: TileMode.clamp,
          ),
          child: layer,
        ),
      );
    }

    return Center(
      child: SizedBox(
        height: 240,
        child: AspectRatio(
          aspectRatio: mobile ? 9 / 16 : 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        appBackgroundTop(context),
                        appBackgroundBottom(context),
                      ],
                    ),
                  ),
                ),
                if (layer != null) layer,
                Center(
                  child: Container(
                    margin: EdgeInsets.symmetric(
                      horizontal: mobile ? 18 : 48,
                      vertical: 28,
                    ),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.86),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: cardBorder(context)),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.auto_awesome,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          "Sena Repo",
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: sectionTextColor(context),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          mobile ? "手机预览" : "PC 预览",
                          style: TextStyle(
                            fontSize: 10.5,
                            color: hintColor(context),
                          ),
                        ),
                      ],
                    ),
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
