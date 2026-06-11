/// Unified empty state placeholder — consistent across all screens.

import "package:flutter/material.dart";

import "../utils/theme_utils.dart";

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppGap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: dimIconColor(context)),
            const SizedBox(height: AppGap.lg),
            Text(title, style: AppText.bodySmall.copyWith(color: subTextColor(context))),
            if (subtitle != null) ...[
              const SizedBox(height: AppGap.sm),
              Text(subtitle!, textAlign: TextAlign.center,
                  style: AppText.caption.copyWith(color: hintColor(context))),
            ],
            if (action != null) ...[
              const SizedBox(height: AppGap.xl),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
