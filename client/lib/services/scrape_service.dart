/// Client-side direct scraper — calls external APIs without going through the server.
/// Used for single-game editing. Batch scraping still uses the server-side scraper.

import "dart:convert";
import "dart:math" as math;

import "logged_http.dart" as http;

class ScrapeService {
  static const int _maxScrapedTags = 20;

  static const _vndbFields =
      "id,title,titles.lang,titles.title,titles.latin,titles.official,titles.main,"
      "image.url,image.sexual,screenshots.url,description,rating,released,"
      "length,length_minutes,"
      "developers.name,tags.name,tags.rating,tags.spoiler";

  /// Search all sources by source key.
  static Future<List<Map<String, dynamic>>> search(
    String source,
    String query, {
    String? proxy,
  }) async {
    switch (source) {
      case "vndb_kana":
        return _searchVndb(query, proxy);
      case "bangumi":
        return _searchBangumi(query, proxy);
      case "steam":
        return _searchSteam(query, proxy);
      default:
        return [];
    }
  }

  // ── VNDB Kana ──

  static String? _normalizeVndbId(String query) {
    final q = query.trim().toLowerCase();
    if (RegExp(r'^v?\d+$').hasMatch(q)) {
      return q.startsWith("v") ? q : "v$q";
    }
    return null;
  }

