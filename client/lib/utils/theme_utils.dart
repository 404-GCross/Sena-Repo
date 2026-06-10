/// Theme color helpers using Material 3 ColorScheme tokens.
/// Reference: PiliPlus uses semantic tokens (onSurface, onSurfaceVariant, outline, etc.)

import "package:flutter/material.dart";

Color cardBg(BuildContext context) =>
    Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5);

Color cardBorder(BuildContext context) =>
    Theme.of(context).colorScheme.outline;

Color sectionTextColor(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface;

Color sectionIconColor(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);

Color subTextColor(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7);

Color hintColor(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);

Color dimIconColor(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55);

Color placeholderBg(BuildContext context) =>
    Theme.of(context).colorScheme.surfaceContainerHighest;

Color placeholderIcon(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4);
