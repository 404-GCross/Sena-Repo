/// Grid view for game library — LunaBox-inspired card design.

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
    final isPC = !Platform.isAndroid;
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: _coverSize,
        childAspectRatio: isPC ? 0.83 : 0.73,  // PC: 3/3.6 like LunaBox
        crossAxisSpacing: isPC ? 10 : 8,
        mainAxisSpacing: isPC ? 12 : 8,
      ),
      itemCount: widget.games.length,
      itemBuilder: (context, index) {
        final game = widget.games[index];
        return isPC
            ? _LunaBoxCard(game: game, onTap: () => widget.onTap(game), coverBaseUrl: widget.coverBaseUrl)
            : _GameCard(game: game, onTap: () => widget.onTap(game), coverBaseUrl: widget.coverBaseUrl);
      },
    );
  }
}

// ── PC: LunaBox-style card ──

class _LunaBoxCard extends StatefulWidget {
  final GameSummary game;
  final VoidCallback onTap;
  final String coverBaseUrl;

  const _LunaBoxCard({required this.game, required this.onTap, this.coverBaseUrl = ""});

  @override
  State<_LunaBoxCard> createState() => _LunaBoxCardState();
}

class _LunaBoxCardState extends State<_LunaBoxCard> {
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
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _hovered
                  ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)
                  : Colors.white.withValues(alpha: 0.08),
              width: 1,
            ),
            boxShadow: _hovered
                ? [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 16, offset: const Offset(0, 4))]
                : [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 6, offset: const Offset(0, 1))],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Cover with hover zoom
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Cover image
                      Transform.scale(
                        scale: _hovered ? 1.1 : 1.0,
                        child: hasCover
                            ? Image.network(
                                "${widget.coverBaseUrl}/api/files/covers${game.coverPath!}",
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => _lunaPlaceholder(),
                                loadingBuilder: (_, child, progress) =>
                                    progress == null ? child : _lunaPlaceholder(),
                              )
                            : _lunaPlaceholder(),
                      ),
                      // Hover overlay
                      if (_hovered)
                        Container(
                          color: Colors.black.withValues(alpha: 0.4),
                          child: Center(
                            child: Container(
                              width: 44, height: 44,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.25),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.info_outline, color: Colors.white, size: 22),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                // Meta
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(game.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                      if (game.companyName != null)
                        Text(game.companyName!, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11, color: Colors.grey[500])),
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

  Widget _lunaPlaceholder() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [Colors.grey[800]!, Colors.grey[850]!],
        ),
      ),
      child: Center(
        child: Icon(Icons.image_not_supported_outlined, size: 36, color: Colors.grey[600]),
      ),
    );
  }
}

// ── Android: simple card ──

class _GameCard extends StatelessWidget {
  final GameSummary game;
  final VoidCallback onTap;
  final String coverBaseUrl;

  const _GameCard({required this.game, required this.onTap, this.coverBaseUrl = ""});

  @override
  Widget build(BuildContext context) {
    final hasCover = game.coverPath != null && coverBaseUrl.isNotEmpty;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(flex: 3, child: Container(color: Colors.grey[850],
            child: hasCover
                ? Image.network("$coverBaseUrl/api/files/covers${game.coverPath!}",
                    fit: BoxFit.cover, errorBuilder: (_, __, ___) => _placeholder())
                : _placeholder())),
          Expanded(flex: 1, child: Padding(padding: const EdgeInsets.all(8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(game.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              const SizedBox(height: 2),
              Text(game.platformSummary, style: TextStyle(color: Colors.grey[400], fontSize: 11)),
            ]))),
        ]),
      ),
    );
  }

  Widget _placeholder() => const Center(child: Icon(Icons.videogame_asset, size: 48, color: Colors.grey));
}
