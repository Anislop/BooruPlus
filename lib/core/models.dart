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

enum Rating { general, questionable, explicit }

extension RatingInfo on Rating {
  String get label => switch (this) {
    Rating.general => 'General',
    Rating.questionable => 'Questionable',
    Rating.explicit => 'Explicit',
  };

  String get queryValue => switch (this) {
    Rating.general => 'safe',
    Rating.questionable => 'questionable',
    Rating.explicit => 'explicit',
  };

  String get shortQueryValue => switch (this) {
    Rating.general => 's',
    Rating.questionable => 'q',
    Rating.explicit => 'e',
  };

  static Rating? parse(dynamic value) {
    final text = '$value'.trim().toLowerCase();
    return switch (text) {
      'general' || 'safe' || 's' || 'g' => Rating.general,
      'questionable' || 'q' => Rating.questionable,
      'explicit' || 'e' => Rating.explicit,
      _ => null,
    };
  }
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

/// A lower-bitrate rendition of a video post, when the provider supplies one.
class VideoVariant {
  const VideoVariant({
    required this.label,
    required this.url,
    this.width = 0,
    this.height = 0,
    this.quality = 0,
  });
  final String label, url;
  final int width, height;

  /// Resolution tier such as 720 for "720p". Providers name tiers by the
  /// short side, so a portrait 720p rendition can be 1440 pixels tall.
  final int quality;

  Map<String, dynamic> toMap() => {
    'label': label,
    'url': url,
    'width': width,
    'height': height,
    'quality': quality,
  };

  factory VideoVariant.fromMap(Map<dynamic, dynamic> map) {
    final width = MediaPost._int(map['width']);
    final height = MediaPost._int(map['height']);
    final label = '${map['label'] ?? ''}'.trim();
    final named = int.tryParse(
      RegExp(r'^(\d+)p').firstMatch(label)?.group(1) ?? '',
    );
    final quality = MediaPost._int(map['quality']) > 0
        ? MediaPost._int(map['quality'])
        : named ?? MediaPost._tier(width, height);
    return VideoVariant(
      label: label.isEmpty && quality > 0 ? '${quality}p' : label,
      url: '${map['url'] ?? ''}'.trim(),
      width: width,
      height: height,
      quality: quality,
    );
  }
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
    this.videoVariants = const [],
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
    final variantsValue = map['videoVariants'];
    final variants = variantsValue is List
        ? variantsValue
              .whereType<Map>()
              .map(VideoVariant.fromMap)
              .where((variant) => variant.url.isNotEmpty && variant.url != url)
              .toList(growable: false)
        : const <VideoVariant>[];
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
      videoVariants: variants,
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
  final List<VideoVariant> videoVariants;

  /// Resolution tier of the original file (its short side).
  int get videoQuality => _tier(width, height);

  /// The best stream at or below the [maxQuality] tier; null means the
  /// original file. A [maxQuality] of 0 always selects the original.
  VideoVariant? videoVariantFor(int maxQuality) {
    if (maxQuality <= 0 || videoVariants.isEmpty) return null;
    final original = videoQuality;
    if (original > 0 && original <= maxQuality) return null;
    VideoVariant? best;
    for (final variant in videoVariants) {
      if (variant.quality <= 0 || variant.quality > maxQuality) continue;
      if (best == null || variant.quality > best.quality) best = variant;
    }
    if (best != null) return best;
    // Every rendition exceeds the request: the smallest is still closest.
    return videoVariants.reduce((a, b) => a.quality <= b.quality ? a : b);
  }

  MediaPost withUrls({required String url, required String previewUrl}) =>
      MediaPost(
        id: id,
        url: url,
        previewUrl: previewUrl,
        tags: tags,
        rating: rating,
        uploader: uploader,
        source: source,
        width: width,
        height: height,
        score: score,
        description: description,
        isVideo: isVideo,
        extension: extension,
        tagDetails: tagDetails,
        postUrl: postUrl,
        videoVariants: videoVariants,
      );

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
    if (videoVariants.isNotEmpty)
      'videoVariants': videoVariants
          .map((variant) => variant.toMap())
          .toList(growable: false),
  };

