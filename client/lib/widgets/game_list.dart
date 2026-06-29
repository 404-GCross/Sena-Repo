/// List view for game library — compact row design with poster thumbnail.

import "package:flutter/material.dart";

import "../models/game.dart";
import "../utils/theme_utils.dart";

class GameList extends StatelessWidget {
  final List<GameSummary> games;
  final void Function(GameSummary game) onTap;
  final String coverBaseUrl;
  final Set<int> selectedIds;
  final void Function(int id)? onSelect;
  final bool multiSelect;
  final ScrollController? controller;

  const GameList({
    super.key,
    required this.games,
    required this.onTap,
    this.coverBaseUrl = "",
    this.selectedIds = const {},
    this.onSelect,
    this.multiSelect = false,
    this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final columns = w > 1600 ? 3 : w > 1000 ? 2 : 1;
        final colWidth = (w - AppGap.lg) / columns;

        return SingleChildScrollView(
          controller: widget.controller,
          padding: const EdgeInsets.symmetric(horizontal: AppGap.sm),
          child: Wrap(
            spacing: AppGap.sm,
            runSpacing: AppGap.xs,
            children: games.map((game) => Stack(children: [
              SizedBox(
                width: colWidth - (columns > 1 ? AppGap.sm : 0),
                child: _GameListTile(game: game, onTap: () => onTap(game), coverBaseUrl: coverBaseUrl),
              ),
              if (multiSelect)
                Positioned(
                  top: 10, left: 6,
                  child: _selectCircle(selectedIds.contains(game.id), context),
                ),
            ])).toList(),
          ),
        );
      },
    );
  }

  Widget _selectCircle(bool selected, BuildContext context) {
    return Container(
      width: 24, height: 24,
      decoration: BoxDecoration(
        color: selected ? Theme.of(context).colorScheme.primary : Colors.black54,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white70, width: 2),
      ),
      child: selected ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
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
    final cs = Theme.of(context).colorScheme;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          margin: EdgeInsets.symmetric(vertical: _hovered ? 3 : 1),
          padding: const EdgeInsets.symmetric(horizontal: AppGap.md, vertical: 10),
          decoration: BoxDecoration(
            color: _hovered ? cs.surfaceContainerHighest.withValues(alpha: 0.6) : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _hovered ? cs.outline.withValues(alpha: 0.3) : Colors.transparent,
            ),
            boxShadow: _hovered ? [
              BoxShadow(color: cs.primary.withValues(alpha: 0.08), blurRadius: 12, offset: const Offset(0, 2)),
            ] : null,
          ),
          child: Row(children: [
            // Cover thumbnail — proper aspect ratio
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 64, height: 90,
                child: hasCover
                    ? Image.network(
                        "${widget.coverBaseUrl}/api/files/covers${game.coverPath!}",
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _placeholder(cs),
                      )
                    : _placeholder(cs),
              ),
            ),
            const SizedBox(width: AppGap.md),
            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(game.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: AppText.body.copyWith( fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text(game.developer ?? game.companyName ?? "",
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: AppText.bodySmall.copyWith(color: hintColor(context))),
                  if (game.tagNames.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 4, runSpacing: 2,
                      children: game.tagNames.take(3).map((t) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: cs.primaryContainer.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(t, style: AppText.caption.copyWith(
                          color: cs.onPrimaryContainer.withValues(alpha: 0.8),
                        )),
                      )).toList(),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: AppGap.sm),
            Icon(Icons.chevron_right_rounded, color: cs.onSurface.withValues(alpha: 0.3), size: 22),
          ]),
        ),
      ),
    );
  }

  Widget _placeholder(ColorScheme cs) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [cs.surfaceContainerHighest, cs.surfaceContainerLow],
        ),
      ),
      child: Center(
        child: Icon(Icons.videogame_asset_rounded, color: cs.onSurface.withValues(alpha: 0.3), size: 28),
      ),
    );
  }
}
