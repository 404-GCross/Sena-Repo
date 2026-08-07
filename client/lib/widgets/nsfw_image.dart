import "dart:io" show Platform;
import "dart:ui";

import "package:flutter/foundation.dart" show kIsWeb;
import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../providers/settings_provider.dart";

/// Applies the user's NSFW image preference consistently across all views.
class NsfwImage extends StatefulWidget {
  final bool isNsfw;
  final Widget child;

  const NsfwImage({super.key, required this.isNsfw, required this.child});

  @override
  State<NsfwImage> createState() => _NsfwImageState();
}

class _NsfwImageState extends State<NsfwImage> {
  bool _hovered = false;

  bool get _supportsHoverReveal =>
      !kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS);

  @override
  Widget build(BuildContext context) {
    final blurEnabled = context.watch<SettingsProvider>().blurNsfwCovers;
    final shouldBlur =
        widget.isNsfw && blurEnabled && !(_supportsHoverReveal && _hovered);
    final content = shouldBlur
        ? ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: widget.child,
          )
        : widget.child;

    if (!widget.isNsfw || !blurEnabled) return content;

    return MouseRegion(
      onEnter:
          _supportsHoverReveal ? (_) => setState(() => _hovered = true) : null,
      onExit:
          _supportsHoverReveal ? (_) => setState(() => _hovered = false) : null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          content,
          if (!(_supportsHoverReveal && _hovered))
            IgnorePointer(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.16),
                child: Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.46),
                      shape: BoxShape.circle,
                    ),
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(
                        Icons.visibility_off_outlined,
                        size: 20,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
