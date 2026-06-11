/// Grid view for game library — LunaBox-inspired card design.

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
    final isPC = MediaQuery.of(context).size.shortestSide > 600;
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: _coverSize,
        childAspectRatio: 0.72,
        crossAxisSpacing: isPC ? 10 : 8,
        mainAxisSpacing: isPC ? 12 : 8,
      ),
      itemCount: widget.games.length,
      itemBuilder: (context, index) {
        final game = widget.games[index];
        return Stack(children: [
          _GameCard(game: game, onTap: () => widget.onTap(game), coverBaseUrl: widget.coverBaseUrl),
          if (widget.multiSelect)
            Positioned(
              top: 6, left: 6,
              child: Container(
                width: 24, height: 24,
                decoration: BoxDecoration(
                  color: widget.selectedIds.contains(game.id)
                      ? Theme.of(context).colorScheme.primary
                      : Colors.black.withValues(alpha: 0.5),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white.withValues(alpha: 0.8), width: 2),
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
                ? cardBorder(context)
                : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _hovered
                  ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)
                  : cardBorder(context),
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
                        scale: _hovered ? 1.05 : 1.0,
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
                                color: cardBorder(context),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.info_outline, color: Colors.white, size: 22),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                // Meta — dark gradient overlay for readability
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(game.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: AppText.bodySmall.copyWith(
                              fontWeight: FontWeight.w700,
                              color: Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black87)),
                      Text(game.developer ?? game.companyName ?? "",
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: AppText.caption.copyWith(
                              color: Theme.of(context).brightness == Brightness.dark ? Colors.grey[300] : Colors.grey[600])),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: isDark
              ? [Colors.grey[800]!, placeholderBg(context)]
              : [Colors.grey[300]!, Colors.grey[350]!],
        ),
      ),
      child: Center(
        child: Icon(Icons.image_not_supported_outlined, size: 36,
            color: isDark ? Colors.grey[600] : Colors.grey[400]),
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
          Expanded(flex: 1, child: Padding(padding: const EdgeInsets.all(AppGap.sm),
            child: Column(crossAxisAlignment: CrossAxisAlignment.center, mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(game.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: AppText.bodySmall.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: AppGap.xs),
              Text(game.developer ?? game.companyName ?? "",
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(color: subTextColor(context))),
            ]))),
        ]),
      ),
    );
  }

  Widget _placeholder() => const Center(child: Icon(Icons.videogame_asset, size: 48, color: Colors.grey));
}
