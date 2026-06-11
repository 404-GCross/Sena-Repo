/// Theme helpers — colors, typography, and spacing tokens.

import "package:flutter/material.dart";

// ── Colors ──

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

// ── Typography scale ──

class AppText {
  AppText._();

  /// 11px — tiny labels, badges
  static const TextStyle caption = TextStyle(fontSize: 11);

  /// 13px — metadata, secondary text, tags
  static const TextStyle bodySmall = TextStyle(fontSize: 13);

  /// 15px — normal body text
  static const TextStyle body = TextStyle(fontSize: 15);

  /// 17px — card titles, section headers
  static const TextStyle title = TextStyle(fontSize: 17, fontWeight: FontWeight.w600);

  /// 22px — page titles, dialog headers
  static const TextStyle headline = TextStyle(fontSize: 22, fontWeight: FontWeight.bold);

  /// 28px — hero / large display
  static const TextStyle display = TextStyle(fontSize: 28, fontWeight: FontWeight.bold);
}

// ── Spacing scale (multiples of 4) ──

class AppGap {
  AppGap._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}
