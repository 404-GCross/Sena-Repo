/// Blurs a child in place without changing its layout size.

import "dart:ui" show ImageFilter;

import "package:flutter/material.dart";

class Obscured extends StatelessWidget {
  final bool enabled;
  final double sigma;
  final Widget child;

  const Obscured({
    super.key,
    required this.enabled,
    required this.child,
    this.sigma = 4,
  });

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return ClipRect(
      child: ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: child,
      ),
    );
  }
}
