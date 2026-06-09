/// List view for game library — compact style inspired by myGal.

import "package:flutter/material.dart";

import "../models/game.dart";

class GameList extends StatelessWidget {
  final List<GameSummary> games;
  final void Function(GameSummary game) onTap;
  final String coverBaseUrl;

  const GameList({
    super.key,
    required this.games,
    required this.onTap,
    this.coverBaseUrl = "",
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final columns = w > 1600 ? 3 : w > 1000 ? 2 : 1;
        final colWidth = (w - 16) / columns;

        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Wrap(
            spacing: 8, runSpacing: 4,
            children: games.map((game) => SizedBox(
              width: colWidth - (columns > 1 ? 8 : 0),
              child: _GameListTile(game: game, onTap: () => onTap(game), coverBaseUrl: coverBaseUrl),
            )).toList(),
          ),
        );
      },
    );
  }
}

class _GameListTile extends StatefulWidget {
  final GameSummary game;
  final VoidCallback onTap;
  final String coverBaseUrl;

  const _GameListTile({required this.game, required this.onTap, this.coverBaseUrl = ""});

  @override
  State<_GameListTile> createState() => _GameListTileState();
}

class _GameListTileState extends State<_GameListTile> {
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
          duration: const Duration(milliseconds: 150),
          transform: _hovered
              ? (Matrix4.identity()..translate(0.0, -1.0))
              : Matrix4.identity(),
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: _hovered
                ? Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: _hovered
                ? Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3))
                : Border.all(color: Colors.transparent),
          ),
          child: Row(
            children: [
              // Cover thumbnail
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 56, height: 40,
                  child: hasCover
                      ? Image.network(
                          "${widget.coverBaseUrl}/api/files/covers${game.coverPath!}",
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _placeholder(),
                        )
                      : _placeholder(),
                ),
              ),
              const SizedBox(width: 12),
              // Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(game.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    if (game.companyName != null)
                      Text(game.companyName!, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Tags
              if (game.tagNames.isNotEmpty)
                ...game.tagNames.take(3).map((t) => Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(t, style: const TextStyle(fontSize: 11)),
                      ),
                    )),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, color: Colors.grey[600], size: 20),
            ],
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
          colors: [Colors.grey[800]!, Colors.grey[850]!],
        ),
      ),
      child: Center(child: Icon(Icons.videogame_asset, color: Colors.grey[700], size: 20)),
    );
  }
}
