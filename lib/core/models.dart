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
  sankaku,
  idolcomplex,
  tbib,
  aibooru,
  nozomi,
  sakugabooru,
  xbooru,
  mspabooru,
  eshuushuu,
  mikubooru,
  nanbooru,
}

/// Websites the app offers, in enum order: every board except retired ones.
final List<Board> listedBoards = List.unmodifiable(
  Board.values.where((board) => !board.isRetired),
);

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
    Board.sankaku => 'Sankaku Complex',
    Board.idolcomplex => 'Idol Complex',
    Board.tbib => 'TBIB',
    Board.aibooru => 'AIBooru',
    Board.nozomi => 'Nozomi',
    Board.sakugabooru => 'Sakugabooru',
    Board.xbooru => 'XBooru',
    Board.mspabooru => 'MSPABooru',
    Board.eshuushuu => 'E-Shuushuu',
    Board.mikubooru => 'Mikubooru',
    Board.nanbooru => 'Nanbooru',
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
    Board.sankaku => 'www.sankakucomplex.com',
    Board.idolcomplex => 'www.idolcomplex.com',
    Board.tbib => 'tbib.org',
    // aibooru.org is a parked domain; the site and its API live here.
    Board.aibooru => 'aibooru.online',
    Board.nozomi => 'nozomi.la',
    Board.sakugabooru => 'www.sakugabooru.com',
    Board.xbooru => 'xbooru.com',
    Board.mspabooru => 'mspabooru.com',
    Board.eshuushuu => 'e-shuushuu.net',
    // Mikubooru (Hybooru) and Nanbooru (Shimmie) live on these hosts.
    Board.mikubooru => 'booru.funmaker.moe',
    Board.nanbooru => 'emmytherobot.art',
  };

  bool get requiresAuth => this == Board.rule34 || this == Board.gelbooru;

  /// Boards searched with Gelbooru 0.2 syntax: `sort:` ordering, no date
  /// searches, and ratings filtered locally.
  bool get usesGelbooruSyntax =>
      this == Board.gelbooru ||
      this == Board.rule34 ||
      this == Board.tbib ||
      this == Board.xbooru ||
      this == Board.mspabooru;

  /// Whether posts carry a rating. Nozomi, E-Shuushuu, Mikubooru, and
  /// Nanbooru do not rate posts, so rating filters do not apply there.
  bool get hasRatings => !const {
    Board.nozomi,
    Board.eshuushuu,
    Board.mikubooru,
    Board.nanbooru,
  }.contains(this);

  /// Whether a search can start at an upload date (Dart sends
  /// `created_at:>=` or `date:`; native clients translate it).
  bool get supportsDateSearch =>
      !usesGelbooruSyntax && this != Board.nozomi && this != Board.mikubooru;

  /// Whether searches can order by favorite count.
  bool get supportsFavoriteOrder =>
      !usesGelbooruSyntax &&
      !isSankakuFamily &&
      this != Board.sakugabooru &&
      this != Board.mikubooru;

  /// Boards made of AI-generated media, where the no-AI setting is ignored.
  bool get isAiBoard => this == Board.aibooru;

  /// Boards the app no longer offers. Their code and saved data stay, but
  /// they are left out of the website lists, searches, and booruShorts.
  bool get isRetired => this == Board.aibooru;

  /// Boards served by Sankaku's API (Sankaku Complex and Idol Complex): the
  /// same search syntax, tag limits, keyset paging, and signed media URLs.
  bool get isSankakuFamily =>
      this == Board.sankaku || this == Board.idolcomplex;

  /// Boards with an optional username/password sign-in. The password is
  /// exchanged natively for a session token; only the token is stored.
  bool get supportsSignIn => this == Board.sankaku;

  /// Boards whose connection is managed in Settings.
  bool get supportsAuth => requiresAuth || supportsSignIn;

  /// The query that limits a search to videos, for booruShorts; null on
  /// boards without usable video (Safebooru and TBIB return only GIFs for
  /// `video`; Konachan, Yande.re, MSPABooru, E-Shuushuu, and Mikubooru host
  /// images). See docs/booru-shorts.md.
  List<String>? get shortsVideoQuery => switch (this) {
    // A metatag: it does not count toward the anonymous tag limit.
    Board.danbooru || Board.aibooru => const ['filetype:mp4,webm'],
    Board.e621 || Board.e926 => const ['~type:webm', '~type:mp4'],
    Board.gelbooru ||
    Board.rule34 ||
    Board.sankaku ||
    Board.idolcomplex ||
    Board.nozomi ||
    Board.xbooru ||
    Board.nanbooru => const ['video'],
    // Sakugabooru's clips are tagged `animated`.
    Board.sakugabooru => const ['animated'],
    Board.safebooru ||
    Board.tbib ||
    Board.konachan ||
    Board.yandere ||
    Board.mspabooru ||
    Board.eshuushuu ||
    Board.mikubooru => null,
  };

  bool get hasShorts => shortsVideoQuery != null;

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

/// The app palette: the BooruPlus dark theme, a white theme, or pure black
/// for OLED screens.
enum ThemeChoice { standard, white, amoled }

extension ThemeChoiceInfo on ThemeChoice {
  String get label => switch (this) {
    ThemeChoice.standard => 'Default',
    ThemeChoice.white => 'White',
    ThemeChoice.amoled => 'AMOLED',
  };
}

/// How often booruShorts shows something outside the viewer's interests.
enum ShortsExploration { low, normal, high }

/// When the viewer loads a website's smaller sample instead of the original.
enum DataSaverMode { off, mobileData, always }

