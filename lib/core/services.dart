import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

abstract interface class BoardRepository {
  Future<List<Map<String, dynamic>>> fetch({
    required Board board,
    required List<String> tags,
    required int limit,
    required int page,
    required bool random,
    int? randomSeed,
    Credentials? credentials,
  });

  Future<List<Map<String, dynamic>>> autocomplete({
    required Board board,
    required String query,
    required int limit,
    Credentials? credentials,
  });
}

abstract interface class SettingsStore {
  Future<AppSettings> loadSettings();
  Future<void> saveSettings(AppSettings settings);
  Future<Board?> loadBoard();
  Future<void> saveBoard(Board? board);
  Future<Credentials?> loadCredentials(Board board);
  Future<void> saveCredentials(Board board, Credentials credentials);
  Future<void> removeCredentials(Board board);
}

abstract interface class PostStore {
  Future<List<SavedPost>> loadFavorites();
  Future<List<SavedPost>> loadHidden();
  Future<void> saveFavorites(Iterable<SavedPost> posts);
  Future<void> saveHidden(Iterable<SavedPost> posts);
}

class MemoryPostStore implements PostStore {
  List<SavedPost> _favorites = const [];
  List<SavedPost> _hidden = const [];
  @override
  Future<List<SavedPost>> loadFavorites() async => _favorites;
  @override
  Future<List<SavedPost>> loadHidden() async => _hidden;
  @override
  Future<void> saveFavorites(Iterable<SavedPost> posts) async =>
      _favorites = List.unmodifiable(posts);
  @override
  Future<void> saveHidden(Iterable<SavedPost> posts) async =>
      _hidden = List.unmodifiable(posts);
}

class LocalPostStore implements PostStore {
  LocalPostStore({SharedPreferences? preferences}) {
    _preferences = preferences;
  }
  SharedPreferences? _preferences;
  Future<SharedPreferences> get prefs async =>
      _preferences ??= await SharedPreferences.getInstance();

  @override
  Future<List<SavedPost>> loadFavorites() => _load('favorites');
  @override
  Future<List<SavedPost>> loadHidden() => _load('hidden');
  Future<List<SavedPost>> _load(String name) async {
    final values = (await prefs).getStringList('posts.$name') ?? const [];
    return values
        .map((value) {
          try {
            return SavedPost.fromMap(jsonDecode(value) as Map);
          } catch (_) {
            return null;
          }
        })
        .whereType<SavedPost>()
        .toList(growable: false);
  }

  @override
  Future<void> saveFavorites(Iterable<SavedPost> posts) =>
      _save('favorites', posts);
  @override
  Future<void> saveHidden(Iterable<SavedPost> posts) => _save('hidden', posts);
  Future<void> _save(String name, Iterable<SavedPost> posts) async {
    final values = posts
        .map((saved) => jsonEncode(_sanitized(saved).toMap()))
        .toList(growable: false);
    await (await prefs).setStringList('posts.$name', values);
  }

  SavedPost _sanitized(SavedPost value) =>
      SavedPost(board: value.board, post: _sanitizePost(value.post));

  MediaPost _sanitizePost(MediaPost value) => MediaPost(
    id: value.id,
    url: _sanitizeUrl(value.url),
    previewUrl: _sanitizeUrl(value.previewUrl),
    tags: value.tags,
    rating: value.rating,
    uploader: value.uploader,
    source: value.source,
    width: value.width,
    height: value.height,
    score: value.score,
    description: value.description,
    isVideo: value.isVideo,
    extension: value.extension,
    tagDetails: value.tagDetails,
    postUrl: value.postUrl,
  );

  static String _sanitizeUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return value;
    final query = Map<String, String>.from(uri.queryParameters)
      ..remove('api_key')
      ..remove('user_id');
    return uri.replace(queryParameters: query).toString();
  }
}

