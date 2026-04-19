import 'dart:convert';

enum Board {
  safebooru,
  danbooru,
  konachan,
  yandere,
  e926,
  e621,
  gelbooru,
  rule34,
}

extension BoardInfo on Board {
  String get label => switch (this) {
    Board.safebooru => 'Safebooru',
    Board.danbooru => 'Danbooru',
    Board.konachan => 'Konachan',
    Board.yandere => 'Yande.re',
    Board.e926 => 'e926',
    Board.e621 => 'e621',
    Board.gelbooru => 'Gelbooru',
    Board.rule34 => 'Rule34',
  };

  String get host => switch (this) {
    Board.safebooru => 'safebooru.org',
    Board.danbooru => 'danbooru.donmai.us',
    Board.konachan => 'konachan.com',
    Board.yandere => 'yande.re',
    Board.e926 => 'e926.net',
    Board.e621 => 'e621.net',
    Board.gelbooru => 'gelbooru.com',
    Board.rule34 => 'rule34.xxx',
  };

  bool get requiresAuth => this == Board.rule34 || this == Board.gelbooru;

  String get authUrl => switch (this) {
    Board.rule34 => 'https://rule34.xxx/index.php?page=account&s=options',
    Board.gelbooru => 'https://gelbooru.com/index.php?page=account&s=options',
    _ => 'https://$host',
  };
}

enum TagCategory {
  general,
  artist,
  copyright,
  character,
  species,
  meta,
  lore,
  unknown,
}

extension TagCategoryInfo on TagCategory {
  String get label => switch (this) {
    TagCategory.general => 'General',
    TagCategory.artist => 'Artist',
    TagCategory.copyright => 'Copyright',
    TagCategory.character => 'Character',
    TagCategory.species => 'Species',
    TagCategory.meta => 'Meta',
    TagCategory.lore => 'Lore',
    TagCategory.unknown => 'Unknown',
  };

  String get value => name;

  static TagCategory parse(dynamic value) {
    final text = '$value'.trim().toLowerCase();
    return switch (text) {
      'general' => TagCategory.general,
      'artist' => TagCategory.artist,
      'copyright' => TagCategory.copyright,
      'character' => TagCategory.character,
      'species' => TagCategory.species,
      'meta' => TagCategory.meta,
      'lore' => TagCategory.lore,
      _ => TagCategory.unknown,
    };
  }
}

class TagInfo {
  const TagInfo({required this.name, required this.category});
  final String name;
  final TagCategory category;

  Map<String, dynamic> toMap() => {'name': name, 'category': category.name};

  factory TagInfo.fromMap(Map<dynamic, dynamic> map) => TagInfo(
    name: '${map['name'] ?? map['tag'] ?? map['value'] ?? ''}'.trim(),
    category: TagCategoryInfo.parse(map['category'] ?? map['type']),
  );
}

class TagSuggestion {
  const TagSuggestion({
    required this.name,
    required this.category,
    this.postCount,
  });
  final String name;
  final TagCategory category;
  final int? postCount;

  Map<String, dynamic> toMap() => {
    'name': name,
    'category': category.name,
    if (postCount != null) 'postCount': postCount,
  };

  factory TagSuggestion.fromMap(Map<dynamic, dynamic> map) => TagSuggestion(
    name: '${map['name'] ?? map['tag'] ?? map['value'] ?? ''}'.trim(),
    category: TagCategoryInfo.parse(map['category'] ?? map['type']),
    postCount: map['postCount'] is num
        ? (map['postCount'] as num).toInt()
        : int.tryParse('${map['postCount'] ?? ''}'),
  );
}

class Credentials {
  const Credentials({required this.userId, required this.apiKey});
  final String userId;
  final String apiKey;
  bool get isValid => userId.trim().isNotEmpty && apiKey.trim().isNotEmpty;
}

class MediaPost {
  const MediaPost({
    required this.id,
    required this.url,
    required this.previewUrl,
    required this.tags,
    required this.rating,
    required this.uploader,
    required this.source,
    required this.width,
    required this.height,
    required this.score,
    required this.description,
    required this.isVideo,
    required this.extension,
    this.tagDetails = const [],
    this.postUrl,
  });

