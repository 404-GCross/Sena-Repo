/// List view for game library.

import "package:flutter/material.dart";

import "../models/game.dart";

class GameList extends StatelessWidget {
  final List<GameSummary> games;
  final void Function(GameSummary game) onTap;

  const GameList({super.key, required this.games, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: games.length,
      itemBuilder: (context, index) {
        final game = games[index];
        return Card(
          child: ListTile(
            leading: SizedBox(
              width: 80,
              height: 110,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: game.coverPath != null
                    ? Image.network(game.coverPath!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _placeholder())
                    : _placeholder(),
              ),
            ),
            title: Text(game.name, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Text(game.platformSummary),
                if (game.companyName != null) Text(game.companyName!, style: TextStyle(color: Colors.grey[500])),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 4,
                  children: game.tagNames.map((t) => Chip(label: Text(t, style: const TextStyle(fontSize: 10)))).toList(),
                ),
              ],
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => onTap(game),
          ),
        );
      },
    );
  }

  Widget _placeholder() {
    return Container(color: Colors.grey[850], child: const Center(child: Icon(Icons.videogame_asset, color: Colors.grey)));
  }
}