extension DataSaverModeInfo on DataSaverMode {
  String get label => switch (this) {
    DataSaverMode.off => 'Off',
    DataSaverMode.mobileData => 'On mobile data',
    DataSaverMode.always => 'Always',
  };
}

/// The hand that holds the phone in one-handed mode; the floating button
/// and the bottom action order follow it.
enum Handedness { right, left }

extension HandednessInfo on Handedness {
  String get label => switch (this) {
    Handedness.right => 'Right hand',
    Handedness.left => 'Left hand',
  };
}

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

/// API credentials, or for [BoardInfo.supportsSignIn] boards a session:
/// [userId] is the account name, [apiKey] the access token, plus an optional
/// [refreshToken] and access-token expiry.
class Credentials {
  const Credentials({
    required this.userId,
    required this.apiKey,
    this.refreshToken = '',
    this.expiresAt,
  });
  final String userId;
  final String apiKey;
  final String refreshToken;
  final DateTime? expiresAt;
  bool get isValid => userId.trim().isNotEmpty && apiKey.trim().isNotEmpty;

  /// Whether the access token should be renewed before use. Unknown expiry
  /// is treated as valid; a rejected request triggers renewal instead.
  bool expiresSoon(DateTime now) =>
      expiresAt != null &&
      !now.isBefore(expiresAt!.subtract(const Duration(minutes: 5)));

  Map<String, dynamic> toMap() => {
    'userId': userId,
    'apiKey': apiKey,
    if (refreshToken.isNotEmpty) 'refreshToken': refreshToken,
    if (expiresAt != null) 'expiresAt': expiresAt!.millisecondsSinceEpoch,
  };

  factory Credentials.fromMap(Map<dynamic, dynamic> map) {
    final expiresAt = map['expiresAt'];
    return Credentials(
      userId: '${map['userId'] ?? ''}',
      apiKey: '${map['apiKey'] ?? map['accessToken'] ?? ''}',
      refreshToken: '${map['refreshToken'] ?? ''}',
      expiresAt: expiresAt is num
          ? DateTime.fromMillisecondsSinceEpoch(expiresAt.toInt())
          : null,
    );
  }
}

