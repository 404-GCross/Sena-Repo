/// Client-side direct scraper — calls external APIs without going through the server.
/// Used for single-game editing. Batch scraping still uses the server-side scraper.

import "package:http/http.dart" as http;
import "dart:convert";

class ScrapeService {
  static const _vndbFields =
      "id,title,titles.lang,titles.title,titles.latin,titles.official,titles.main,"
      "image.url,screenshots.url,description,rating,released,"
      "length,length_minutes,"
      "developers.name,tags.name,tags.rating,tags.spoiler";

  /// Search all sources by source key.
  static Future<List<Map<String, dynamic>>> search(String source, String query,
      {String? proxy}) async {
    switch (source) {
      case "vndb_kana":
        return _searchVndb(query, proxy);
      case "bangumi":
        return _searchBangumi(query, proxy);
      case "steam":
        return _searchSteam(query, proxy);
      case "ymgal":
        return _searchYmgal(query, proxy);
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
      String query, String? proxy) async {
    final uri = Uri.parse("https://api.vndb.org/kana/vn");
    final vndbId = _normalizeVndbId(query);
    try {
      final resp = await http.post(uri,
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({
            "filters": vndbId != null
                ? ["id", "=", vndbId]
                : ["search", "=", query],
            "fields": _vndbFields,
            if (vndbId == null) "sort": "searchrank",
            "results": vndbId != null ? 1 : 5,
          }));
      if (resp.statusCode != 200) return [];
      final items = jsonDecode(resp.body)["results"] as List? ?? [];
      return items.map<Map<String, dynamic>>((item) {
        final titles = item["titles"] as List? ?? [];
        String title = item["title"] ?? "";
        for (final t in titles) {
          if (t["lang"] == "zh-Hans" || t["lang"] == "zh-Hant") {
            title = t["title"] ?? title;
            break;
          }
        }
        final devs = item["developers"] as List? ?? [];
        return {
          "title": title,
          "developer": devs.isNotEmpty ? (devs.first["name"] ?? "") : "",
          "release_date": item["released"] ?? "",
          "description": item["description"] ?? "",
          "cover_url": (item["image"] ?? {})["url"] ?? "",
          "screenshots": ((item["screenshots"] as List?) ?? [])
              .map((s) => s["url"] ?? "").toList(),
          "length": item["length"] ?? 0,
          "length_minutes": item["length_minutes"] ?? 0,
          "source_id": item["id"] ?? "",
        };
      }).toList();
    } catch (_) {
      return [];
    }
  }

  // ── Bangumi ──

  static Future<List<Map<String, dynamic>>> _searchBangumi(
      String query, String? proxy) async {
    final uri = Uri.parse(
        "https://api.bgm.tv/v0/search/subjects/${Uri.encodeComponent(query)}"
        "?type=1&limit=5");
    try {
      final resp = await http.get(uri);
      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body);
      final list = data["list"] as List? ?? [];
      return list.map<Map<String, dynamic>>((item) {
        return {
          "title": item["name_cn"] ?? item["name"] ?? "",
          "developer": "",
          "release_date": item["date"] ?? "",
          "description": item["summary"] ?? "",
          "cover_url": (item["images"] ?? {})["large"] ?? "",
          "screenshots": <String>[],
          "source_id": item["id"]?.toString() ?? "",
        };
      }).toList();
    } catch (_) {
      return [];
    }
  }

  // ── Steam ──

