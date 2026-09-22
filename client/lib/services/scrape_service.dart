/// Client-side direct scraper — calls external APIs without going through the server.
/// Used for single-game editing. Batch scraping still uses the server-side scraper.

import "dart:convert";
import "dart:math" as math;

import "api_client.dart";
import "logged_http.dart" as http;
import "nextmoe_token_store.dart";

/// Raised when a NextMoe-backed scrape needs the user to log in again.
class NextmoeAuthRequiredException implements Exception {
  final String message;
  NextmoeAuthRequiredException(this.message);
  @override
  String toString() => message;
}

class ScrapeService {
  static const int _maxScrapedTags = 20;
  static const String _steamAssetBaseUrl =
      "https://shared.akamai.steamstatic.com/store_item_assets/";
  static const String _steamStoreItemsUrl =
      "https://api.steampowered.com/IStoreBrowseService/GetItems/v1/";

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
    ApiClient? api,
  }) async {
    switch (source) {
      case "vndb_kana":
        return _searchVndb(query, proxy);
      case "bangumi":
        return _searchBangumi(query, proxy);
      case "steam":
        return _searchSteam(query, proxy);
      case "nextmoe":
        final client = api;
        if (client == null) {
          throw NextmoeAuthRequiredException("请先使用 NextMoe 登录");
        }
        return _searchNextmoe(query, client);
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

    final cover = await _resolveSteamCoverUrl(appid);

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

  static Future<String> _resolveSteamCoverUrl(String appid) async {
    final assets = await _steamStoreAssets(appid);
    for (final key in ["library_capsule_2x", "library_capsule"]) {
      final url = _steamAssetUrl(assets, key);
      if (url.isNotEmpty) return url;
    }

    for (final suffix in ["_schinese", "_english", ""]) {
      try {
        final url =
            "https://cdn.akamai.steamstatic.com/steam/apps/$appid/library_600x900$suffix.jpg";
        final r = await http.head(Uri.parse(url));
        if (r.statusCode == 200) return url;
      } catch (_) {}
    }
    return "";
  }

  static Future<Map<String, String>> _steamStoreAssets(String appid) async {
    final appidValue = int.tryParse(appid);
    if (appidValue == null) return {};

    for (final (lang, cc) in [("schinese", "CN"), ("english", "US")]) {
      try {
        final uri = Uri.parse(_steamStoreItemsUrl).replace(
          queryParameters: {
            "input_json": jsonEncode({
              "ids": [
                {"appid": appidValue},
              ],
              "context": {
                "language": lang,
                "country_code": cc,
                "steam_realm": 1,
              },
              "data_request": {
                "include_assets": true,
                "include_basic_info": true,
              },
            }),
          },
        );
        final resp = await http.get(uri);
        if (resp.statusCode != 200) continue;
        final data = jsonDecode(resp.body);
        final items = ((data["response"] ?? {})["store_items"] as List?) ?? [];
        if (items.isEmpty || items.first is! Map) continue;
        final assets = (items.first as Map)["assets"];
        if (assets is! Map) continue;
        return assets.map(
          (key, value) => MapEntry(key.toString(), value?.toString() ?? ""),
        );
      } catch (_) {}
    }
    return {};
  }

  static String _steamAssetUrl(Map<String, String> assets, String key) {
    final filename = (assets[key] ?? "").trim();
    final template = (assets["asset_url_format"] ?? "").trim();
    if (filename.isEmpty || template.isEmpty) return "";
    final path = template.replaceAll(r"${FILENAME}", filename);
    if (path.startsWith("http://") || path.startsWith("https://")) {
      return path;
    }
    return "$_steamAssetBaseUrl${path.replaceFirst(RegExp(r'^/+'), '')}";
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

  // ── NextMoe (user OAuth token) ──

  static const String _nextmoeApiBase = "https://api.nextmoe.dev/v2";
  static const String _nextmoeUserAgent =
      "SenaRepo/0.1 (https://github.com/404-GCross/Sena-Repo)";
  static const int _nextmoeSearchLimit = 5;
  static const int _nextmoeEnrichLimit = 3;
  static const String _nextmoeListInclude =
      "titles,refs,companies,intros,covers,tags,ratings";
  static const String _nextmoeDetailInclude = "screenshots,playtimes";
  static const Set<String> _nextmoeExternalSources = {
    "vndb",
    "bangumi",
    "steam",
  };
  static const Set<String> _nextmoeChineseLangs = {
    "zh-hans",
    "zh-cn",
    "zh-sg",
    "zh",
  };
  static const Map<String, int> _nextmoeCompanyRoleRank = {
    "developer": 0,
    "brand": 0,
    "circle": 0,
    "publisher": 1,
  };

  static Future<List<Map<String, dynamic>>> _searchNextmoe(
    String query,
    ApiClient api,
  ) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return const [];
    final token = await NextmoeTokenStore.getValidAccessToken(api);
    if (token == null || token.isEmpty) {
      throw NextmoeAuthRequiredException("请先使用 NextMoe 登录");
    }
    final headers = {
      "Accept": "application/json",
      "Authorization": "Bearer $token",
      "User-Agent": _nextmoeUserAgent,
    };
    final uri = Uri.parse("$_nextmoeApiBase/catalog/works").replace(
      queryParameters: {
        "q": keyword,
        "limit": "$_nextmoeSearchLimit",
        "nsfw": "true",
        "include": _nextmoeListInclude,
      },
    );
    final resp = await http
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 20));
    await _throwIfNextmoeAuthError(resp.statusCode, api);
    if (resp.statusCode != 200) return const [];
    final payload = jsonDecode(resp.body);
    if (payload is! Map) return const [];
    final items = (payload["items"] as List?) ?? const [];

    final results = <Map<String, dynamic>>[];
    var enriched = 0;
    for (final entry in items) {
      if (entry is! Map) continue;
      var candidate = _parseNextmoeWork(Map<String, dynamic>.from(entry));
      if (candidate == null) continue;
      final id = (candidate["source_id"] ?? "").toString();
      if (id.isNotEmpty && enriched < _nextmoeEnrichLimit) {
        enriched++;
        final detail = await _nextmoeDetail(id, headers, api);
        if (detail != null) {
          candidate = {
            ...candidate,
            if ((detail["screenshots"] as List?)?.isNotEmpty == true)
              "screenshots": detail["screenshots"],
            if ((detail["hero_url"] ?? "").toString().isNotEmpty)
              "hero_url": detail["hero_url"],
            if ((detail["covers"] as List?)?.isNotEmpty == true)
              "covers": detail["covers"],
          };
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      results.add(candidate);
    }
    return _rankMetadataResults(keyword, results);
  }

  static Future<void> _throwIfNextmoeAuthError(
    int statusCode,
    ApiClient api,
  ) async {
    if (statusCode != 401 && statusCode != 403) return;
    await NextmoeTokenStore.clear(api);
    throw NextmoeAuthRequiredException(
      statusCode == 403
          ? "需要重新使用 NextMoe 登录以授权目录读取"
          : "NextMoe 授权已失效，请重新登录",
    );
  }

  static Future<Map<String, dynamic>?> _nextmoeDetail(
    String workId,
    Map<String, String> headers,
    ApiClient api,
  ) async {
    final uri = Uri.parse("$_nextmoeApiBase/catalog/works/$workId").replace(
      queryParameters: {
        "nsfw": "true",
        "include": "$_nextmoeListInclude,$_nextmoeDetailInclude",
      },
    );
    try {
      final resp = await http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 20));
      await _throwIfNextmoeAuthError(resp.statusCode, api);
      if (resp.statusCode != 200) return null;
      final payload = jsonDecode(resp.body);
      if (payload is! Map) return null;
      return _parseNextmoeWork(Map<String, dynamic>.from(payload));
    } on NextmoeAuthRequiredException {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? _parseNextmoeWork(Map<String, dynamic> item) {
    final id = (item["id"] ?? "").toString().trim();
    final title = _nextmoeTitle(item);
    if (id.isEmpty && title.isEmpty) return null;
    final primaryCover = _nextmoeImageUrl(item["cover"]);
    final covers = _nextmoeCoverCandidates(item["covers"], primaryCover);
    return {
      "title": title,
      "developer": _nextmoeCompanies(item["companies"]),
      "release_date": _nextmoeDate(item["release_date"]),
      "description": _nextmoeDescription(item["intros"]),
      "cover_url": primaryCover.isNotEmpty
          ? primaryCover
          : (covers.isNotEmpty ? covers.first : ""),
      "covers": covers,
      "hero_url": _nextmoeImageUrl(item["banner"]),
      "screenshots": _nextmoeImageUrls(item["screenshots"]),
      "external_ids": _nextmoeExternalIds(item["refs"]),
      "source_id": id,
      "is_nsfw": _nextmoeNsfw(item["content_rating"]),
      "tags": _nextmoeTags(item["tags"]),
    };
  }

  static String _nextmoeTitle(Map<String, dynamic> item) {
    final localized = item["localized"];
    if (localized is Map) {
      var machine = "";
      for (final entry in localized.entries) {
        final lang = entry.key.toString().trim().toLowerCase();
        if (!_nextmoeChineseLangs.contains(lang)) continue;
        final parsed = _nextmoeLocalizedEntry(entry.value);
        if (parsed.text.isEmpty) continue;
        if (parsed.isMachine) {
          if (machine.isEmpty) machine = parsed.text;
        } else {
          return parsed.text;
        }
      }
      if (machine.isNotEmpty) return machine;
    }
    final display = (item["display_name"] ?? "").toString().trim();
    if (display.isNotEmpty) return display;
    return (item["latin"] ?? "").toString().trim();
  }

  static ({String text, bool isMachine}) _nextmoeLocalizedEntry(dynamic value) {
    if (value is String) return (text: value.trim(), isMachine: false);
    if (value is Map) {
      final text = (value["value"] ?? value["text"] ?? "").toString().trim();
      return (text: text, isMachine: value["is_machine"] == true);
    }
    return (text: "", isMachine: false);
  }

  static String _nextmoeCompanies(dynamic companies) {
    if (companies is! List) return "";
    final ranked = <(int, int, String)>[];
    for (var index = 0; index < companies.length; index++) {
      final entry = companies[index];
      var name = "";
      var role = "";
      if (entry is String) {
        name = entry.trim();
      } else if (entry is Map) {
        name = (entry["display_name"] ?? entry["name"] ?? "").toString().trim();
        role =
            (entry["attribution_role"] ?? "").toString().trim().toLowerCase();
      }
      if (name.isEmpty) continue;
      ranked.add((_nextmoeCompanyRoleRank[role] ?? 2, index, name));
    }
    ranked.sort((a, b) {
      final byRole = a.$1.compareTo(b.$1);
      return byRole != 0 ? byRole : a.$2.compareTo(b.$2);
    });
    final names = <String>[];
    for (final row in ranked) {
      if (!names.contains(row.$3)) names.add(row.$3);
    }
    return names.take(3).join(", ");
  }

  static String _nextmoeDescription(dynamic intros) {
    var authoredZh = "";
    var machineZh = "";
    var authored = "";
    var machine = "";
    void consider(String lang, String text, bool isMachine) {
      if (text.isEmpty) return;
      if (lang.startsWith("zh")) {
        if (isMachine) {
          if (machineZh.isEmpty) machineZh = text;
        } else if (authoredZh.isEmpty) {
          authoredZh = text;
        }
      } else if (isMachine) {
        if (machine.isEmpty) machine = text;
      } else if (authored.isEmpty) {
        authored = text;
      }
    }

    if (intros is Map) {
      intros.forEach((key, entry) {
        if (entry is Map) {
          consider(
            _nextmoeIntroLang(entry, key.toString()),
            _nextmoeIntroText(entry),
            entry["is_machine"] == true,
          );
        } else {
          consider(
            key.toString().trim().toLowerCase(),
            entry?.toString().trim() ?? "",
            false,
          );
        }
      });
    } else if (intros is List) {
      for (final entry in intros) {
        if (entry is String) {
          consider("", entry.trim(), false);
        } else if (entry is Map) {
          consider(
            _nextmoeIntroLang(entry, ""),
            _nextmoeIntroText(entry),
            entry["is_machine"] == true,
          );
        }
      }
    }

    final best = authoredZh.isNotEmpty
        ? authoredZh
        : machineZh.isNotEmpty
            ? machineZh
            : authored.isNotEmpty
                ? authored
                : machine;
    return best.length > 2000 ? best.substring(0, 2000) : best;
  }

  static String _nextmoeIntroText(Map entry) {
    for (final key in const [
      "intro",
      "text",
      "value",
      "description",
      "body",
      "content",
    ]) {
      final text = (entry[key] ?? "").toString().trim();
      if (text.isNotEmpty) return text;
    }
    return "";
  }

  static String _nextmoeIntroLang(Map entry, String fallback) {
    for (final key in const ["lang", "intro_lang", "language", "locale"]) {
      final lang = (entry[key] ?? "").toString().trim().toLowerCase();
      if (lang.isNotEmpty) return lang;
    }
    return fallback.trim().toLowerCase();
  }

  static Map<String, String> _nextmoeExternalIds(dynamic refs) {
    final ids = <String, String>{};
    final ranks = <String, int>{};
    void add(String source, String externalId) {
      final key = source.trim().toLowerCase();
      final id = externalId.trim();
      if (!_nextmoeExternalSources.contains(key) || id.isEmpty) return;
      final rank = _nextmoeExternalIdRank(key, id);
      if (!ids.containsKey(key) || rank < ranks[key]!) {
        ids[key] = id;
        ranks[key] = rank;
      }
    }

    if (refs is Map) {
      refs.forEach((source, entry) => add(source.toString(), _nextmoeRefId(entry)));
    } else if (refs is List) {
      for (final entry in refs) {
        if (entry is String) {
          final index = entry.indexOf(":");
          if (index > 0) {
            add(entry.substring(0, index), entry.substring(index + 1));
          }
        } else if (entry is Map) {
          add(
            _nextmoeFirstText(
              entry,
              const ["source", "kind", "type", "provider"],
            ),
            _nextmoeRefId(entry),
          );
        }
      }
    }
    return ids;
  }

  /// Works carry work-level anchors (VNDB `v####`) and release refs
  /// (`r####`); prefer the former so a release id never replaces a VN id.
  static int _nextmoeExternalIdRank(String source, String externalId) {
    if (source == "vndb") {
      return RegExp(r'^v\d+$', caseSensitive: false).hasMatch(externalId)
          ? 0
          : 1;
    }
    if (source == "bangumi" || source == "steam") {
      return RegExp(r'^\d+$').hasMatch(externalId) ? 0 : 1;
    }
    return 1;
  }

  static String _nextmoeRefId(dynamic value) {
    if (value is Map) {
      return _nextmoeFirstText(
        value,
        const ["external_id", "id", "value", "slug"],
      );
    }
    return value?.toString().trim() ?? "";
  }

  static String _nextmoeFirstText(Map entry, List<String> keys) {
    for (final key in keys) {
      final text = (entry[key] ?? "").toString().trim();
      if (text.isNotEmpty) return text;
    }
    return "";
  }

  static String _nextmoeImageUrl(dynamic value) {
    if (value is String) {
      final url = value.trim();
      return (url.startsWith("http://") || url.startsWith("https://"))
          ? url
          : "";
    }
    if (value is Map) {
      for (final key in const ["url", "image_url", "src"]) {
        final url = _nextmoeImageUrl(value[key]);
        if (url.isNotEmpty) return url;
      }
    }
    return "";
  }

  static List<String> _nextmoeImageUrls(dynamic value) {
    if (value is! List) return const [];
    final urls = <String>[];
    for (final entry in value) {
      final url = _nextmoeImageUrl(entry);
      if (url.isNotEmpty && !urls.contains(url)) urls.add(url);
    }
    return urls;
  }

  static List<String> _nextmoeCoverCandidates(dynamic covers, String primary) {
    final portrait = <(int, String)>[];
    final others = <String>[];
    if (covers is List) {
      for (final entry in covers) {
        final url = _nextmoeCoverRowUrl(entry);
        if (url.isEmpty) continue;
        final size = _nextmoeCoverRowSize(entry);
        if (size.$1 > 0 && size.$2 > size.$1) {
          portrait.add((_nextmoeCoverRowVotes(entry), url));
        } else {
          others.add(url);
        }
      }
    }
    portrait.sort((a, b) => b.$1.compareTo(a.$1));
    final ordered = <String>[];
    for (final url in [
      primary,
      ...portrait.map((row) => row.$2),
      ...others,
    ]) {
      if (url.isNotEmpty && !ordered.contains(url)) ordered.add(url);
    }
    return ordered.take(12).toList();
  }

  static String _nextmoeCoverRowUrl(dynamic value) {
    var url = _nextmoeImageUrl(value);
    if (url.isNotEmpty) return url;
    if (value is Map) {
      url = _nextmoeImageUrl(value["image"]);
      if (url.isEmpty) url = _nextmoeImageUrl(value["media"]);
    }
    return url;
  }

  static (int, int) _nextmoeCoverRowSize(dynamic value) {
    if (value is! Map) return (0, 0);
    for (final candidate in [value, value["image"], value["media"]]) {
      if (candidate is! Map) continue;
      final width = int.tryParse(candidate["width"]?.toString() ?? "") ?? 0;
      final height = int.tryParse(candidate["height"]?.toString() ?? "") ?? 0;
      if (width > 0 && height > 0) return (width, height);
    }
    return (0, 0);
  }

  static int _nextmoeCoverRowVotes(dynamic value) {
    if (value is! Map) return 0;
    return int.tryParse(value["votes"]?.toString() ?? "") ?? 0;
  }

  static bool? _nextmoeNsfw(dynamic value) {
    final rating = (value ?? "").toString().trim().toLowerCase();
    if (rating == "r18") return true;
    if (rating == "all_ages" || rating == "sensitive") return false;
    return null;
  }

  static List<Map<String, dynamic>> _nextmoeTags(dynamic value) {
    if (value is! List) return const [];
    final result = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final entry in value) {
      final parsed = _nextmoeTag(entry);
      if (parsed.name.isEmpty || !seen.add(parsed.name.toLowerCase())) continue;
      result.add({
        "name": parsed.name,
        "rating": parsed.rating,
        "is_spoiler": parsed.spoiler,
      });
    }
    result.sort(
      (a, b) => (b["rating"] as double).compareTo(a["rating"] as double),
    );
    return result.take(_maxScrapedTags).toList();
  }

  static ({String name, double rating, bool spoiler}) _nextmoeTag(
    dynamic entry,
  ) {
    if (entry is String) {
      return (name: entry.trim(), rating: 0, spoiler: false);
    }
    if (entry is! Map) return (name: "", rating: 0, spoiler: false);
    var name = "";
    final rawName = entry["name"];
    if (rawName is String) {
      name = rawName.trim();
    } else if (rawName is Map) {
      for (final key in const [
        "zh-cn",
        "zh-Hans",
        "zh-hans",
        "zh",
        "en",
        "ja",
      ]) {
        final value = rawName[key];
        if (value is String && value.trim().isNotEmpty) {
          name = value.trim();
          break;
        }
      }
      if (name.isEmpty) {
        for (final value in rawName.values) {
          if (value is String && value.trim().isNotEmpty) {
            name = value.trim();
            break;
          }
        }
      }
    }
    if (name.isEmpty) {
      name = (entry["display_name"] ?? entry["slug"] ?? "").toString().trim();
    }
    var rating = 0.0;
    for (final key in const ["rating", "score", "votes", "count"]) {
      final parsed = double.tryParse(entry[key]?.toString() ?? "");
      if (parsed != null && parsed != 0) {
        rating = parsed;
        break;
      }
    }
    final rawSpoiler = entry["spoiler"];
    final spoiler = rawSpoiler is bool
        ? rawSpoiler
        : rawSpoiler is String
            ? !const ["", "none", "false", "0"]
                .contains(rawSpoiler.trim().toLowerCase())
            : rawSpoiler is num && rawSpoiler > 0;
    return (name: name, rating: rating, spoiler: spoiler);
  }

  static String _nextmoeDate(dynamic value) {
    final text = (value ?? "").toString().trim();
    if (text.isEmpty) return "";
    final index = text.indexOf("T");
    return index > 0 ? text.substring(0, index) : text;
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