  factory MediaPost.fromMap(Map<dynamic, dynamic> map) {
    final url = '${map['url'] ?? ''}';
    final rawTags = map['tags'];
    final tags = rawTags is List
        ? rawTags
              .map((tag) => '$tag'.trim())
              .where((tag) => tag.isNotEmpty)
              .toList(growable: false)
        : '$rawTags'.trim().isEmpty || rawTags == null
        ? const <String>[]
        : '$rawTags'.split(RegExp(r'\s+'));
    final detailsValue = map['tagDetails'] ?? map['typedTags'];
    final details = <TagInfo>[];
    final seen = <String>{};
    if (detailsValue is List) {
      for (final value in detailsValue.whereType<Map>()) {
        final tag = TagInfo.fromMap(value);
        final key = tag.name.toLowerCase();
        if (tag.name.isNotEmpty && seen.add(key)) details.add(tag);
      }
    }
    if (details.isEmpty) {
      details.addAll(
        tags.map((tag) => TagInfo(name: tag, category: TagCategory.general)),
      );
    } else {
      for (final tag in tags) {
        if (seen.add(tag.toLowerCase())) {
          details.add(TagInfo(name: tag, category: TagCategory.unknown));
        }
      }
    }
    final extension = _extension(url);
    return MediaPost(
      id: _int(map['id']),
      url: url,
      previewUrl: '${map['previewUrl'] ?? map['preview_url'] ?? url}',
      tags: tags,
      rating: '${map['rating'] ?? ''}',
      uploader: '${map['uploader'] ?? map['owner'] ?? ''}',
      source: '${map['source'] ?? ''}',
      width: _int(map['width']),
      height: _int(map['height']),
      score: _int(map['score']),
      description: '${map['description'] ?? ''}',
      isVideo:
          _bool(map['isVideo']) ||
          const {'mp4', 'webm', 'mov', 'avi'}.contains(extension),
      extension: extension,
      tagDetails: List.unmodifiable(details),
      postUrl: _stringOrNull(map['postUrl'] ?? map['post_url']),
    );
  }

  final int id;
  final String url,
      previewUrl,
      rating,
      uploader,
      source,
      description,
      extension;
  final List<String> tags;
  final List<TagInfo> tagDetails;
  final String? postUrl;
  final int width, height, score;
  final bool isVideo;

  Map<String, dynamic> toMap() => {
    'id': id,
    'url': url,
    'previewUrl': previewUrl,
    'tags': tags,
    'rating': rating,
    'uploader': uploader,
    'source': source,
    'width': width,
    'height': height,
    'score': score,
    'description': description,
    'isVideo': isVideo,
    'extension': extension,
    'tagDetails': tagDetails.map((tag) => tag.toMap()).toList(growable: false),
    'postUrl': postUrl,
  };

  static int _int(dynamic value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;
  static String? _stringOrNull(dynamic value) =>
      value is String && value.trim().isNotEmpty ? value : null;
  static bool _bool(dynamic value) =>
      value == true || value == 1 || value == 'true';
  static String _extension(String url) {
    final clean = url.split('?').first.split('#').first;
    final dot = clean.lastIndexOf('.');
    return dot >= 0 && dot + 1 < clean.length
        ? clean.substring(dot + 1).toLowerCase()
        : '';
  }
}

class AppSettings {
  const AppSettings({
    this.columns = 3,
    this.rows = 4,
    this.batchSize = 50,
    this.blacklist = const [],
    this.downloadDirectory,
    this.excludeAi = true,
    this.gesturesEnabled = true,
    this.savedQueries = const [],
  });
  final int columns, rows, batchSize;
  final List<String> blacklist;
  final String? downloadDirectory;
  final bool excludeAi;
  final bool gesturesEnabled;
  final List<List<String>> savedQueries;

  AppSettings normalized() => AppSettings(
    columns: columns.clamp(1, 6),
    rows: rows.clamp(2, 8),
    batchSize: ((batchSize.clamp(50, 200) - 50) ~/ 10) * 10 + 50,
    blacklist: _normalizedTags(blacklist),
    downloadDirectory: downloadDirectory,
    excludeAi: excludeAi,
    gesturesEnabled: gesturesEnabled,
    savedQueries: _normalizedQueries(savedQueries),
  );

