import "dart:ui";

import "package:flutter/foundation.dart" show defaultTargetPlatform, kIsWeb;
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
  bool _revealed = false;
  Offset? _pointerDownPosition;
  Duration? _pointerDownTime;
  int? _pointerId;

  bool get _supportsHoverReveal =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS);

  bool get _supportsTapReveal => !_supportsHoverReveal;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!context.read<SettingsProvider>().blurNsfwCovers) {
      _revealed = false;
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    if (!_supportsTapReveal) return;
    _pointerId = event.pointer;
    _pointerDownPosition = event.position;
    _pointerDownTime = event.timeStamp;
  }

  void _onPointerUp(PointerUpEvent event) {
    if (!_supportsTapReveal || event.pointer != _pointerId) return;
    final position = _pointerDownPosition;
    final time = _pointerDownTime;
    _pointerId = null;
    _pointerDownPosition = null;
    _pointerDownTime = null;
    if (position == null || time == null) return;

    final isTap = (event.position - position).distance <= 12 &&
        event.timeStamp - time <= const Duration(milliseconds: 500);
    if (isTap && mounted) setState(() => _revealed = !_revealed);
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _pointerId) return;
    _pointerId = null;
    _pointerDownPosition = null;
    _pointerDownTime = null;
  }

  @override
  Widget build(BuildContext context) {
    final blurEnabled = context.watch<SettingsProvider>().blurNsfwCovers;
    final revealed =
        (_supportsHoverReveal && _hovered) || (_supportsTapReveal && _revealed);
    final shouldBlur = widget.isNsfw && blurEnabled && !revealed;
    final content = shouldBlur
        ? ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: widget.child,
          )
        : widget.child;

    if (!widget.isNsfw || !blurEnabled) return content;

    return Listener(
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: MouseRegion(
        onEnter: _supportsHoverReveal
            ? (_) => setState(() => _hovered = true)
            : null,
        onExit: _supportsHoverReveal
            ? (_) => setState(() => _hovered = false)
            : null,
        child: Stack(
          fit: StackFit.expand,
          children: [
            content,
            if (!revealed)
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
      ),
    );
  }
}
