/// Theme color helpers using Material 3 ColorScheme tokens.
/// Reference: PiliPlus uses semantic tokens (onSurface, onSurfaceVariant, outline, etc.)
/// instead of hardcoded Colors.grey[N]. This automatically adapts to brightness.

import "package:flutter/material.dart";

Color cardBg(BuildContext context) =>
    Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4);

Color cardBorder(BuildContext context) =>
    Theme.of(context).colorScheme.outlineVariant;

Color sectionTextColor(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface;

Color sectionIconColor(BuildContext context) =>
    Theme.of(context).colorScheme.onSurfaceVariant;

Color subTextColor(BuildContext context) =>
    Theme.of(context).colorScheme.onSurfaceVariant;

Color hintColor(BuildContext context) =>
    Theme.of(context).colorScheme.onSurfaceVariant;

Color dimIconColor(BuildContext context) =>
    Theme.of(context).colorScheme.onSurfaceVariant;

Color placeholderBg(BuildContext context) =>
    Theme.of(context).colorScheme.surfaceContainerHighest;

Color placeholderIcon(BuildContext context) =>
    Theme.of(context).colorScheme.onSurfaceVariant;