  static int _int(dynamic value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;
  static int _tier(int width, int height) =>
      width > 0 && height > 0 ? (width < height ? width : height) : height;
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

class SavedPost {
  const SavedPost({required this.board, required this.post});
  final Board board;
  final MediaPost post;

  String get identity => post.id > 0
      ? '${board.name}:id:${post.id}'
      : '${board.name}:url:${_withoutCredentials(post.url)}|preview:${_withoutCredentials(post.previewUrl)}|tags:${post.tags.join(' ')}|source:${post.source}|size:${post.width}x${post.height}|description:${post.description}';

  SavedPost authorized(Credentials? credentials) {
    if (board != Board.gelbooru ||
        credentials == null ||
        !credentials.isValid) {
      return this;
    }
    return SavedPost(
      board: board,
      post: _withUrls(
        post,
        _authorizeUrl(post.url, credentials),
        _authorizeUrl(post.previewUrl, credentials),
      ),
    );
  }

  SavedPost sanitized() => SavedPost(
    board: board,
    post: _withUrls(
      post,
      _withoutCredentials(post.url),
      _withoutCredentials(post.previewUrl),
    ),
  );

  Map<String, dynamic> toMap() => {'board': board.name, 'post': post.toMap()};
  factory SavedPost.fromMap(Map<dynamic, dynamic> map) => SavedPost(
    board: Board.values.firstWhere(
      (value) => value.name == map['board'],
      orElse: () => Board.safebooru,
    ),
    post: MediaPost.fromMap((map['post'] as Map?) ?? map),
  );

  @override
  bool operator ==(Object other) =>
      other is SavedPost && other.identity == identity;

  @override
  int get hashCode => identity.hashCode;

  static String _authorizeUrl(String value, Credentials credentials) {
    if (value.trim().isEmpty) return value;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        !(uri.host == 'gelbooru.com' || uri.host.endsWith('.gelbooru.com'))) {
      return value;
    }
    final query = Map<String, String>.from(uri.queryParameters)
      ..['api_key'] = credentials.apiKey
      ..['user_id'] = credentials.userId;
    return uri.replace(queryParameters: query).toString();
  }

  static String _withoutCredentials(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.query.isEmpty) return value;
    final query = Map<String, String>.from(uri.queryParameters)
      ..remove('api_key')
      ..remove('user_id');
    return uri.replace(queryParameters: query).toString();
  }

