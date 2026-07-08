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
      case "dlsite":
        return _searchDlsite(query, proxy);
      case "ymgal":
        return _searchYmgal(query, proxy);
      default:
        return [];
    }
  }

  // ── VNDB Kana ──

  static Future<List<Map<String, dynamic>>> _searchVndb(
      String query, String? proxy) async {
    final uri = Uri.parse("https://api.vndb.org/kana/vn");
    try {
      final resp = await http.post(uri,
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({
            "filters": ["search", "=", query],
            "fields": _vndbFields,
            "sort": "searchrank",
            "results": 5,
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

  static Future<List<Map<String, dynamic>>> _searchSteam(
      String query, String? proxy) async {
    final uri = Uri.parse(
        "https://store.steampowered.com/api/storesearch/"
        "?term=${Uri.encodeComponent(query)}&l=schinese&cc=CN");
    try {
      final resp = await http.get(uri);
      if (resp.statusCode != 200) return [];
      final items = jsonDecode(resp.body)["items"] as List? ?? [];
      final results = <Map<String, dynamic>>[];
      for (final item in items.take(5)) {
        final id = item["id"];
        // Get details for Chinese name
        String name = item["name"] ?? "";
        String desc = "";
        String release = "";
        String cover = "https://shared.cloudflare.steamstatic.com/store_item_assets/steam/apps/$id/header.jpg";
        String dev = "";
        List<String> shots = [];
        try {
          final d = Uri.parse(
              "https://store.steampowered.com/api/appdetails?appids=$id&l=schinese");
          final dr = await http.get(d);
          if (dr.statusCode == 200) {
            final dd = jsonDecode(dr.body);
            final detail = (dd[id.toString()] ?? {})["data"] ?? {};
            final cn = detail["name"] ?? "";
            if (cn.isNotEmpty) name = cn;
            desc = detail["short_description"] ?? "";
            release = (detail["release_date"] ?? {})["date"] ?? "";
            final devs = detail["developers"] as List? ?? [];
            if (devs.isNotEmpty) dev = devs.first ?? "";
            final bg = detail["background_raw"] ?? detail["background"] ?? "";
            if (bg.isNotEmpty) cover = bg;
            final screenshots = detail["screenshots"] as List? ?? [];
            shots = screenshots.map<dynamic>((s) => s["path_full"] ?? "").where((u) => u is String && u.isNotEmpty).cast<String>().toList();
          }
        } catch (_) {}
        results.add({
          "title": name,
          "developer": dev,
          "release_date": release,
          "description": desc,
          "cover_url": cover,
          "screenshots": shots,
          "source_id": id.toString(),
        });
      }
      return results;
    } catch (_) {
      return [];
    }
  }

  // ── DLsite ──

  static Future<List<Map<String, dynamic>>> _searchDlsite(
      String query, String? proxy) async {
    final uri = Uri.parse(
        "https://www.dlsite.com/maniax/fsr/=/keyword/${Uri.encodeComponent(query)}"
        "/order/release_d/from/fs.header/options/AND/");
    try {
      final resp = await http.get(uri,
          headers: {"User-Agent": "Sena-Repo/1.0", "Accept": "text/html"});
      if (resp.statusCode != 200) return [];
      final html = resp.body;
      // Extract work data from embedded JSON
      final re = RegExp(r'data-per-page="1" data-work="(\{[^}]+\})');
      final matches = re.allMatches(html);
      final results = <Map<String, dynamic>>[];
      for (final m in matches.take(5)) {
        try {
          final j = jsonDecode(m.group(1)!);
          results.add({
            "title": j["work_name"] ?? "",
            "developer": j["maker_name"] ?? "",
            "release_date": "",
            "description": "",
            "cover_url": "https:${j["image"] ?? ""}",
            "screenshots": <String>[],
            "source_id": j["id"] ?? "",
          });
        } catch (_) {}
      }
      return results;
    } catch (_) {
      return [];
    }
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