class MediaPost {
  const MediaPost({
    required this.id,
    this.providerId,
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
    this.md5 = '',
    this.parentId,
    this.hasChildren = false,
    this.sampleUrl = '',
    this.pools = const [],
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
    final id = _int(map['id']);
    final md5 = '${map['md5'] ?? ''}'.trim().toLowerCase();
    final parent = '${map['parentId'] ?? ''}'.trim();
    final poolsValue = map['pools'];
    return MediaPost(
      id: id,
      providerId: id > 0 ? null : _providerId(map['id']),
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
      md5: RegExp(r'^[0-9a-f]{32}$').hasMatch(md5) ? md5 : '',
      parentId: RegExp(r'^[A-Za-z0-9]{1,32}$').hasMatch(parent) && parent != '0'
          ? parent
          : null,
      hasChildren: _bool(map['hasChildren']),
      sampleUrl: '${map['sampleUrl'] ?? ''}',
      pools: poolsValue is List
          ? poolsValue
                .map((pool) => '$pool'.trim())
                .where((pool) => RegExp(r'^\d{1,12}$').hasMatch(pool))
                .toList(growable: false)
          : const [],
    );
  }

  /// Numeric provider post ID, or 0 when the provider's ID is not numeric.
  final int id;

  /// Opaque provider post ID (Sankaku uses alphanumeric IDs); null when [id]
  /// holds the provider's ID.
  final String? providerId;
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

  /// The file's MD5 hash (lowercase hex), or empty when not supplied.
  final String md5;

  /// The parent post's ID, when this post has one.
  final String? parentId;
  final bool hasChildren;

  /// A resized image for the viewer's data saver, or empty.
  final String sampleUrl;

  /// IDs of the pools this post belongs to, when the website lists them.
  final List<String> pools;

  bool get hasId => id > 0 || providerId != null;

  /// The provider's post ID as shown in links, file names, and labels.
  String get displayId => providerId ?? '$id';

  /// The file format from [extension], such as JPG or MP4; empty when the
  /// URL names none.
  String get fileType => switch (extension) {
    'jpeg' => 'JPG',
    _ => extension.toUpperCase(),
  };

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

  MediaPost withUrls({
    required String url,
    required String previewUrl,
    String? sampleUrl,
  }) => MediaPost(
    id: id,
    providerId: providerId,
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
    md5: md5,
    parentId: parentId,
    hasChildren: hasChildren,
    sampleUrl: sampleUrl ?? this.sampleUrl,
    pools: pools,
  );

  Map<String, dynamic> toMap() => {
    'id': providerId ?? id,
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
    if (md5.isNotEmpty) 'md5': md5,
    if (parentId != null) 'parentId': parentId,
    if (hasChildren) 'hasChildren': true,
    if (sampleUrl.isNotEmpty) 'sampleUrl': sampleUrl,
    if (pools.isNotEmpty) 'pools': pools,
  };

  static int _int(dynamic value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;
  static int _tier(int width, int height) =>
      width > 0 && height > 0 ? (width < height ? width : height) : height;
  static String? _providerId(dynamic value) {
    // Digit-only strings are numeric IDs (or the "0" placeholder for none).
    final text = value is String ? value.trim() : '';
    return RegExp(r'^(?=.*[A-Za-z])[A-Za-z0-9]{1,32}$').hasMatch(text)
        ? text
        : null;
  }

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

  String get identity =>
      post.hasId ? '${board.name}:id:${post.displayId}' : _urlIdentity;

  /// The identity this post had before its website reported post IDs
  /// (Danbooru before 2026-10), so earlier favorites and hidden posts still
  /// match it. Null when there is no older form.
  String? get legacyIdentity =>
      board == Board.danbooru && post.hasId ? _urlIdentity : null;

  String get _urlIdentity =>
      '${board.name}:url:${_withoutCredentials(post.url)}|preview:${_withoutCredentials(post.previewUrl)}|tags:${post.tags.join(' ')}|source:${post.source}|size:${post.width}x${post.height}|description:${post.description}';

  SavedPost authorized(Credentials? credentials) {
    if (board != Board.gelbooru ||
        credentials == null ||
        !credentials.isValid) {
      return this;
    }
    return SavedPost(
      board: board,
      post: post.withUrls(
        url: _authorizeUrl(post.url, credentials),
        previewUrl: _authorizeUrl(post.previewUrl, credentials),
        sampleUrl: _authorizeUrl(post.sampleUrl, credentials),
      ),
    );
  }

  SavedPost sanitized() => SavedPost(
    board: board,
    post: post.withUrls(
      url: _withoutCredentials(post.url),
      previewUrl: _withoutCredentials(post.previewUrl),
      sampleUrl: _withoutCredentials(post.sampleUrl),
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
}

/// A post saved to the device, for the downloaded marker and history.
class DownloadRecord {
  const DownloadRecord({
    required this.saved,
    required this.savedAt,
    this.location = '',
  });

  /// The post, without credentials.
  final SavedPost saved;
  final DateTime savedAt;

  /// The content URI the file was written to.
  final String location;

  Map<String, dynamic> toMap() => {
    ...saved.sanitized().toMap(),
    'savedAt': savedAt.millisecondsSinceEpoch,
    if (location.isNotEmpty) 'location': location,
  };

  factory DownloadRecord.fromMap(Map<dynamic, dynamic> map) => DownloadRecord(
    saved: SavedPost.fromMap(map).sanitized(),
    savedAt: DateTime.fromMillisecondsSinceEpoch(
      map['savedAt'] is num ? (map['savedAt'] as num).toInt() : 0,
    ),
    location: '${map['location'] ?? ''}',
  );
}

/// The default [AppSettings.filenameTemplate].
const defaultFilenameTemplate = '{site}_{id}';

/// The drawer order before the user changes it: [listedBoards], as a
/// constant for [AppSettings]'s default.
const _defaultBoardOrder = [
  Board.safebooru,
  Board.danbooru,
  Board.konachan,
  Board.yandere,
  Board.e926,
  Board.e621,
  Board.gelbooru,
  Board.rule34,
  Board.sankaku,
  Board.idolcomplex,
  Board.tbib,
  Board.nozomi,
  Board.sakugabooru,
  Board.xbooru,
  Board.mspabooru,
  Board.eshuushuu,
  Board.mikubooru,
  Board.nanbooru,
];

/// [bytes] as KB, MB, or GB.
String formatBytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// The name [post]'s media is saved or shared under: [template] with
/// `{site}`, `{id}`, `{md5}`, `{artist}`, `{character}`, `{copyright}`,
/// `{rating}`, `{width}`, and `{height}` filled in, made safe for a file
/// name, plus the media's extension from [url].
String mediaFileName(
  Board board,
  MediaPost post,
  String url, {
  String template = defaultFilenameTemplate,
}) {
  final path = Uri.tryParse(url)?.path ?? '';
  final extension = path.contains('.')
      ? path.split('.').last.replaceAll(RegExp('[^a-zA-Z0-9]'), '')
      : '';
  String tagOf(TagCategory category) =>
      post.tagDetails
          .where((tag) => tag.category == category)
          .map((tag) => tag.name)
          .firstOrNull ??
      '';
  final values = {
    'site': board.name,
    'id': post.hasId ? post.displayId : '',
    'md5': post.md5,
    'artist': tagOf(TagCategory.artist),
    'character': tagOf(TagCategory.character),
    'copyright': tagOf(TagCategory.copyright),
    'rating': post.rating.toLowerCase(),
    'width': post.width > 0 ? '${post.width}' : '',
    'height': post.height > 0 ? '${post.height}' : '',
  };
  String expand(String pattern) => pattern.replaceAllMapped(
    RegExp(r'\{(\w+)\}'),
    (match) => values[match[1]!.toLowerCase()] ?? match[0]!,
  );
  String clean(String value) => value
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'_{2,}'), '_')
      .replaceAll(RegExp(r'^[\s._-]+|[\s._-]+$'), '');
  var base = clean(expand(template));
  if (base.isEmpty) base = clean(expand(defaultFilenameTemplate));
  if (base.length > 150) base = base.substring(0, 150);
  return '$base.${extension.isEmpty ? 'jpg' : extension}';
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
    this.boardOrder = _defaultBoardOrder,
    this.hiddenBoards = const [],
    this.boardBlacklists = const {},
    this.boardSavedQueries = const {},
    this.globalSavedQueries = false,
    this.theme = ThemeChoice.standard,
    this.secureScreen = false,
    this.appLock = false,
    this.incognito = false,
    this.dataSaver = DataSaverMode.off,
    this.slideshowSeconds = 5,
    this.doubleTapFavorite = false,
    this.volumeKeyPaging = false,
    this.oneHanded = false,
    this.handedness = Handedness.right,
    this.classicDrawer = false,
    this.surfaceOpacity = 80,
    this.surfaceBlur = 16,
    this.panelOpacity = 80,
    this.detailsOpacity = 80,
    this.hidePanelOnScroll = true,
    this.reduceMotion = false,
    this.aiExemptBoards = const [Board.aibooru],
    this.aiNoticeShown = false,
    this.multiSearchOff = const [],
    this.filenameTemplate = defaultFilenameTemplate,
    this.autoFavoriteOnDownload = false,
    this.boardHiddenUploaders = const {},
    this.savedSearchMarks = const {},
    this.shortsTags = const [],
    this.shortsOff = const [],
    this.shortsMuted = false,
    this.shortsAutoAdvance = false,
    this.shortsPersonalized = true,
    this.shortsExploration = ShortsExploration.normal,
    this.shortsFollowing = const [],
    this.shortsAutoScrollSeconds = 0,
    this.shortsPictureInPicture = true,
    this.checkUpdates = true,
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

  /// Drawer order for websites; always a full permutation once normalized.
  final List<Board> boardOrder;

  /// Websites left out of the drawer. At least one always stays visible.
  final List<Board> hiddenBoards;

  /// Websites shown in the drawer, in the user's order.
  List<Board> get visibleBoards => boardOrder
      .where((board) => !board.isRetired && !hiddenBoards.contains(board))
      .toList();

  /// Blocked tags that apply to one website only; [blacklist] applies to
  /// every website.
  final Map<Board, List<String>> boardBlacklists;

  /// Bookmarked searches per website, used unless [globalSavedQueries] is
  /// on. [savedQueries] holds the searches shared by every website.
  final Map<Board, List<List<String>>> boardSavedQueries;
  final bool globalSavedQueries;

  /// The palette: default dark, white, or pure black (AMOLED).
  final ThemeChoice theme;

  /// Hides the app's content from the recent-apps screen and screenshots.
  final bool secureScreen;

  /// Asks for the device's screen lock (or biometrics) when the app opens or
  /// returns from the background.
  final bool appLock;

  /// Pauses recent searches and searched/browsed tag counts.
  final bool incognito;

  /// When the viewer shows the website's smaller sample image instead of
  /// the original. Downloads always save the original.
  final DataSaverMode dataSaver;

  /// Seconds each image stays on screen during a slideshow.
  final int slideshowSeconds;

  /// Double-tapping an image in the viewer favorites it instead of zooming.
  final bool doubleTapFavorite;

  /// The volume keys move between posts in the viewer.
  final bool volumeKeyPaging;

  /// Search, filters, and feed actions sit at the bottom of the screen
  /// within thumb reach.
  final bool oneHanded;

  /// The hand used in [oneHanded] mode.
  final Handedness handedness;

  /// The navigation drawer uses its original layout: a long list of
  /// entries above a short website list.
  final bool classicDrawer;

  /// Opacity (percent) of the drawer's frosted website list. The one-handed
  /// panel and the viewer's details have their own [panelOpacity] and
  /// [detailsOpacity].
  final int surfaceOpacity;

  /// Blur strength behind the frosted surfaces; 0 turns blurring off.
  final int surfaceBlur;

  /// Opacity (percent) of the one-handed bottom panel.
  final int panelOpacity;

  /// Opacity (percent) of the viewer's details panel.
  final int detailsOpacity;

  /// In [oneHanded] mode, the bottom panel slides away while the feed is
  /// scrolled down and returns when it is scrolled up.
  final bool hidePanelOnScroll;

  /// Skips the splash animation and turns off the blur behind frosted
  /// surfaces, for slower phones.
  final bool reduceMotion;

  /// Websites where [excludeAi] does not apply, in enum order. AIBooru,
  /// which only hosts AI-generated posts, is listed by default.
  final List<Board> aiExemptBoards;

  /// Whether the notice that an AI-only website ignores [excludeAi] was
  /// already shown, so it appears once rather than on every start.
  final bool aiNoticeShown;

  /// Websites switched off in Search all sites, in enum order, kept so the
  /// next search starts with the same choice. Websites not listed (such as
  /// one signed in to later) start switched on.
  final List<Board> multiSearchOff;

  /// Whether [excludeAi] applies on [board].
  bool excludesAiOn(Board? board) =>
      excludeAi && (board == null || !aiExemptBoards.contains(board));

  /// Download file name pattern; see [mediaFileName].
  final String filenameTemplate;

  /// Downloading a post also adds it to favorites.
  final bool autoFavoriteOnDownload;

  /// Uploaders whose posts are hidden, per website (lowercase names).
  final Map<Board, List<String>> boardHiddenUploaders;

  /// The highest post ID seen per saved search, keyed by
  /// [savedSearchKey], for the new-posts count.
  final Map<String, int> savedSearchMarks;

  /// booruShorts shows videos with any of these tags (all videos when
  /// empty).
  final List<String> shortsTags;

  /// Websites switched off in booruShorts, in enum order.
  final List<Board> shortsOff;

  /// booruShorts plays without sound.
  final bool shortsMuted;

  /// booruShorts moves to the next video when one ends instead of looping.
  final bool shortsAutoAdvance;

  /// booruShorts learns from likes, dislikes, and watch time, and orders
  /// videos by the viewer's interests.
  final bool shortsPersonalized;
  final ShortsExploration shortsExploration;

  /// Tags followed in booruShorts' Following tab (artists, characters).
  final List<String> shortsFollowing;

  /// The longest a video plays during auto-scroll, in seconds; 0 plays it
  /// to the end.
  final int shortsAutoScrollSeconds;
  static const shortsAutoScrollChoices = [0, 10, 15, 30, 60];

  /// booruShorts shrinks into picture-in-picture when leaving the app
  /// while a video plays.
  final bool shortsPictureInPicture;

  /// The app looks for a newer release when it starts and offers to
  /// install it.
  final bool checkUpdates;

  /// The [savedSearchMarks] key for [query] on [board].
  static String savedSearchKey(Board board, List<String> query) =>
      '${board.name}|${_normalizedTags(query).join(' ')}';

  /// Whether [uploader] is hidden on [board].
  bool hidesUploader(Board? board, String uploader) {
    if (board == null) return false;
    final name = _normalizeTag(uploader);
    return name.isNotEmpty &&
        (boardHiddenUploaders[board]?.contains(name) ?? false);
  }

  /// Every tag blocked on [board]: the shared list, then its own.
  List<String> blacklistFor(Board? board) {
    final own = board == null ? null : boardBlacklists[board];
    if (own == null || own.isEmpty) return blacklist;
    return _normalizedTags([...blacklist, ...own]);
  }

  /// The bookmarked searches shown on [board].
  List<List<String>> savedQueriesFor(Board? board) =>
      globalSavedQueries || board == null
      ? savedQueries
      : boardSavedQueries[board] ?? const [];

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
    boardOrder: _normalizedBoardOrder(boardOrder),
    hiddenBoards: _normalizedHiddenBoards(hiddenBoards),
    boardBlacklists: _normalizedBoardTags(boardBlacklists),
    boardSavedQueries: _normalizedBoardQueries(boardSavedQueries),
    globalSavedQueries: globalSavedQueries,
    theme: theme,
    secureScreen: secureScreen,
    appLock: appLock,
    incognito: incognito,
    dataSaver: dataSaver,
    slideshowSeconds: slideshowSeconds.clamp(2, 60),
    doubleTapFavorite: doubleTapFavorite,
    volumeKeyPaging: volumeKeyPaging,
    oneHanded: oneHanded,
    handedness: handedness,
    classicDrawer: classicDrawer,
    surfaceOpacity: surfaceOpacity.clamp(20, 100),
    surfaceBlur: surfaceBlur.clamp(0, 30),
    panelOpacity: panelOpacity.clamp(20, 100),
    detailsOpacity: detailsOpacity.clamp(20, 100),
    hidePanelOnScroll: hidePanelOnScroll,
    reduceMotion: reduceMotion,
    aiExemptBoards: List.unmodifiable(
      Board.values.where(aiExemptBoards.toSet().contains),
    ),
    aiNoticeShown: aiNoticeShown,
    multiSearchOff: List.unmodifiable(
      Board.values.where(multiSearchOff.toSet().contains),
    ),
    filenameTemplate: filenameTemplate.trim().isEmpty
        ? defaultFilenameTemplate
        : filenameTemplate.trim().length > 120
        ? filenameTemplate.trim().substring(0, 120)
        : filenameTemplate.trim(),
    autoFavoriteOnDownload: autoFavoriteOnDownload,
    boardHiddenUploaders: _normalizedBoardTags(boardHiddenUploaders),
    savedSearchMarks: _normalizedMarks(savedSearchMarks),
    shortsTags: List.unmodifiable(_normalizedTags(shortsTags).take(20)),
    shortsOff: List.unmodifiable(
      Board.values.where(shortsOff.toSet().contains),
    ),
    shortsMuted: shortsMuted,
    shortsAutoAdvance: shortsAutoAdvance,
    shortsPersonalized: shortsPersonalized,
    shortsExploration: shortsExploration,
    shortsFollowing: List.unmodifiable(
      _normalizedTags(shortsFollowing).take(50),
    ),
    shortsAutoScrollSeconds:
        shortsAutoScrollChoices.contains(shortsAutoScrollSeconds)
        ? shortsAutoScrollSeconds
        : 0,
    shortsPictureInPicture: shortsPictureInPicture,
    checkUpdates: checkUpdates,
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
    List<Board>? boardOrder,
    List<Board>? hiddenBoards,
    Map<Board, List<String>>? boardBlacklists,
    Map<Board, List<List<String>>>? boardSavedQueries,
    bool? globalSavedQueries,
    ThemeChoice? theme,
    bool? secureScreen,
    bool? appLock,
    bool? incognito,
    DataSaverMode? dataSaver,
    int? slideshowSeconds,
    bool? doubleTapFavorite,
    bool? volumeKeyPaging,
    bool? oneHanded,
    Handedness? handedness,
    bool? classicDrawer,
    int? surfaceOpacity,
    int? surfaceBlur,
    int? panelOpacity,
    int? detailsOpacity,
    bool? hidePanelOnScroll,
    bool? reduceMotion,
    List<Board>? aiExemptBoards,
    bool? aiNoticeShown,
    List<Board>? multiSearchOff,
    String? filenameTemplate,
    bool? autoFavoriteOnDownload,
    Map<Board, List<String>>? boardHiddenUploaders,
    Map<String, int>? savedSearchMarks,
    List<String>? shortsTags,
    List<Board>? shortsOff,
    bool? shortsMuted,
    bool? shortsAutoAdvance,
    bool? shortsPersonalized,
    ShortsExploration? shortsExploration,
    List<String>? shortsFollowing,
    int? shortsAutoScrollSeconds,
    bool? shortsPictureInPicture,
    bool? checkUpdates,
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
    boardOrder: boardOrder ?? this.boardOrder,
    hiddenBoards: hiddenBoards ?? this.hiddenBoards,
    boardBlacklists: boardBlacklists ?? this.boardBlacklists,
    boardSavedQueries: boardSavedQueries ?? this.boardSavedQueries,
    globalSavedQueries: globalSavedQueries ?? this.globalSavedQueries,
    theme: theme ?? this.theme,
    secureScreen: secureScreen ?? this.secureScreen,
    appLock: appLock ?? this.appLock,
    incognito: incognito ?? this.incognito,
    dataSaver: dataSaver ?? this.dataSaver,
    slideshowSeconds: slideshowSeconds ?? this.slideshowSeconds,
    doubleTapFavorite: doubleTapFavorite ?? this.doubleTapFavorite,
    volumeKeyPaging: volumeKeyPaging ?? this.volumeKeyPaging,
    oneHanded: oneHanded ?? this.oneHanded,
    handedness: handedness ?? this.handedness,
    classicDrawer: classicDrawer ?? this.classicDrawer,
    surfaceOpacity: surfaceOpacity ?? this.surfaceOpacity,
    surfaceBlur: surfaceBlur ?? this.surfaceBlur,
    panelOpacity: panelOpacity ?? this.panelOpacity,
    detailsOpacity: detailsOpacity ?? this.detailsOpacity,
    hidePanelOnScroll: hidePanelOnScroll ?? this.hidePanelOnScroll,
    reduceMotion: reduceMotion ?? this.reduceMotion,
    aiExemptBoards: aiExemptBoards ?? this.aiExemptBoards,
    aiNoticeShown: aiNoticeShown ?? this.aiNoticeShown,
    multiSearchOff: multiSearchOff ?? this.multiSearchOff,
    filenameTemplate: filenameTemplate ?? this.filenameTemplate,
    autoFavoriteOnDownload:
        autoFavoriteOnDownload ?? this.autoFavoriteOnDownload,
    boardHiddenUploaders: boardHiddenUploaders ?? this.boardHiddenUploaders,
    savedSearchMarks: savedSearchMarks ?? this.savedSearchMarks,
    shortsTags: shortsTags ?? this.shortsTags,
    shortsOff: shortsOff ?? this.shortsOff,
    shortsMuted: shortsMuted ?? this.shortsMuted,
    shortsAutoAdvance: shortsAutoAdvance ?? this.shortsAutoAdvance,
    shortsPersonalized: shortsPersonalized ?? this.shortsPersonalized,
    shortsExploration: shortsExploration ?? this.shortsExploration,
    shortsFollowing: shortsFollowing ?? this.shortsFollowing,
    shortsAutoScrollSeconds:
        shortsAutoScrollSeconds ?? this.shortsAutoScrollSeconds,
    shortsPictureInPicture:
        shortsPictureInPicture ?? this.shortsPictureInPicture,
    checkUpdates: checkUpdates ?? this.checkUpdates,
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
    'boardOrder': boardOrder.map((board) => board.name).toList(),
    'hiddenBoards': hiddenBoards.map((board) => board.name).toList(),
    'boardBlacklists': {
      for (final entry in boardBlacklists.entries) entry.key.name: entry.value,
    },
    'boardSavedQueries': {
      for (final entry in boardSavedQueries.entries)
        entry.key.name: entry.value,
    },
    'globalSavedQueries': globalSavedQueries,
    'theme': theme.name,
    'secureScreen': secureScreen,
    'appLock': appLock,
    'incognito': incognito,
    'dataSaver': dataSaver.name,
    'slideshowSeconds': slideshowSeconds,
    'doubleTapFavorite': doubleTapFavorite,
    'volumeKeyPaging': volumeKeyPaging,
    'oneHanded': oneHanded,
    'handedness': handedness.name,
    'classicDrawer': classicDrawer,
    'surfaceOpacity': surfaceOpacity,
    'surfaceBlur': surfaceBlur,
    'panelOpacity': panelOpacity,
    'detailsOpacity': detailsOpacity,
    'hidePanelOnScroll': hidePanelOnScroll,
    'reduceMotion': reduceMotion,
    'aiExemptBoards': aiExemptBoards.map((board) => board.name).toList(),
    'aiNoticeShown': aiNoticeShown,
    'multiSearchOff': multiSearchOff.map((board) => board.name).toList(),
    'filenameTemplate': filenameTemplate,
    'autoFavoriteOnDownload': autoFavoriteOnDownload,
    'boardHiddenUploaders': {
      for (final entry in boardHiddenUploaders.entries)
        entry.key.name: entry.value,
    },
    'savedSearchMarks': savedSearchMarks,
    'shortsTags': shortsTags,
    'shortsOff': shortsOff.map((board) => board.name).toList(),
    'shortsMuted': shortsMuted,
    'shortsAutoAdvance': shortsAutoAdvance,
    'shortsPersonalized': shortsPersonalized,
    'shortsExploration': shortsExploration.name,
    'shortsFollowing': shortsFollowing,
    'shortsAutoScrollSeconds': shortsAutoScrollSeconds,
    'shortsPictureInPicture': shortsPictureInPicture,
    'checkUpdates': checkUpdates,
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
    boardOrder: _boardsFromMap(map['boardOrder']),
    hiddenBoards: _boardsFromMap(map['hiddenBoards']),
    boardBlacklists: _boardMapFrom(
      map['boardBlacklists'],
      (value) => value is List ? value.map((tag) => '$tag').toList() : null,
    ),
    boardSavedQueries: _boardMapFrom(
      map['boardSavedQueries'],
      (value) => value is List ? _queriesFromMap(value) : null,
    ),
    globalSavedQueries: _asBool(map['globalSavedQueries'], false),
    // Settings saved before the theme choice stored an AMOLED switch.
    theme:
        ThemeChoice.values.asNameMap()['${map['theme']}'] ??
        (_asBool(map['amoledTheme'], false)
            ? ThemeChoice.amoled
            : ThemeChoice.standard),
    secureScreen: _asBool(map['secureScreen'], false),
    appLock: _asBool(map['appLock'], false),
    incognito: _asBool(map['incognito'], false),
    dataSaver:
        DataSaverMode.values.asNameMap()['${map['dataSaver']}'] ??
        DataSaverMode.off,
    slideshowSeconds: _asInt(map['slideshowSeconds'], 5),
    doubleTapFavorite: _asBool(map['doubleTapFavorite'], false),
    volumeKeyPaging: _asBool(map['volumeKeyPaging'], false),
    oneHanded: _asBool(map['oneHanded'], false),
    handedness:
        Handedness.values.asNameMap()['${map['handedness']}'] ??
        Handedness.right,
    classicDrawer: _asBool(map['classicDrawer'], false),
    surfaceOpacity: _asInt(map['surfaceOpacity'], 80),
    surfaceBlur: _asInt(map['surfaceBlur'], 16),
    // Settings saved before the separate opacities used the shared one.
    panelOpacity: _asInt(map['panelOpacity'] ?? map['surfaceOpacity'], 80),
    detailsOpacity: _asInt(map['detailsOpacity'] ?? map['surfaceOpacity'], 80),
    hidePanelOnScroll: _asBool(map['hidePanelOnScroll'], true),
    reduceMotion: _asBool(map['reduceMotion'], false),
    aiExemptBoards: map['aiExemptBoards'] is List
        ? _boardsFromMap(map['aiExemptBoards'])
        : const [Board.aibooru],
    aiNoticeShown: _asBool(map['aiNoticeShown'], false),
    multiSearchOff: _boardsFromMap(map['multiSearchOff']),
    filenameTemplate: map['filenameTemplate'] is String
        ? map['filenameTemplate'] as String
        : defaultFilenameTemplate,
    autoFavoriteOnDownload: _asBool(map['autoFavoriteOnDownload'], false),
    boardHiddenUploaders: _boardMapFrom(
      map['boardHiddenUploaders'],
      (value) => value is List ? value.map((name) => '$name').toList() : null,
    ),
    savedSearchMarks: _countsFromMap(map['savedSearchMarks']),
    shortsTags: (map['shortsTags'] as List? ?? const [])
        .map((tag) => '$tag')
        .toList(),
    shortsOff: _boardsFromMap(map['shortsOff']),
    shortsMuted: _asBool(map['shortsMuted'], false),
    shortsAutoAdvance: _asBool(map['shortsAutoAdvance'], false),
    shortsPersonalized: _asBool(map['shortsPersonalized'], true),
    shortsExploration:
        ShortsExploration.values.asNameMap()['${map['shortsExploration']}'] ??
        ShortsExploration.normal,
    shortsFollowing: (map['shortsFollowing'] as List? ?? const [])
        .map((tag) => '$tag')
        .toList(),
    shortsAutoScrollSeconds: _asInt(map['shortsAutoScrollSeconds'], 0),
    shortsPictureInPicture: _asBool(map['shortsPictureInPicture'], true),
    checkUpdates: _asBool(map['checkUpdates'], true),
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

  static Map<Board, T> _boardMapFrom<T>(
    dynamic value,
    T? Function(dynamic) parse,
  ) {
    if (value is! Map) return const {};
    final byName = Board.values.asNameMap();
    final result = <Board, T>{};
    for (final entry in value.entries) {
      final board = byName['${entry.key}'];
      final parsed = parse(entry.value);
      if (board != null && parsed != null) result[board] = parsed;
    }
    return result;
  }

  static Map<Board, List<String>> _normalizedBoardTags(
    Map<Board, List<String>> values,
  ) {
    final result = <Board, List<String>>{};
    for (final board in Board.values) {
      final tags = _normalizedTags(values[board] ?? const []);
      if (tags.isNotEmpty) result[board] = tags;
    }
    return Map.unmodifiable(result);
  }

  static Map<Board, List<List<String>>> _normalizedBoardQueries(
    Map<Board, List<List<String>>> values,
  ) {
    final result = <Board, List<List<String>>>{};
    for (final board in Board.values) {
      final queries = _normalizedQueries(values[board] ?? const []);
      if (queries.isNotEmpty) result[board] = queries;
    }
    return Map.unmodifiable(result);
  }

  static List<Board> _boardsFromMap(dynamic value) {
    if (value is! List) return const [];
    final byName = Board.values.asNameMap();
    return value.map((name) => byName['$name']).whereType<Board>().toList();
  }

  // Unknown or missing boards (e.g. ones added in a later version) are
  // appended in their default position order; retired boards are dropped.
  static List<Board> _normalizedBoardOrder(Iterable<Board> values) {
    final result = <Board>{...values, ...listedBoards};
    return List.unmodifiable(result.where((board) => !board.isRetired));
  }

  static List<Board> _normalizedHiddenBoards(Iterable<Board> values) {
    final hidden = values.toSet();
    if (listedBoards.every(hidden.contains)) return const [];
    return List.unmodifiable(listedBoards.where(hidden.contains));
  }

  static List<Rating> _normalizedRatings(Iterable<Rating> values) =>
      List.unmodifiable(Rating.values.where(values.toSet().contains));

  static Map<String, int> _countsFromMap(dynamic value) => value is Map
      ? value.map((key, count) => MapEntry('$key', _asInt(count, 0)))
      : const {};

  // Keys keep their case-sensitive board prefix; only the newest 200 stay.
  static Map<String, int> _normalizedMarks(Map<String, int> values) {
    final entries = values.entries
        .where((entry) => entry.key.contains('|') && entry.value > 0)
        .toList();
    final kept = entries.length > 200
        ? entries.sublist(entries.length - 200)
        : entries;
    return Map.unmodifiable(Map.fromEntries(kept));
  }

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
        !_sameBoards(other.boardOrder, boardOrder) ||
        !_sameBoards(other.hiddenBoards, hiddenBoards) ||
        other.globalSavedQueries != globalSavedQueries ||
        other.theme != theme ||
        other.secureScreen != secureScreen ||
        other.appLock != appLock ||
        other.incognito != incognito ||
        other.dataSaver != dataSaver ||
        other.slideshowSeconds != slideshowSeconds ||
        other.doubleTapFavorite != doubleTapFavorite ||
        other.volumeKeyPaging != volumeKeyPaging ||
        other.oneHanded != oneHanded ||
        other.handedness != handedness ||
        other.classicDrawer != classicDrawer ||
        other.surfaceOpacity != surfaceOpacity ||
        other.surfaceBlur != surfaceBlur ||
        other.panelOpacity != panelOpacity ||
        other.detailsOpacity != detailsOpacity ||
        other.hidePanelOnScroll != hidePanelOnScroll ||
        other.reduceMotion != reduceMotion ||
        !_sameBoards(other.aiExemptBoards, aiExemptBoards) ||
        other.aiNoticeShown != aiNoticeShown ||
        !_sameBoards(other.multiSearchOff, multiSearchOff) ||
        other.filenameTemplate != filenameTemplate ||
        other.autoFavoriteOnDownload != autoFavoriteOnDownload ||
        !_sameBoardTags(other.boardHiddenUploaders, boardHiddenUploaders) ||
        !_sameCounts(other.savedSearchMarks, savedSearchMarks) ||
        !_sameTags(other.shortsTags, shortsTags) ||
        !_sameBoards(other.shortsOff, shortsOff) ||
        other.shortsMuted != shortsMuted ||
        other.shortsAutoAdvance != shortsAutoAdvance ||
        other.shortsPersonalized != shortsPersonalized ||
        other.shortsExploration != shortsExploration ||
        !_sameTags(other.shortsFollowing, shortsFollowing) ||
        other.shortsAutoScrollSeconds != shortsAutoScrollSeconds ||
        other.shortsPictureInPicture != shortsPictureInPicture ||
        other.checkUpdates != checkUpdates ||
        !_sameBoardTags(other.boardBlacklists, boardBlacklists) ||
        !_sameBoardQueries(other.boardSavedQueries, boardSavedQueries) ||
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
    return _sameQueries(savedQueries, other.savedQueries) &&
        _sameQueries(recentSearches, other.recentSearches);
  }

  static bool _sameTags(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameQueries(List<List<String>> a, List<List<String>> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameTags(a[i], b[i])) return false;
    }
    return true;
  }