  static MediaPost _withUrls(MediaPost value, String url, String previewUrl) =>
      value.withUrls(url: url, previewUrl: previewUrl);
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
    this.hierarchicalGrid = false,
    this.hidePostTags = false,
    this.blurExplicit = false,
    this.blurQuestionable = false,
    this.savedQueries = const [],
    this.recentSearches = const [],
    this.selectedRatings = const [
      Rating.general,
      Rating.questionable,
      Rating.explicit,
    ],
    this.searchedTagCounts = const {},
    this.browsedTagCounts = const {},
    this.videoQuality = 0,
  });
  final int columns, rows, batchSize;

  /// Preferred maximum video tier (e.g. 720 for 720p); 0 streams the
  /// original file.
  final int videoQuality;
  final List<String> blacklist;
  final String? downloadDirectory;
  final bool excludeAi;
  final bool gesturesEnabled;
  final bool hierarchicalGrid;
  final bool hidePostTags;
  final bool blurExplicit;
  final bool blurQuestionable;
  final List<List<String>> savedQueries;
  final List<List<String>> recentSearches;
  final List<Rating> selectedRatings;
  final Map<String, int> searchedTagCounts;
  final Map<String, int> browsedTagCounts;

  AppSettings normalized() => AppSettings(
    columns: columns.clamp(1, 6),
    rows: rows.clamp(2, 8),
    batchSize: ((batchSize.clamp(50, 200) - 50) ~/ 10) * 10 + 50,
    blacklist: _normalizedTags(blacklist),
    downloadDirectory: downloadDirectory,
    excludeAi: excludeAi,
    gesturesEnabled: gesturesEnabled,
    hierarchicalGrid: hierarchicalGrid,
    hidePostTags: hidePostTags,
    blurExplicit: blurExplicit,
    blurQuestionable: blurQuestionable,
    savedQueries: _normalizedQueries(savedQueries),
    recentSearches: _normalizedQueries(recentSearches, limit: 30),
    selectedRatings: _normalizedRatings(selectedRatings),
    searchedTagCounts: _normalizedCounts(searchedTagCounts),
    browsedTagCounts: _normalizedCounts(browsedTagCounts),
    videoQuality: videoQuality < 0 ? 0 : videoQuality,
  );

  AppSettings copyWith({
    int? columns,
    int? rows,
    int? batchSize,
    List<String>? blacklist,
    Object? downloadDirectory = _unset,
    bool? excludeAi,
    bool? gesturesEnabled,
    bool? hierarchicalGrid,
    bool? hidePostTags,
    bool? blurExplicit,
    bool? blurQuestionable,
    List<List<String>>? savedQueries,
    List<List<String>>? recentSearches,
    List<Rating>? selectedRatings,
    Map<String, int>? searchedTagCounts,
    Map<String, int>? browsedTagCounts,
    int? videoQuality,
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
    hierarchicalGrid: hierarchicalGrid ?? this.hierarchicalGrid,
    hidePostTags: hidePostTags ?? this.hidePostTags,
    blurExplicit: blurExplicit ?? this.blurExplicit,
    blurQuestionable: blurQuestionable ?? this.blurQuestionable,
    savedQueries: savedQueries ?? this.savedQueries,
    recentSearches: recentSearches ?? this.recentSearches,
    selectedRatings: selectedRatings ?? this.selectedRatings,
    searchedTagCounts: searchedTagCounts ?? this.searchedTagCounts,
    browsedTagCounts: browsedTagCounts ?? this.browsedTagCounts,
    videoQuality: videoQuality ?? this.videoQuality,
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
    'hierarchicalGrid': hierarchicalGrid,
    'hidePostTags': hidePostTags,
    'blurExplicit': blurExplicit,
    'blurQuestionable': blurQuestionable,
    'savedQueries': savedQueries,
    'recentSearches': recentSearches,
    'selectedRatings': selectedRatings.map((rating) => rating.name).toList(),
    'searchedTagCounts': searchedTagCounts,
    'browsedTagCounts': browsedTagCounts,
    'videoQuality': videoQuality,
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
    hierarchicalGrid: _asBool(map['hierarchicalGrid'], false),
    hidePostTags: _asBool(map['hidePostTags'], false),
    blurExplicit: _asBool(map['blurExplicit'], false),
    blurQuestionable: _asBool(map['blurQuestionable'], false),
    savedQueries: _queriesFromMap(map['savedQueries']),
    recentSearches: _queriesFromMap(map['recentSearches']),
    selectedRatings: _ratingsFromMap(map['selectedRatings']),
    searchedTagCounts: _countsFromMap(map['searchedTagCounts']),
    browsedTagCounts: _countsFromMap(map['browsedTagCounts']),
    videoQuality: _asInt(map['videoQuality'], 0),
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

  static List<List<String>> _normalizedQueries(
    Iterable<List<String>> values, {
    int limit = 50,
  }) {
    final result = <List<String>>[];
    final seen = <String>{};
    for (final query in values) {
      final tags = _normalizedTags(query);
      if (tags.isEmpty) continue;
      final key = tags.join('\u0000');
      if (seen.add(key)) result.add(tags);
      if (result.length == limit) break;
    }
    return List.unmodifiable(result);
  }

  static List<List<String>> _queriesFromMap(dynamic value) => value is List
      ? value
            .whereType<List>()
            .map((query) => query.map((tag) => '$tag').toList())
            .toList()
      : const [];

  static List<Rating> _ratingsFromMap(dynamic value) => value is List
      ? value.map(RatingInfo.parse).whereType<Rating>().toList()
      : Rating.values;

  static List<Rating> _normalizedRatings(Iterable<Rating> values) => List.unmodifiable(
    Rating.values.where(values.toSet().contains),
  );

  static Map<String, int> _countsFromMap(dynamic value) => value is Map
      ? value.map((key, count) => MapEntry('$key', _asInt(count, 0)))
      : const {};

  static Map<String, int> _normalizedCounts(Map<String, int> values) {
    final result = <String, int>{};
    for (final entry in values.entries) {
      final key = _normalizeTag(entry.key);
      if (key.isNotEmpty && entry.value > 0) {
        result[key] = (result[key] ?? 0) + entry.value;
      }
    }
    final entries = result.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        return byCount == 0 ? a.key.compareTo(b.key) : byCount;
      });
    return Map.unmodifiable(Map.fromEntries(entries.take(100)));
  }

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
        other.hierarchicalGrid != hierarchicalGrid ||
        other.hidePostTags != hidePostTags ||
        other.blurExplicit != blurExplicit ||
        other.blurQuestionable != blurQuestionable ||
        other.videoQuality != videoQuality ||
        other.blacklist.length != blacklist.length ||
        other.savedQueries.length != savedQueries.length ||
        other.recentSearches.length != recentSearches.length) {
      return false;
    }
    if (other.selectedRatings.length != selectedRatings.length ||
        other.searchedTagCounts.length != searchedTagCounts.length ||
        other.browsedTagCounts.length != browsedTagCounts.length ||
        !_sameRatings(other.selectedRatings, selectedRatings) ||
        !_sameCounts(other.searchedTagCounts, searchedTagCounts) ||
        !_sameCounts(other.browsedTagCounts, browsedTagCounts)) {
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
    for (var i = 0; i < recentSearches.length; i++) {
      final a = recentSearches[i];
      final b = other.recentSearches[i];
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
    hierarchicalGrid,
    hidePostTags,
    blurExplicit,
    blurQuestionable,
    Object.hashAll(blacklist),
    Object.hashAll(savedQueries.map(Object.hashAll)),
    Object.hashAll(recentSearches.map(Object.hashAll)),
    Object.hashAll(selectedRatings),
    _countsHash(searchedTagCounts),
    _countsHash(browsedTagCounts),
    videoQuality,
  );

  static bool _sameRatings(List<Rating> a, List<Rating> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameCounts(Map<String, int> a, Map<String, int> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  static int _countsHash(Map<String, int> counts) => Object.hashAll(
    (counts.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).map(
      (entry) => Object.hash(entry.key, entry.value),
    ),
  );
}
