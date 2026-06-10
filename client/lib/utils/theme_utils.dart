/// Theme-aware color helpers for light/dark mode adaptation.

import "package:flutter/material.dart";

/// Semi-transparent card background
Color cardBg(BuildContext context) => Theme.of(context).brightness == Brightness.dark
    ? Colors.white.withValues(alpha: 0.04)
    : Colors.grey.withValues(alpha: 0.08);

/// Card border color
Color cardBorder(BuildContext context) => Theme.of(context).brightness == Brightness.dark
    ? Colors.white.withValues(alpha: 0.06)
    : Colors.grey.withValues(alpha: 0.15);

/// Dimmed icon/text color
Color dimColor(BuildContext context) => Theme.of(context).brightness == Brightness.dark
    ? Colors.white60
    : Colors.black54;

/// Bold section text
Color boldColor(BuildContext context) => Theme.of(context).brightness == Brightness.dark
    ? Colors.white70
    : Colors.black87;

/// Grey that works in both modes
Color? grey(BuildContext context, int shade) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final map = {50: 50, 100: 100, 200: 200, 300: 300, 400: 400, 500: 500, 600: 600, 700: 700, 800: 800, 850: 850, 900: 900};
  final s = map[shade] ?? 500;
  return isDark ? Colors.grey[s] : Colors.grey[1000 - s];
}

/// Placeholder/image background
Color placeholderBg(BuildContext context) => Theme.of(context).brightness == Brightness.dark
    ? Colors.grey[850]!
    : Colors.grey[200]!;

/// Placeholder icon color
Color placeholderIcon(BuildContext context) => Theme.of(context).brightness == Brightness.dark
    ? Colors.grey[700]!
    : Colors.grey[400]!;

/// Subtitle/secondary text — readable in both modes
Color subTextColor(BuildContext context) => Theme.of(context).brightness == Brightness.dark
    ? Colors.grey[400]!
    : Colors.grey[600]!;

/// Hint/muted text
Color hintColor(BuildContext context) => Theme.of(context).brightness == Brightness.dark
    ? Colors.grey[500]!
    : Colors.grey[600]!;

/// Dim icon color
Color dimIconColor(BuildContext context) => Theme.of(context).brightness == Brightness.dark
    ? Colors.grey[500]!
    : Colors.grey[600]!;
