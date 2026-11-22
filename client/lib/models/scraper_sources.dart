class ScraperSources {
  static const labels = {
    'vndb_kana': 'VNDB',
    'bangumi': 'Bangumi',
    'steam': 'Steam',
    'hikarinagi': 'Hikarinagi',
    'nextmoe': 'NextMoe',
  };

  final Set<String> enabled;

  ScraperSources.fromConfig(Map<String, dynamic>? config)
    : enabled = _parse(config?['enabled_scrapers']);

  static Set<String> _parse(Object? raw) {
    if (raw is! List || !raw.every((source) => labels.containsKey(source))) {
      throw const FormatException('Invalid enabled_scrapers');
    }
    return Set.unmodifiable(
      raw.contains('nextmoe') ? ['nextmoe'] : raw.cast<String>(),
    );
  }

  bool allows(String source) =>
      labels.containsKey(source) &&
      (enabled.contains('nextmoe') == (source == 'nextmoe'));

  Map<String, String> get choices => {
    for (final e in labels.entries)
      if (allows(e.key)) e.key: e.value,
  };
}
