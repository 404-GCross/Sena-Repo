import "dart:async";
import "dart:ui";

import "package:flutter/foundation.dart" show defaultTargetPlatform, kIsWeb;
import "package:flutter/material.dart";
import "package:flutter/services.dart";
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
  bool _revealed = false;
  Timer? _revealTimer;
  Timer? _hoverExitTimer;

  bool get _supportsHoverReveal =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS);

  bool get _supportsTimedReveal => !_supportsHoverReveal;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!context.read<SettingsProvider>().blurNsfwCovers) {
      _revealTimer?.cancel();
      _revealed = false;
    }
  }

  @override
  void dispose() {
    _revealTimer?.cancel();
    _hoverExitTimer?.cancel();
    super.dispose();
  }

  void _setHovered(bool value) {
    if (!_supportsHoverReveal || !mounted) return;
    _hoverExitTimer?.cancel();
    if (value) {
      if (!_hovered) setState(() => _hovered = true);
      return;
    }

    // Game library cards animate on hover. On Linux this can briefly move the
    // pointer out of the nested MouseRegion during the scale transition.
    _hoverExitTimer = Timer(const Duration(milliseconds: 140), () {
      if (mounted && _hovered) setState(() => _hovered = false);
    });
  }

  void _temporarilyReveal() {
    if (!_supportsTimedReveal || !mounted) return;
    _revealTimer?.cancel();
    HapticFeedback.selectionClick();
    setState(() => _revealed = true);
    _revealTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _revealed = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final blurEnabled = context.watch<SettingsProvider>().blurNsfwCovers;
    final revealed = (_supportsHoverReveal && _hovered) ||
        (_supportsTimedReveal && _revealed);
    final shouldBlur = widget.isNsfw && blurEnabled && !revealed;
    final content = shouldBlur
        ? ClipRect(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: widget.child,
            ),
          )
        : widget.child;

    if (!widget.isNsfw || !blurEnabled) return content;

    return Semantics(
      label: "NSFW 图片",
      child: MouseRegion(
        onEnter: _supportsHoverReveal ? (_) => _setHovered(true) : null,
        onExit: _supportsHoverReveal ? (_) => _setHovered(false) : null,
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            content,
            if (!revealed)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.16),
                  child: Center(
                    child: _supportsTimedReveal
                        ? Semantics(
                            button: true,
                            label: "临时查看 NSFW 图片",
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: _temporarilyReveal,
                              child: SizedBox(
                                width: 48,
                                height: 48,
                                child: Center(child: _privacyIcon()),
                              ),
                            ),
                          )
                        : IgnorePointer(child: _privacyIcon()),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _privacyIcon() {
    return DecoratedBox(
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
    );
  }
}
