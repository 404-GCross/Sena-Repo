/// Grid view for game library — full-bleed cover style inspired by myGal.

import "dart:io" show Platform;

import "package:flutter/material.dart";
import "package:shared_preferences/shared_preferences.dart";

import "../models/game.dart";

class GameGrid extends StatefulWidget {
  final List<GameSummary> games;
  final void Function(GameSummary game) onTap;
  final String coverBaseUrl;

  const GameGrid({
    super.key,
    required this.games,
    required this.onTap,
    this.coverBaseUrl = "",
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
      padding: const EdgeInsets.all(8),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: _coverSize,
        childAspectRatio: 0.73,  // portrait box art ratio
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: widget.games.length,
      itemBuilder: (context, index) {
        final game = widget.games[index];
        return _GameCard(game: game, onTap: () => widget.onTap(game), coverBaseUrl: widget.coverBaseUrl);
      },
    );
  }
}

class _GameCard extends StatefulWidget {
  final GameSummary game;
  final VoidCallback onTap;
  final String coverBaseUrl;

  const _GameCard({required this.game, required this.onTap, this.coverBaseUrl = ""});

  @override
  State<_GameCard> createState() => _GameCardState();
}

class _GameCardState extends State<_GameCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    final hasCover = game.coverPath != null && widget.coverBaseUrl.isNotEmpty;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          transform: _hovered
              ? (Matrix4.identity()..translate(0.0, -3.0))
              : Matrix4.identity(),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            boxShadow: _hovered
                ? [BoxShadow(color: Colors.black45, blurRadius: 16, offset: const Offset(0, 6))]
                : [BoxShadow(color: Colors.black26, blurRadius: 6, offset: const Offset(0, 2))],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Cover image or placeholder
                if (hasCover)
                  Image.network(
                    "${widget.coverBaseUrl}/api/files/covers${game.coverPath!}",
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _placeholder(),
                    loadingBuilder: (_, child, progress) {
                      if (progress == null) return child;
                      return _placeholder();
                    },
                  )
                else
                  _placeholder(),

                // Gradient overlay: darkens bottom for text readability
                const Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.transparent,
                          Color(0x44000000),
                          Color(0xBB000000),
                        ],
                        stops: [0.0, 0.45, 0.7, 1.0],
                      ),
                    ),
                  ),
                ),

                // Tags (top area, centered)
                if (game.tagNames.isNotEmpty)
                  Positioned(
                    left: 6, right: 6, top: 8,
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 4, runSpacing: 4,
                      children: game.tagNames.take(2).map((t) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
                        ),
                        child: Text(t, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w500)),
                      )).toList(),
                    ),
                  ),

                // Game name + platform (bottom)
                Positioned(
                  left: 8, right: 8, bottom: 8,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        game.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                        ),
                      ),
                      if (game.companyName != null)
                        Text(
                          game.companyName!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Colors.white70, fontSize: 11, height: 1.3),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.grey[800]!, Colors.grey[900]!],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: Icon(Icons.videogame_asset, size: 36, color: Colors.grey[500]),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: Text("无封面", style: TextStyle(color: Colors.grey[500], fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }
}