class PlatformBoardRepository implements BoardRepository {
  PlatformBoardRepository({MethodChannel? channel})
    : channel = channel ?? const MethodChannel('booruplus/platform');
  final MethodChannel channel;
  @override
  Future<List<Map<String, dynamic>>> fetch({
    required Board board,
    required List<String> tags,
    required int limit,
    required int page,
    required bool random,
    int? randomSeed,
    Credentials? credentials,
  }) async {
    final response = await channel.invokeMethod<List<dynamic>>('fetch', {
      'board': board.name,
      'tags': tags,
      'limit': limit,
      'page': page,
      'random': random,
      'randomSeed': randomSeed,
      'apiKey': credentials?.apiKey,
      'userId': credentials?.userId,
    });
    return (response ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> autocomplete({
    required Board board,
    required String query,
    required int limit,
    Credentials? credentials,
  }) async {
    final response = await channel.invokeMethod<List<dynamic>>('autocomplete', {
      'board': board.name,
      'query': query,
      'limit': limit,
      'apiKey': credentials?.apiKey,
      'userId': credentials?.userId,
    });
    return (response ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }
}

class LocalSettingsStore implements SettingsStore {
  LocalSettingsStore({
    SharedPreferences? preferences,
    FlutterSecureStorage? secureStorage,
  }) : _secure = secureStorage ?? const FlutterSecureStorage() {
    _preferences = preferences;
  }
  SharedPreferences? _preferences;
  final FlutterSecureStorage _secure;
  Future<SharedPreferences> get prefs async =>
      _preferences ??= await SharedPreferences.getInstance();
  @override
  Future<AppSettings> loadSettings() async => AppSettings.decode(
    (await prefs).getString('settings') ?? AppSettings().encode(),
  );
  @override
  Future<void> saveSettings(AppSettings settings) async =>
      (await prefs).setString('settings', settings.encode());
  @override
  Future<Board?> loadBoard() async {
    final value = (await prefs).getString('board');
    return value == null
        ? null
        : Board.values.firstWhere(
            (b) => b.name == value,
            orElse: () => Board.safebooru,
          );
  }

  @override
  Future<void> saveBoard(Board? board) async {
    final preferences = await prefs;
    if (board == null) {
      await preferences.remove('board');
    } else {
      await preferences.setString('board', board.name);
    }
  }

  String _key(Board board) => 'credential.${board.name}';
  @override
  Future<Credentials?> loadCredentials(Board board) async {
    final encoded = await _secure.read(key: _key(board));
    if (encoded == null) return null;
    final value = jsonDecode(encoded) as Map;
    return Credentials(
      userId: '${value['userId'] ?? ''}',
      apiKey: '${value['apiKey'] ?? ''}',
    );
  }

  @override
  Future<void> saveCredentials(Board board, Credentials c) => _secure.write(
    key: _key(board),
    value: jsonEncode({'userId': c.userId, 'apiKey': c.apiKey}),
  );
  @override
  Future<void> removeCredentials(Board board) =>
      _secure.delete(key: _key(board));
}

class DownloadService {
  DownloadService({MethodChannel? channel})
    : channel = channel ?? const MethodChannel('booruplus/platform');
  final MethodChannel channel;
  Future<String?> chooseDirectory() =>
      channel.invokeMethod<String?>('pickDownloadDirectory');
  Future<String> download({
    required String url,
    required String name,
    String? directory,
  }) => channel
      .invokeMethod<String>('download', {
        'url': url,
        'name': name,
        'directory': directory,
      })
      .then((v) => v ?? '');
}

class MediaService {
  MediaService({MethodChannel? channel})
    : channel = channel ?? const MethodChannel('booruplus/platform');
  final MethodChannel channel;

  Future<Uint8List> fetchMedia({
    required Board board,
    required String url,
    Credentials? credentials,
  }) async {
    final bytes = await channel.invokeMethod<Uint8List>('fetchMedia', {
      'board': board.name,
      'url': url,
      'apiKey': credentials?.apiKey,
      'userId': credentials?.userId,
    });
    if (bytes == null || bytes.isEmpty) {
      throw StateError('Media response was empty');
    }
    return bytes;
  }
}

class ScreenAwakeService {
  ScreenAwakeService({MethodChannel? channel})
    : channel = channel ?? const MethodChannel('booruplus/platform');
  final MethodChannel channel;

  Future<void> setEnabled(bool enabled) async {
    try {
      await channel.invokeMethod<void>('setKeepScreenOn', {'enabled': enabled});
    } catch (_) {
      // The Android implementation owns this capability. Keep the viewer
      // usable in widget tests and on platforms without the channel.
    }
  }
}
