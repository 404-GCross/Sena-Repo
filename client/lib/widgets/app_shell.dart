import "dart:ui";

import "package:flutter/material.dart";

import "../utils/theme_utils.dart";

class AppRadius {
  AppRadius._();

  static const double sm = 10;
  static const double md = 14;
  static const double lg = 18;
  static const double xl = 22;
}

class AppMotion {
  AppMotion._();

  static const Duration fast = Duration(milliseconds: 180);
  static const Duration normal = Duration(milliseconds: 280);
  static const Curve curve = Curves.easeOutCubic;
}

class AppSurface extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final Color? color;
  final Border? border;
  final double? width;
  final double? height;
  final bool blur;

  const AppSurface({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.radius = AppRadius.lg,
    this.color,
    this.border,
    this.width,
    this.height,
    this.blur = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = color ??
        (isDark
            ? Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withValues(alpha: 0.56)
            : Theme.of(context).colorScheme.surface.withValues(alpha: 0.72));
    final content = Container(
      width: width,
      height: height,
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(radius),
        border: border ??
            Border.all(color: cardBorder(context).withValues(alpha: 0.72)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.16 : 0.06),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
    if (!blur) return content;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: content,
      ),
    );
  }
}

class AppPageHeader extends StatelessWidget {
  final Widget? leading;
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final EdgeInsetsGeometry padding;
  final bool showBack;
  final VoidCallback? onBack;

  const AppPageHeader({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.actions = const [],
    this.padding = const EdgeInsets.fromLTRB(24, 20, 24, 14),
    this.showBack = false,
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: 0.62),
        border: Border(
            bottom:
                BorderSide(color: cardBorder(context).withValues(alpha: 0.7))),
      ),
      child: Row(
        children: [
          if (showBack) ...[
            IconButton(
              tooltip: "返回",
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: onBack ?? () => Navigator.maybePop(context),
            ),
            const SizedBox(width: AppGap.sm),
          ],
          if (leading != null) ...[
            leading!,
            const SizedBox(width: AppGap.md),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: AppText.headline.copyWith(color: cs.onSurface)),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(subtitle!,
                      style: AppText.bodySmall
                          .copyWith(color: hintColor(context))),
                ],
              ],
            ),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(width: AppGap.md),
            Wrap(
                spacing: AppGap.sm,
                runSpacing: AppGap.sm,
                alignment: WrapAlignment.end,
                children: actions),
          ],
        ],
      ),
    );
  }
}

class AppSegmentedTabs extends StatelessWidget {
  final int selectedIndex;
  final List<AppSegmentedTab> tabs;
  final ValueChanged<int> onChanged;

  const AppSegmentedTabs({
    super.key,
    required this.selectedIndex,
    required this.tabs,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return AppSurface(
      radius: AppRadius.md,
      padding: const EdgeInsets.all(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final tab in tabs)
            _SegmentButton(
              tab: tab,
              selected: tab.index == selectedIndex,
              onTap: () => onChanged(tab.index),
            ),
        ],
      ),
    );
  }
}

class AppSegmentedTab {
  final int index;
  final IconData icon;
  final String label;

  const AppSegmentedTab(this.index, this.icon, this.label);
}

class _SegmentButton extends StatelessWidget {
  final AppSegmentedTab tab;
  final bool selected;
  final VoidCallback onTap;

  const _SegmentButton(
      {required this.tab, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: selected ? cs.primary.withValues(alpha: 0.13) : Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(tab.icon,
                  size: 16, color: selected ? cs.primary : hintColor(context)),
              const SizedBox(width: 6),
              Text(
                tab.label,
                style: AppText.bodySmall.copyWith(
                  color: selected ? cs.primary : subTextColor(context),
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AppActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color? color;
  final bool filled;
  final bool busy;

  const AppActionButton({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
    this.color,
    this.filled = false,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = color ?? cs.primary;
    final enabled = onPressed != null && !busy;
    return Material(
      color: filled
          ? base.withValues(alpha: enabled ? 0.16 : 0.07)
          : base.withValues(alpha: enabled ? 0.08 : 0.04),
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: enabled ? onPressed : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                SizedBox(
                    width: 15,
                    height: 15,
                    child:
                        CircularProgressIndicator(strokeWidth: 2, color: base))
              else
                Icon(icon, size: 16, color: enabled ? base : cs.outline),
              const SizedBox(width: 7),
              Text(
                label,
                style: AppText.bodySmall.copyWith(
                  color: enabled ? base : cs.outline,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AppStatusPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const AppStatusPill({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(label,
              style: AppText.caption
                  .copyWith(color: color, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class AppMetricCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const AppMetricCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return AppSurface(
      padding: const EdgeInsets.all(14),
      radius: AppRadius.md,
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppRadius.sm)),
            child: Icon(icon, color: color, size: 18),
          ),
          const SizedBox(width: AppGap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value,
                    style: AppText.title.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(label,
                    style: AppText.caption.copyWith(color: hintColor(context))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