  static Future<List<Map<String, dynamic>>> _searchVndb(
    String query,
    String? proxy,
  ) async {
    final uri = Uri.parse("https://api.vndb.org/kana/vn");
    final vndbId = _normalizeVndbId(query);
    try {
      final resp = await http.post(
        uri,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "filters":
              vndbId != null ? ["id", "=", vndbId] : ["search", "=", query],
          "fields": _vndbFields,
          if (vndbId == null) "sort": "searchrank",
          "results": vndbId != null ? 1 : 5,
        }),
      );
      if (resp.statusCode != 200) return [];
      final items = jsonDecode(resp.body)["results"] as List? ?? [];
      final results = <Map<String, dynamic>>[];
      for (final item in items) {
        final titles = item["titles"] as List? ?? [];
        String title = item["title"] ?? "";
        for (final t in titles) {
          if (t["lang"] == "zh-Hans" || t["lang"] == "zh-Hant") {
            title = t["title"] ?? title;
            break;
          }
        }
        final devs = item["developers"] as List? ?? [];
        final cover = await _pickVndbCover(item);
        final vndbTags = ((item["tags"] as List?) ?? [])
            .whereType<Map>()
            .where((tag) => _tagRating(tag["rating"]) >= 1.5)
            .toList();
        vndbTags.sort(
          (a, b) => _tagRating(b["rating"]).compareTo(_tagRating(a["rating"])),
        );
        final tags = vndbTags
            .map((tag) => {
                  "name": tag["name"]?.toString() ?? "",
                  "rating": tag["rating"] ?? 0,
                  "is_spoiler": tag["spoiler"] == true,
                })
            .where((tag) => (tag["name"] ?? "").toString().trim().isNotEmpty)
            .take(_maxScrapedTags)
            .toList();
        results.add({
          "title": title,
          "developer": devs.isNotEmpty ? (devs.first["name"] ?? "") : "",
          "release_date": item["released"] ?? "",
          "description": item["description"] ?? "",
          "cover_url": cover,
          "screenshots": ((item["screenshots"] as List?) ?? [])
              .map((s) => s["url"] ?? "")
              .toList(),
          "length": item["length"] ?? 0,
          "length_minutes": item["length_minutes"] ?? 0,
          "source_id": item["id"] ?? "",
          "is_nsfw": _isVndbImageNsfw(item["image"]),
          "tags": tags,
        });
      }
      return _rankMetadataResults(query, results);
    } catch (_) {
      return [];
    }
  }

  static bool _isVndbImageNsfw(dynamic image) {
    if (image is! Map) return false;
    final sexual = image["sexual"];
    if (sexual is num) return sexual >= 2.0;
    final parsed = double.tryParse(sexual?.toString() ?? "");
    return parsed != null && parsed >= 2.0;
  }

  static double _tagRating(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? "") ?? 0.0;
  }

  static Future<String> _pickVndbCover(dynamic item) async {
    final fallback = ((item["image"] ?? {})["url"] ?? "").toString();
    final id = (item["id"] ?? "").toString();
    if (id.isEmpty) return fallback;
    final cover = await _findChineseVndbReleaseCover(id);
    return cover.isNotEmpty ? cover : fallback;
  }

  static Future<String> _findChineseVndbReleaseCover(String vndbId) async {
    try {
      final resp = await http.post(
        Uri.parse("https://api.vndb.org/kana/release"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "filters": [
            "vn",
            "=",
            ["id", "=", vndbId],
          ],
          "fields": "id,title,languages.lang,images.url,official,released",
          "sort": "released",
          "reverse": true,
          "results": 100,
        }),
      );
      if (resp.statusCode != 200) return "";
      final releases = jsonDecode(resp.body)["results"] as List? ?? [];
      var bestUrl = "";
      var bestScore = -1;
      for (final release in releases) {
        final images = release["images"] as List? ?? [];
        if (images.isEmpty) continue;
        final langs = ((release["languages"] as List?) ?? [])
            .map((lang) => lang["lang"]?.toString() ?? "")
            .toSet();
        var score = -1;
        if (langs.contains("zh-Hans")) {
          score = 40;
        } else if (langs.contains("zh-Hant")) {
          score = 35;
        } else if (langs.contains("zh")) {
          score = 30;
        }
        if (score < 0) continue;
        if (release["official"] == true) score += 5;
        final url = (images.first["url"] ?? "").toString();
        if (url.isNotEmpty && score > bestScore) {
          bestUrl = url;
          bestScore = score;
        }
      }
      return bestUrl;
    } catch (_) {
      return "";
    }
  }

  // ── Bangumi ──

  static Future<List<Map<String, dynamic>>> _searchBangumi(
    String query,
    String? proxy,
  ) async {
    final id = query.trim();
    if (RegExp(r'^\d+$').hasMatch(id)) {
      return _bangumiSubject(id);
    }

    final uri = Uri.parse(
      "https://api.bgm.tv/v0/search/subjects/${Uri.encodeComponent(query)}"
      "?type=1&limit=5",
    );
    try {
      final resp = await http.get(uri);
      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body);
      final list = data["list"] as List? ?? [];
      final results = list.map<Map<String, dynamic>>((item) {
        return _parseBangumiSubject(item as Map<String, dynamic>);
      }).toList();
      return _rankMetadataResults(query, results);
    } catch (_) {
      return [];
    }
  }

  static Map<String, dynamic> _parseBangumiSubject(Map<String, dynamic> item) {
    final cover = (item["images"] ?? {})["large"] ??
        (item["images"] ?? {})["common"] ??
        "";
    final tags = ((item["tags"] as List?) ?? [])
        .whereType<Map>()
        .map((tag) => {"name": tag["name"]?.toString() ?? ""})
        .where((tag) => (tag["name"] ?? "").toString().trim().isNotEmpty)
        .take(_maxScrapedTags)
        .toList();
    return {
      "title": item["name_cn"] ?? item["name"] ?? "",
      "developer": "",
      "release_date": item["date"] ?? "",
      "description": item["summary"] ?? "",
      "cover_url": cover,
      "screenshots": <String>[],
      "source_id": item["id"]?.toString() ?? "",
      "is_nsfw": item["nsfw"] == true,
      "tags": tags,
    };
  }

  static Future<List<Map<String, dynamic>>> _bangumiSubject(String id) async {
    final uri = Uri.parse("https://api.bgm.tv/v0/subjects/$id");
    try {
      final resp = await http.get(uri);
      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body);
      if (data is! Map<String, dynamic>) return [];
      return [_parseBangumiSubject(data)];
    } catch (_) {
      return [];
    }
  }

  // ── Steam ──

  /// Multi-store search: Chinese store + English store + Community fallback.
  static Future<List<Map<String, dynamic>>> _searchSteam(
    String query,
    String? proxy,
  ) async {
    // Numeric → direct App ID lookup
    if (RegExp(r'^\d+$').hasMatch(query.trim())) {
      return _steamDetails(query.trim(), query.trim());
    }
    // Collect candidates from all stores
    final allItems = <Map<String, dynamic>>[];
    for (final (lang, cc) in [("schinese", "CN"), ("english", "US")]) {
      try {
        final uri = Uri.parse(
          "https://store.steampowered.com/api/storesearch/"
          "?term=${Uri.encodeComponent(query)}&l=$lang&cc=$cc&category1=998",
        );
        final resp = await http.get(uri);
        if (resp.statusCode == 200) {
          final items = (jsonDecode(resp.body)["items"] as List?)
              ?.cast<Map<String, dynamic>>();
          if (items != null) allItems.addAll(items);
        }
      } catch (_) {}
    }
    // Community search as fallback
    if (allItems.isEmpty) {
      try {
        final resp = await http.get(
          Uri.parse(
            "https://steamcommunity.com/actions/SearchApps/?term=${Uri.encodeComponent(query)}",
          ),
        );
        if (resp.statusCode == 200) {
          final apps = jsonDecode(resp.body);
          if (apps is List) {
            for (final a in apps) {
              if (a is Map) allItems.add({"id": a["appid"], "name": a["name"]});
            }
          }
        }
      } catch (_) {}
    }
    if (allItems.isEmpty) return [];

    // Pick best match by name similarity
    final best = _pickBestSteam(allItems, query);
    if (best == null) return [];

    final appid = (best["appid"] ?? best["id"])?.toString();
    if (appid == null || appid.isEmpty) return [];

    return _steamDetails(appid, query);
  }

  /// Name similarity matching with sequel-number mismatch protection.
  static Map<String, dynamic>? _pickBestSteam(
    List<Map<String, dynamic>> items,
    String title,
  ) {
    final ranked = items.asMap().entries.toList()
      ..sort((a, b) {
        final aScore = _metadataTitleMatchScore(
          title,
          (a.value["name"] ?? "").toString(),
        );
        final bScore = _metadataTitleMatchScore(
          title,
          (b.value["name"] ?? "").toString(),
        );
        final scoreCompare = bScore.compareTo(aScore);
        return scoreCompare != 0 ? scoreCompare : a.key.compareTo(b.key);
      });
    if (ranked.isEmpty) return null;
    final best = ranked.first.value;
    final score = _metadataTitleMatchScore(title, (best["name"] ?? "").toString());
    return score >= 70 ? best : null;
  }

  /// Fetch full details for an App ID, with Chinese-first cover and hero banner.
  static Future<List<Map<String, dynamic>>> _steamDetails(
    String appid,
    String searchTitle,
  ) async {
    Map<String, dynamic> details = {};
    for (final lang in ["schinese", "english"]) {
      try {
        final resp = await http.get(
          Uri.parse(
            "https://store.steampowered.com/api/appdetails?appids=$appid&l=$lang",
          ),
        );
        if (resp.statusCode == 200) {
          final d = (jsonDecode(resp.body)[appid] ?? {})["data"];
          if (d is Map && (d["name"] ?? "").toString().isNotEmpty) {
            details = d.cast<String, dynamic>();
            break;
          }
        }
      } catch (_) {}
    }
    if (details.isEmpty) return [];

    final title = details["name"]?.toString() ?? searchTitle;
    final devs = (details["developers"] as List?)?.cast<String>() ?? [];
    final developer = devs.isNotEmpty ? devs.first : "";
    final desc = (details["short_description"]?.toString() ?? "").length > 500
        ? details["short_description"].toString().substring(0, 500)
        : (details["short_description"]?.toString() ?? "");
    final release = ((details["release_date"] ?? {})["date"] ?? "").toString();
    final tags = _steamTagMaps(details);
    final screenshots = ((details["screenshots"] as List?) ?? [])
        .map<dynamic>((s) => s["path_full"] ?? "")
        .where((u) => u is String && u.isNotEmpty)
        .cast<String>()
        .toList();

    // Cover URL: Chinese → English → default
    String cover =
        "https://cdn.akamai.steamstatic.com/steam/apps/$appid/library_600x900.jpg";
    for (final suffix in ["_schinese", "_english", ""]) {
      try {
        final url =
            "https://cdn.akamai.steamstatic.com/steam/apps/$appid/library_600x900$suffix.jpg";
        final r = await http.head(Uri.parse(url));
        if (r.statusCode == 200) {
          cover = url;
          break;
        }
      } catch (_) {}
    }

    // Hero banner: library_hero → header
    String hero =
        "https://cdn.akamai.steamstatic.com/steam/apps/$appid/library_hero.jpg";
    try {
      final r = await http.head(Uri.parse(hero));
      if (r.statusCode != 200) {
        hero =
            "https://cdn.akamai.steamstatic.com/steam/apps/$appid/header.jpg";
      }
    } catch (_) {
      hero = "https://cdn.akamai.steamstatic.com/steam/apps/$appid/header.jpg";
    }

    return [
      {
        "title": title,
        "developer": developer,
        "release_date": release,
        "description": desc,
        "cover_url": cover,
        "hero_url": hero,
        "screenshots": screenshots,
        "source_id": appid,
        "tags": tags,
      },
    ];
  }

  static List<Map<String, dynamic>> _steamTagMaps(
    Map<String, dynamic> details,
  ) {
    final tags = <Map<String, dynamic>>[];
    final seen = <String>{};

    void addName(dynamic value) {
      final name = value?.toString().trim() ?? "";
      final key = name.toLowerCase();
      if (name.isEmpty || seen.contains(key)) return;
      seen.add(key);
      tags.add({"name": name});
    }

    for (final genre in (details["genres"] as List?) ?? const []) {
      if (genre is Map) addName(genre["description"]);
    }
    for (final category in (details["categories"] as List?) ?? const []) {
      if (category is Map) addName(category["description"]);
    }

    return tags.take(_maxScrapedTags).toList();
  }

  static List<Map<String, dynamic>> _rankMetadataResults(
    String query,
    List<Map<String, dynamic>> results,
  ) {
    final indexed = results.asMap().entries.toList()
      ..sort((a, b) {
        final aScore = _metadataTitleMatchScore(
          query,
          (a.value["title"] ?? a.value["name"] ?? "").toString(),
        );
        final bScore = _metadataTitleMatchScore(
          query,
          (b.value["title"] ?? b.value["name"] ?? "").toString(),
        );
        final scoreCompare = bScore.compareTo(aScore);
        return scoreCompare != 0 ? scoreCompare : a.key.compareTo(b.key);
      });
    return indexed.map((entry) => entry.value).toList();
  }

  static int _metadataTitleMatchScore(String query, String title) {
    final queryKey = _normalizeSearchKeyNumbers(
      _metadataSearchKey(_cleanSearchTitle(query)),
    );
    final titleKey = _normalizeSearchKeyNumbers(_metadataSearchKey(title));
    if (queryKey.isEmpty || titleKey.isEmpty) return 0;

    final queryNumbers = _metadataNumberGroups(queryKey);
    final titleNumbers = _metadataNumberGroups(titleKey);
    if (queryNumbers.isNotEmpty &&
        titleNumbers.isNotEmpty &&
        !_sameStringList(queryNumbers, titleNumbers)) {
      return 0;
    }

    var score = 0;
    if (queryKey == titleKey) {
      score = 100;
    } else if (titleKey.startsWith(queryKey) || queryKey.startsWith(titleKey)) {
      score = 92;
    } else if (titleKey.contains(queryKey) || queryKey.contains(titleKey)) {
      score = 88;
    } else {
      final titleRunes = titleKey.runes.toSet();
      var overlap = 0;
      for (final rune in queryKey.runes) {
        if (titleRunes.contains(rune)) overlap += 1;
      }
      score = (overlap / math.max(1, queryKey.runes.length) * 86).round();
    }

    if (queryNumbers.isNotEmpty && titleNumbers.isEmpty) {
      score = math.min(score, 62);
    } else if (titleNumbers.isNotEmpty && queryNumbers.isEmpty) {
      score = math.min(score, 66);
    }
    return math.max(0, math.min(100, score));
  }

  static String _cleanSearchTitle(String title) {
    var result = title.trim();
    if (RegExp(r'^\d+$').hasMatch(result)) return result;
    result = result
        .replaceFirst(RegExp(r'^[\[\(（][A-Za-z]+[\]\)）]'), "")
        .trim();
    result = result
        .replaceFirst(RegExp(r'^直装[_ ]', caseSensitive: false), "")
        .trim();
    result = result
        .replaceFirst(
          RegExp(
            r'[-_ ]?(?:v|ver|version)\s*\d+(?:\.\d+)*$',
            caseSensitive: false,
          ),
          "",
        )
        .trim();
    result = result.replaceFirst(RegExp(r'[-_ ]?\d+\.\d+(?:\.\d+)*$'), "").trim();
    result = result
        .replaceFirst(
          RegExp(
            r'[-_ ]?(汉化|中文|官方中文|完全版|DL版|体験版|体験版Ver[\d.]+).*$',
            caseSensitive: false,
          ),
          "",
        )
        .trim();
    result = result
        .replaceFirst(
          RegExp(
            r'[-_ ]?[（(](?:pc|krkr|ons|ty|android|直装|汉化|中文|官方中文|dl版|'
            r'r18|r-18|成人|全年龄|全年齡|ver[\d.]+|v[\d.]+)[)）]$',
            caseSensitive: false,
          ),
          "",
        )
        .trim();
    return result;
  }

  static String _metadataSearchKey(String text) {
    final buffer = StringBuffer();
    for (final rune in text.toLowerCase().runes) {
      final isDigit = rune >= 0x30 && rune <= 0x39;
      final isFullWidthDigit = rune >= 0xff10 && rune <= 0xff19;
      final isAsciiLetter = rune >= 0x61 && rune <= 0x7a;
      final isHiragana = rune >= 0x3040 && rune <= 0x309f;
      final isKatakana = rune >= 0x30a0 && rune <= 0x30ff;
      final isCjk = rune >= 0x3400 && rune <= 0x9fff;
      if (isDigit || isAsciiLetter || isHiragana || isKatakana || isCjk) {
        buffer.writeCharCode(rune);
      } else if (isFullWidthDigit) {
        buffer.writeCharCode(0x30 + rune - 0xff10);
      }
    }
    return buffer.toString();
  }

  static List<String> _metadataNumberGroups(String normalized) {
    return RegExp(r'\d+')
        .allMatches(normalized)
        .map((match) => _normalizeNumberGroup(match.group(0) ?? ""))
        .where((value) => value.isNotEmpty)
        .toList();
  }

  static String _normalizeSearchKeyNumbers(String value) {
    return value.replaceAllMapped(
      RegExp(r'\d+'),
      (match) => _normalizeNumberGroup(match.group(0) ?? ""),
    );
  }

  static String _normalizeNumberGroup(String value) {
    final normalized = value.replaceFirst(RegExp(r'^0+'), "");
    return normalized.isEmpty ? "0" : normalized;
  }

  static bool _sameStringList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i += 1) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