  static bool _sameBoardTags(
    Map<Board, List<String>> a,
    Map<Board, List<String>> b,
  ) =>
      a.length == b.length &&
      a.entries.every((entry) {
        final other = b[entry.key];
        return other != null && _sameTags(entry.value, other);
      });

  static bool _sameBoardQueries(
    Map<Board, List<List<String>>> a,
    Map<Board, List<List<String>>> b,
  ) =>
      a.length == b.length &&
      a.entries.every((entry) {
        final other = b[entry.key];
        return other != null && _sameQueries(entry.value, other);
      });

  @override
  int get hashCode => Object.hashAll([
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
    Object.hashAll(boardOrder),
    Object.hashAll(hiddenBoards),
    globalSavedQueries,
    theme,
    secureScreen,
    appLock,
    incognito,
    dataSaver,
    slideshowSeconds,
    doubleTapFavorite,
    volumeKeyPaging,
    oneHanded,
    handedness,
    classicDrawer,
    surfaceOpacity,
    surfaceBlur,
    panelOpacity,
    detailsOpacity,
    hidePanelOnScroll,
    reduceMotion,
    Object.hashAll(aiExemptBoards),
    aiNoticeShown,
    Object.hashAll(multiSearchOff),
    filenameTemplate,
    autoFavoriteOnDownload,
    _countsHash(savedSearchMarks),
    Object.hashAll(shortsTags),
    Object.hashAll(shortsOff),
    shortsMuted,
    shortsAutoAdvance,
    shortsPersonalized,
    shortsExploration,
    Object.hashAll(shortsFollowing),
    shortsAutoScrollSeconds,
    shortsPictureInPicture,
    checkUpdates,
    Object.hashAll(
      boardHiddenUploaders.entries.map(
        (entry) => Object.hash(entry.key, Object.hashAll(entry.value)),
      ),
    ),
    Object.hashAll(
      boardBlacklists.entries.map(
        (entry) => Object.hash(entry.key, Object.hashAll(entry.value)),
      ),
    ),
    Object.hashAll(
      boardSavedQueries.entries.map(
        (entry) => Object.hash(
          entry.key,
          Object.hashAll(entry.value.map(Object.hashAll)),
        ),
      ),
    ),
  ]);

  static bool _sameBoards(List<Board> a, List<Board> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

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
