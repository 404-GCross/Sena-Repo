/// Grid view for game library.

import "package:flutter/material.dart";

import "../models/game.dart";

class GameGrid extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        childAspectRatio: 0.7,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: games.length,
      itemBuilder: (context, index) {
        final game = games[index];
        return _GameCard(game: game, onTap: () => onTap(game), coverBaseUrl: coverBaseUrl);
      },
    );
  }
}

class _GameCard extends StatelessWidget {
  final GameSummary game;
  final VoidCallback onTap;
  final String coverBaseUrl;

  const _GameCard({required this.game, required this.onTap, this.coverBaseUrl = ""});

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 3,
              child: Container(
                color: Colors.grey[850],
                child: game.coverPath != null && coverBaseUrl.isNotEmpty
                    ? Image.network("$coverBaseUrl/api/files/covers${game.coverPath!}", fit: BoxFit.cover, errorBuilder: (_, __, ___) => _placeholder())
                    : _placeholder(),
              ),
            ),
            Expanded(
              flex: 1,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      game.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      game.platformSummary,
                      style: TextStyle(color: Colors.grey[400], fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder() {
    return const Center(child: Icon(Icons.videogame_asset, size: 48, color: Colors.grey));
  }
}
