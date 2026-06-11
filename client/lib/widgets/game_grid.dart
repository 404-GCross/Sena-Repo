/// Grid view for game library — poster-style cards with hover effects.

import "dart:io" show Platform;

import "package:flutter/material.dart";
import "package:shared_preferences/shared_preferences.dart";

import "../models/game.dart";
import "../utils/theme_utils.dart";

class GameGrid extends StatefulWidget {
  final List<GameSummary> games;
  final void Function(GameSummary game) onTap;
  final String coverBaseUrl;
  final Set<int> selectedIds;
  final void Function(int id)? onSelect;
  final bool multiSelect;

  const GameGrid({
    super.key,
    required this.games,
    required this.onTap,
    this.coverBaseUrl = "",
    this.selectedIds = const {},
    this.onSelect,
    this.multiSelect = false,
  });

  @override
  State<GameGrid> createState() => _GameGridState();
}

class _GameGridState extends State<GameGrid> {
  double _coverSize = 200;

  @override
  void initState() {
    super.initState();
    _loadCoverSize();
  }

  Future<void> _loadCoverSize() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getDouble("cover_size") ?? (Platform.isAndroid ? 160.0 : 200.0);
    if (mounted) setState(() => _coverSize = v);
  }

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(AppGap.sm),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: _coverSize,
        childAspectRatio: 0.7,
        crossAxisSpacing: AppGap.md,
        mainAxisSpacing: AppGap.md,
      ),
      itemCount: widget.games.length,
      itemBuilder: (context, index) {
        final game = widget.games[index];
        return Stack(children: [
          _PosterCard(game: game, onTap: () => widget.onTap(game), coverBaseUrl: widget.coverBaseUrl),
          if (widget.multiSelect)
            Positioned(
              top: 8, left: 8,
              child: Container(
                width: 24, height: 24,
                decoration: BoxDecoration(
                  color: widget.selectedIds.contains(game.id)
                      ? Theme.of(context).colorScheme.primary
                      : Colors.black54,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white70, width: 2),
                ),
                child: widget.selectedIds.contains(game.id)
                    ? const Icon(Icons.check, size: 16, color: Colors.white)
                    : null,
              ),
            ),
        ]);
      },
    );
  }
}

class _PosterCard extends StatefulWidget {
  final GameSummary game;
  final VoidCallback onTap;
  final String coverBaseUrl;

  const _PosterCard({required this.game, required this.onTap, this.coverBaseUrl = ""});

  @override
  State<_PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<_PosterCard> with SingleTickerProviderStateMixin {
  bool _hovered = false;
  late final AnimationController _ctrl;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(duration: const Duration(milliseconds: 200), vsync: this);
    _scale = Tween<double>(begin: 1.0, end: 1.04).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _setHovered(bool v) {
    setState(() => _hovered = v);
    if (v) { _ctrl.forward(); } else { _ctrl.reverse(); }
  }

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    final hasCover = game.coverPath != null && widget.coverBaseUrl.isNotEmpty;
    final cs = Theme.of(context).colorScheme;

    return MouseRegion(
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: _scale,
          builder: (_, child) => Transform.scale(scale: _scale.value, child: child),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: _hovered
                      ? cs.primary.withValues(alpha: 0.25)
                      : Colors.black.withValues(alpha: 0.12),
                  blurRadius: _hovered ? 20 : 8,
                  offset: Offset(0, _hovered ? 8 : 2),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Cover image
                  if (hasCover)
                    Image.network(
                      "${widget.coverBaseUrl}/api/files/covers${game.coverPath!}",
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _placeholder(),
                      loadingBuilder: (_, child, progress) =>
                          progress == null ? child : _placeholder(),
                    )
                  else
                    _placeholder(),

                  // Bottom gradient + metadata
                  Positioned(
                    left: 0, right: 0, bottom: 0,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.85),
                            Colors.black.withValues(alpha: 0.4),
                            Colors.transparent,
                          ],
                          stops: const [0.0, 0.55, 1.0],
                        ),
                      ),
                      padding: const EdgeInsets.fromLTRB(10, 32, 10, 10),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(game.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w700,
                              color: Colors.white, height: 1.2,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            game.developer ?? game.companyName ?? "",
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11, color: Colors.white70, height: 1.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Hover overlay
                  if (_hovered)
                    Container(color: cs.primary.withValues(alpha: 0.12)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _placeholder() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [cs.surfaceContainerHighest, cs.surfaceContainerLow],
        ),
      ),
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.videogame_asset_rounded, size: 40, color: cs.onSurface.withValues(alpha: 0.25)),
          const SizedBox(height: 8),
          Text(widget.game.name, maxLines: 2, overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: cs.onSurface.withValues(alpha: 0.5))),
        ]),
      ),
    );
  }
}

// ── Helpers ──

class AnimatedBuilder extends AnimatedWidget {
  final Widget? child;
  final Widget Function(BuildContext, Widget?) builder;

  const AnimatedBuilder({
    super.key,
    required super.listenable,
    required this.builder,
    this.child,
  }) : assert(listenable != null);

  @override
  Widget build(BuildContext context) => builder(context, child);
}
