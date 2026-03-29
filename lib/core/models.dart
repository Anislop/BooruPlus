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
  });

  factory MediaPost.fromMap(Map<dynamic, dynamic> map) {
    final url = '${map['url'] ?? ''}';
    final rawTags = map['tags'];
    final tags = rawTags is List
        ? rawTags
              .map((tag) => '$tag')
              .where((tag) => tag.isNotEmpty)
              .toList(growable: false)
        : '$rawTags'.trim().isEmpty || rawTags == null
        ? const <String>[]
        : '$rawTags'.split(RegExp(r'\s+'));
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
  };

  static int _int(dynamic value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;
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
    this.savedQueries = const [],
  });
  final int columns, rows, batchSize;
  final List<String> blacklist;
  final String? downloadDirectory;
  final bool excludeAi;
  final List<List<String>> savedQueries;

  AppSettings normalized() => AppSettings(
    columns: columns.clamp(1, 6),
    rows: rows.clamp(2, 8),
    batchSize: ((batchSize.clamp(50, 200) - 50) ~/ 10) * 10 + 50,
    blacklist: _normalizedTags(blacklist),
    downloadDirectory: downloadDirectory,
    excludeAi: excludeAi,
    savedQueries: _normalizedQueries(savedQueries),
  );

  AppSettings copyWith({
    int? columns,
    int? rows,
    int? batchSize,
    List<String>? blacklist,
    Object? downloadDirectory = _unset,
    bool? excludeAi,
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
}
