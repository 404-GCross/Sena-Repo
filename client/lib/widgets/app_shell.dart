import "dart:ui";

import "package:flutter/material.dart";

import "../utils/theme_utils.dart";

class AppRadius {
  AppRadius._();

  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
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
    final cs = Theme.of(context).colorScheme;
    final bg = color ??
        (isDark
            ? cs.surfaceContainerHighest.withValues(alpha: 0.62)
            : cs.surface.withValues(alpha: 0.82));
    final content = Container(
      width: width,
      height: height,
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(radius),
        border: border ??
            Border.all(color: cardBorder(context).withValues(alpha: 0.86)),
        boxShadow: [
          BoxShadow(
            color: softShadowColor(context),
            blurRadius: 22,
            offset: const Offset(0, 10),
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
    final isCompact = MediaQuery.sizeOf(context).width < 600;
    final effectivePadding =
        isCompact ? const EdgeInsets.fromLTRB(12, 8, 12, 8) : padding;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: cs.surface.withValues(alpha: 0.54),
            border: Border(
              bottom: BorderSide(
                color: cardBorder(context).withValues(alpha: 0.72),
              ),
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: effectivePadding,
              child: Row(
                children: [
                  if (showBack) ...[
                    IconButton.filledTonal(
                      tooltip: "返回",
                      icon: const Icon(Icons.arrow_back_rounded),
                      onPressed: onBack ?? () => Navigator.maybePop(context),
                    ),
                    const SizedBox(width: AppGap.sm),
                  ],
                  if (!isCompact && leading != null) ...[
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: cs.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      child: Center(child: leading!),
                    ),
                    const SizedBox(width: AppGap.md),
                  ],
                  const Spacer(),
                  if (actions.isNotEmpty) ...[
                    const SizedBox(width: AppGap.sm),
                    Flexible(
                      child: Wrap(
                          spacing: AppGap.sm,
                          runSpacing: AppGap.sm,
                          alignment: WrapAlignment.end,
                          children: actions),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
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
          ? base.withValues(alpha: enabled ? 0.18 : 0.07)
          : base.withValues(alpha: enabled ? 0.09 : 0.04),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: enabled ? onPressed : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
      radius: AppRadius.lg,
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

class AppScaffold extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> actions;
  final Widget child;
  final bool showBack;
  final EdgeInsetsGeometry padding;
  final bool scrollable;
  final double maxWidth;
  final FloatingActionButton? floatingActionButton;

  const AppScaffold({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.actions = const [],
    required this.child,
    this.showBack = true,
    this.padding = const EdgeInsets.all(16),
    this.scrollable = true,
    this.maxWidth = 1180,
    this.floatingActionButton,
  });

  @override
  Widget build(BuildContext context) {
    final body = Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: padding,
          child: child,
        ),
      ),
    );
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: floatingActionButton,
      body: AppBackdrop(
        child: Column(
          children: [
            AppPageHeader(
              showBack: showBack,
              leading: leading,
              title: title,
              subtitle: subtitle,
              actions: actions,
            ),
            Expanded(
              child: scrollable ? SingleChildScrollView(child: body) : body,
            ),
          ],
        ),
      ),
    );
  }
}

class AppBackdrop extends StatelessWidget {
  final Widget child;

  const AppBackdrop({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
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
      child: child,
    );
  }
}

class AppSectionTitle extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const AppSectionTitle({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: cs.primary.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Icon(icon, size: 17, color: cs.primary),
        ),
        const SizedBox(width: AppGap.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppText.section.copyWith(color: cs.onSurface)),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(subtitle!,
                    style: AppText.caption.copyWith(color: hintColor(context))),
              ],
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class AppListTile extends StatelessWidget {
  final IconData icon;
  final Color? color;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const AppListTile({
    super.key,
    required this.icon,
    this.color,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = color ?? cs.primary;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: base.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(icon, size: 19, color: base),
              ),
              const SizedBox(width: AppGap.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: AppText.bodyMedium.copyWith(
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface,
                        )),
                    if (subtitle != null && subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(subtitle!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.caption
                              .copyWith(color: hintColor(context))),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppGap.sm),
              trailing ??
                  Icon(Icons.chevron_right_rounded,
                      size: 20, color: hintColor(context)),
            ],
          ),
        ),
      ),
    );
  }
}

class AppStateView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  final bool loading;

  const AppStateView({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.loading = false,
  });

  const AppStateView.loading({
    super.key,
    this.title = "加载中",
    this.message,
    this.action,
  })  : icon = Icons.hourglass_empty_rounded,
        loading = true;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppGap.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const SizedBox(
                width: 30,
                height: 30,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              )
            else
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: cs.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(AppRadius.xl),
                ),
                child: Icon(icon, color: cs.primary, size: 28),
              ),
            const SizedBox(height: AppGap.lg),
            Text(title,
                textAlign: TextAlign.center,
                style: AppText.title.copyWith(color: cs.onSurface)),
            if (message != null && message!.isNotEmpty) ...[
              const SizedBox(height: AppGap.sm),
              Text(message!,
                  textAlign: TextAlign.center,
                  style: AppText.bodySmall.copyWith(color: hintColor(context))),
            ],
            if (action != null) ...[
              const SizedBox(height: AppGap.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