  AppSettings copyWith({
    int? columns,
    int? rows,
    int? batchSize,
    List<String>? blacklist,
    Object? downloadDirectory = _unset,
    bool? excludeAi,
    bool? gesturesEnabled,
    List<List<String>>? savedQueries,
  }) => AppSettings(
    columns: columns ?? this.columns,
    rows: rows ?? this.rows,
    batchSize: batchSize ?? this.batchSize,
    blacklist: blacklist ?? this.blacklist,
    downloadDirectory: identical(downloadDirectory, _unset)
        ? this.downloadDirectory
        : downloadDirectory as String?,
    excludeAi: excludeAi ?? this.excludeAi,
    gesturesEnabled: gesturesEnabled ?? this.gesturesEnabled,
    savedQueries: savedQueries ?? this.savedQueries,
  ).normalized();
  static const _unset = Object();

  Map<String, dynamic> toMap() => {
    'columns': columns,
    'rows': rows,
    'batchSize': batchSize,
    'blacklist': blacklist,
    'downloadDirectory': downloadDirectory,
    'excludeAi': excludeAi,
    'gesturesEnabled': gesturesEnabled,
    'savedQueries': savedQueries,
  };
  factory AppSettings.fromMap(Map<dynamic, dynamic> map) => AppSettings(
    columns: _asInt(map['columns'], 3),
    rows: _asInt(map['rows'], 4),
    batchSize: _asInt(map['batchSize'], 50),
    blacklist: (map['blacklist'] as List? ?? const [])
        .map((e) => '$e')
        .toList(),
    downloadDirectory: map['downloadDirectory'] as String?,
    excludeAi: _asBool(map['excludeAi'] ?? map['noAi'], true),
    gesturesEnabled: _asBool(map['gesturesEnabled'], true),
    savedQueries: _queriesFromMap(map['savedQueries']),
  ).normalized();
  String encode() => jsonEncode(toMap());
  factory AppSettings.decode(String value) =>
      AppSettings.fromMap(jsonDecode(value) as Map);
  static int _asInt(dynamic value, int fallback) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? fallback;
  static bool _asBool(dynamic value, bool fallback) => value is bool
      ? value
      : value == 1 || value == '1' || value == 'true'
      ? true
      : value == 0 || value == '0' || value == 'false'
      ? false
      : fallback;

  static String _normalizeTag(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  static List<String> _normalizedTags(Iterable<String> values) {
    final result = <String>[];
    final seen = <String>{};
    for (final value in values) {
      final tag = _normalizeTag(value);
      if (tag.isNotEmpty && seen.add(tag)) result.add(tag);
    }
    return List.unmodifiable(result);
  }

  static List<List<String>> _normalizedQueries(Iterable<List<String>> values) {
    final result = <List<String>>[];
    final seen = <String>{};
    for (final query in values) {
      final tags = _normalizedTags(query);
      if (tags.isEmpty) continue;
      final key = tags.join('\u0000');
      if (seen.add(key)) result.add(tags);
      if (result.length == 50) break;
    }
    return List.unmodifiable(result);
  }

  static List<List<String>> _queriesFromMap(dynamic value) => value is List
      ? value
            .whereType<List>()
            .map((query) => query.map((tag) => '$tag').toList())
            .toList()
      : const [];

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! AppSettings) return false;
    if (other.columns != columns ||
        other.rows != rows ||
        other.batchSize != batchSize ||
        other.downloadDirectory != downloadDirectory ||
        other.excludeAi != excludeAi ||
        other.gesturesEnabled != gesturesEnabled ||
        other.blacklist.length != blacklist.length ||
        other.savedQueries.length != savedQueries.length) {
      return false;
    }
    for (var i = 0; i < blacklist.length; i++) {
      if (blacklist[i] != other.blacklist[i]) return false;
    }
    for (var i = 0; i < savedQueries.length; i++) {
      final a = savedQueries[i];
      final b = other.savedQueries[i];
      if (a.length != b.length) return false;
      for (var j = 0; j < a.length; j++) {
        if (a[j] != b[j]) return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    columns,
    rows,
    batchSize,
    downloadDirectory,
    excludeAi,
    gesturesEnabled,
    Object.hashAll(blacklist),
    Object.hashAll(savedQueries.map(Object.hashAll)),
  );
}
