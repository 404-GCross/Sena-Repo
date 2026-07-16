/// Game data models matching the server API responses.

class GameVersion {
  final int id;
  final String platform;
  final String filename;
  final String filePath;
  final int fileSize;
  final String? extractPassword;

  GameVersion({
    required this.id,
    required this.platform,
    required this.filename,
    required this.filePath,
    required this.fileSize,
    this.extractPassword,
  });

  factory GameVersion.fromJson(Map<String, dynamic> json) {
    return GameVersion(
      id: json["id"] ?? 0,
      platform: json["platform"] ?? "",
      filename: json["filename"] ?? "",
      filePath: json["file_path"] ?? "",
      fileSize: json["file_size"] ?? 0,
      extractPassword: json["extract_password"],
    );
  }
}

class Tag {
  final int id;
  final String name;
  final String color;

  Tag({required this.id, required this.name, required this.color});

  factory Tag.fromJson(Map<String, dynamic> json) {
    return Tag(
      id: json["id"] ?? 0,
      name: json["name"] ?? "",
      color: json["color"] ?? "#3B82F6",
    );
  }
}

class GameSummary {
  final int id;
  final String name;
  final String? companyName;
  final String? developer;
  final String folderPath;
  final String? coverPath;
  final String platformSummary;
  final List<String> tagNames;
  final String importedAt;
  final int length;
  final int lengthMinutes;

  GameSummary({
    required this.id,
    required this.name,
    this.companyName,
    this.developer,
    required this.folderPath,
    this.coverPath,
    required this.platformSummary,
    required this.tagNames,
    required this.importedAt,
    this.length = 0,
    this.lengthMinutes = 0,
  });

  factory GameSummary.fromJson(Map<String, dynamic> json) {
    return GameSummary(
      id: json["id"] ?? 0,
      name: json["name"] ?? "",
      companyName: json["company_name"],
      developer: json["developer"],
      folderPath: json["folder_path"] ?? "",
      coverPath: json["cover_path"],
      platformSummary: json["platform_summary"] ?? "",
      tagNames: List<String>.from(json["tag_names"] ?? []),
      importedAt: json["imported_at"] ?? "",
      length: json["length"] ?? 0,
      lengthMinutes: json["length_minutes"] ?? 0,
    );
  }
}

class GameDetail {
  final int id;
  final String name;
  final String? companyName;
  final int rootId;
  final String folderPath;
  final String? coverPath;
  final String? bgPath;
  final String? developer;
  final String? description;
  final String? releaseDate;
  final String? vndbId;
  final String? steamId;
  final String? bangumiId;
  final int length;
  final int lengthMinutes;
  final bool isDeleted;
  final String importedAt;
  final String updatedAt;
  final List<GameVersion> versions;
  final List<Tag> tags;

  GameDetail({
    required this.id,
    required this.name,
    this.companyName,
    required this.rootId,
    required this.folderPath,
    this.coverPath,
    this.bgPath,
    this.developer,
    this.description,
    this.releaseDate,
    this.vndbId,
    this.steamId,
    this.bangumiId,
    this.length = 0,
    this.lengthMinutes = 0,
    required this.isDeleted,
    required this.importedAt,
    required this.updatedAt,
    required this.versions,
    required this.tags,
  });

  factory GameDetail.fromJson(Map<String, dynamic> json) {
    return GameDetail(
      id: json["id"] ?? 0,
      name: json["name"] ?? "",
      companyName: json["company_name"],
      rootId: json["root_id"] ?? 0,
      folderPath: json["folder_path"] ?? "",
      coverPath: json["cover_path"],
      bgPath: json["bg_path"],
      developer: json["developer"],
      description: json["description"],
      releaseDate: json["release_date"],
      vndbId: json["vndb_id"],
      steamId: json["steam_id"],
      bangumiId: json["bangumi_id"],
      length: json["length"] ?? 0,
      lengthMinutes: json["length_minutes"] ?? 0,
      isDeleted: json["is_deleted"] ?? false,
      importedAt: json["imported_at"] ?? "",
      updatedAt: json["updated_at"] ?? "",
      versions:
          (json["versions"] as List<dynamic>?)
              ?.map((v) => GameVersion.fromJson(v as Map<String, dynamic>))
              .toList() ??
          [],
      tags:
          (json["tags"] as List<dynamic>?)
              ?.map((t) => Tag.fromJson(t as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}