  /// Multi-store search: Chinese store + English store + Community fallback.
  static Future<List<Map<String, dynamic>>> _searchSteam(
      String query, String? proxy) async {
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
            "?term=${Uri.encodeComponent(query)}&l=$lang&cc=$cc&category1=998");
        final resp = await http.get(uri);
        if (resp.statusCode == 200) {
          final items = (jsonDecode(resp.body)["items"] as List?)?.cast<Map<String, dynamic>>();
          if (items != null) allItems.addAll(items);
        }
      } catch (_) {}
    }
    // Community search as fallback
    if (allItems.isEmpty) {
      try {
        final resp = await http.get(Uri.parse(
            "https://steamcommunity.com/actions/SearchApps/?term=${Uri.encodeComponent(query)}"));
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

  /// Name similarity matching — exact > contains > prefix > reverse contains.
  static Map<String, dynamic>? _pickBestSteam(
      List<Map<String, dynamic>> items, String title) {
    final norm = title.toLowerCase();
    // Exact match
    for (final a in items) {
      if ((a["name"] ?? "").toString().toLowerCase() == norm) return a;
    }
    // Contains match
    for (final a in items) {
      if ((a["name"] ?? "").toString().toLowerCase().contains(norm)) return a;
    }
    // Prefix match
    for (final a in items) {
      if ((a["name"] ?? "").toString().toLowerCase().startsWith(norm)) return a;
    }
    // Reverse contains
    for (final a in items) {
      final n = (a["name"] ?? "").toString().toLowerCase();
      if (n.isNotEmpty && norm.contains(n)) return a;
    }
    return null;
  }

  /// Fetch full details for an App ID, with Chinese-first cover and hero banner.
  static Future<List<Map<String, dynamic>>> _steamDetails(
      String appid, String searchTitle) async {
    Map<String, dynamic> details = {};
    for (final lang in ["schinese", "english"]) {
      try {
        final resp = await http.get(Uri.parse(
            "https://store.steampowered.com/api/appdetails?appids=$appid&l=$lang"));
        if (resp.statusCode == 200) {
          final d = (jsonDecode(resp.body)[appid] ?? {})["data"];
          if (d is Map && (d["name"] ?? "").toString().isNotEmpty) {
            details = d.cast<String, dynamic>(); break;
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
    final screenshots = ((details["screenshots"] as List?) ?? [])
        .map<dynamic>((s) => s["path_full"] ?? "").where((u) => u is String && u.isNotEmpty).cast<String>().toList();

    // Cover URL: Chinese → English → default
    String cover = "https://cdn.akamai.steamstatic.com/steam/apps/$appid/library_600x900.jpg";
    for (final suffix in ["_schinese", "_english", ""]) {
      try {
        final url = "https://cdn.akamai.steamstatic.com/steam/apps/$appid/library_600x900$suffix.jpg";
        final r = await http.head(Uri.parse(url));
        if (r.statusCode == 200) { cover = url; break; }
      } catch (_) {}
    }

    // Hero banner: library_hero → header
    String hero = "https://cdn.akamai.steamstatic.com/steam/apps/$appid/library_hero.jpg";
    try {
      final r = await http.head(Uri.parse(hero));
      if (r.statusCode != 200) {
        hero = "https://cdn.akamai.steamstatic.com/steam/apps/$appid/header.jpg";
      }
    } catch (_) {
      hero = "https://cdn.akamai.steamstatic.com/steam/apps/$appid/header.jpg";
    }

    return [{
      "title": title,
      "developer": developer,
      "release_date": release,
      "description": desc,
      "cover_url": cover,
      "hero_url": hero,
      "screenshots": screenshots,
      "source_id": appid,
    }];
  }
  // ── Ymgal (月幕) ──

  static Future<List<Map<String, dynamic>>> _searchYmgal(
      String query, String? proxy) async {
    final uri = Uri.parse("https://api.ymgal.games/open/archive/search-game");
    try {
      final resp = await http.post(uri,
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({"keyword": query, "limit": 5}));
      if (resp.statusCode != 200) return [];
      final items = jsonDecode(resp.body)["data"] as List? ?? [];
      return items.map<Map<String, dynamic>>((item) {
        return {
          "title": item["title_cn"] ?? item["title"] ?? "",
          "developer": item["developer"] ?? "",
          "release_date": item["release_date"] ?? "",
          "description": item["description"] ?? "",
          "cover_url": item["cover"] ?? "",
          "screenshots": <String>[],
          "source_id": item["id"]?.toString() ?? "",
        };
      }).toList();
    } catch (_) {
      return [];
    }
  }
}
