import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

abstract interface class BoardRepository {
  /// A [feed] request is the visible feed's page: a newer feed request
  /// cancels it natively, failing it with [RequestCancelledException].
  Future<List<Map<String, dynamic>>> fetch({
    required Board board,
    required List<String> tags,
    required int limit,
    required int page,
    required bool random,
    int? randomSeed,
    Credentials? credentials,
    bool feed = false,
  });

  Future<List<Map<String, dynamic>>> autocomplete({
    required Board board,
    required String query,
    required int limit,
    Credentials? credentials,
  });
}

/// Optional password sign-in for [BoardInfo.supportsSignIn] boards.
abstract interface class AccountRepository {
  /// Exchanges [password] for a session. Throws [SignInRejectedException]
  /// for a refused login.
  Future<Credentials> signIn({
    required Board board,
    required String login,
    required String password,
  });

  /// Renews [credentials]. Throws [SignInRejectedException] when the session
  /// can no longer be renewed.
  Future<Credentials> refreshSignIn({
    required Board board,
    required Credentials credentials,
  });
}

/// The provider refused a password or refresh token.
class SignInRejectedException implements Exception {
  const SignInRejectedException();
}

/// The provider refused the session's access token.
class AuthExpiredException implements Exception {
  const AuthExpiredException();
}

/// The search used more counted tags than the provider allows.
class TagLimitException implements Exception {
  const TagLimitException(this.limit);
  final int? limit;
}

/// The provider kept refusing requests as too frequent (HTTP 429/503) after
/// the native backoff. [retryAfter] is its suggested wait, when known.
class RateLimitedException implements Exception {
  const RateLimitedException([this.retryAfter]);
  final Duration? retryAfter;
}

/// The request was cancelled natively, because a newer feed request
/// superseded it or the activity closed. Nothing waits on its result.
class RequestCancelledException implements Exception {
  const RequestCancelledException();
}

/// Maps the bridge's auth, tag-limit, rate-limit, and cancellation codes to
/// typed exceptions.
Object _platformError(Object error) {
  if (error is! PlatformException) return error;
  return switch (error.code) {
    'CANCELLED' => const RequestCancelledException(),
    'AUTH_REJECTED' => const SignInRejectedException(),
    'AUTH_EXPIRED' => const AuthExpiredException(),
    'TAG_LIMIT' => TagLimitException(switch (error.details) {
      {'limit': final num limit} => limit.toInt(),
      _ => null,
    }),
    'RATE_LIMITED' => RateLimitedException(switch (error.details) {
      {'retryAfter': final num seconds} => Duration(seconds: seconds.toInt()),
      _ => null,
    }),
    _ => error,
  };
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

  MediaPost _sanitizePost(MediaPost value) => value.withUrls(
    url: _sanitizeUrl(value.url),
    previewUrl: _sanitizeUrl(value.previewUrl),
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
    bool feed = false,
  }) async {
    final List<dynamic>? response;
    try {
      response = await channel.invokeMethod<List<dynamic>>('fetch', {
        'board': board.name,
        'tags': tags,
        'limit': limit,
        'page': page,
        'random': random,
        'randomSeed': randomSeed,
        'apiKey': credentials?.apiKey,
        'userId': credentials?.userId,
        if (feed) 'feed': true,
      });
    } catch (error) {
      throw _platformError(error);
    }
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
    final List<dynamic>? response;
    try {
      response = await channel.invokeMethod<List<dynamic>>('autocomplete', {
        'board': board.name,
        'query': query,
        'limit': limit,
        'apiKey': credentials?.apiKey,
        'userId': credentials?.userId,
      });
    } catch (error) {
      throw _platformError(error);
    }
    return (response ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }
}

class PlatformAccountRepository implements AccountRepository {
  PlatformAccountRepository({MethodChannel? channel})
    : channel = channel ?? const MethodChannel('booruplus/platform');
  final MethodChannel channel;

  @override
  Future<Credentials> signIn({
    required Board board,
    required String login,
    required String password,
  }) => _session('signIn', {
    'board': board.name,
    'login': login,
    'password': password,
  });

  @override
  Future<Credentials> refreshSignIn({
    required Board board,
    required Credentials credentials,
  }) => _session('refreshSignIn', {
    'board': board.name,
    'userId': credentials.userId,
    'refreshToken': credentials.refreshToken,
  });

  Future<Credentials> _session(String method, Map<String, Object?> args) async {
    final Map<dynamic, dynamic>? response;
    try {
      response = await channel.invokeMethod<Map<dynamic, dynamic>>(
        method,
        args,
      );
    } catch (error) {
      throw _platformError(error);
    }
    final credentials = Credentials.fromMap(response ?? const {});
    if (!credentials.isValid) throw const SignInRejectedException();
    return credentials;
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
    return Credentials.fromMap(jsonDecode(encoded) as Map);
  }

  @override
  Future<void> saveCredentials(Board board, Credentials c) =>
      _secure.write(key: _key(board), value: jsonEncode(c.toMap()));
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

  // Shared by every tile: rebuilding or scrolling back over a grid reuses
  // in-flight and recent bytes instead of re-requesting the provider, which
  // would otherwise throttle the account. Settled responses are kept within
  // a small byte budget; failures are dropped so they can be retried.
  static final _recent = <String, Future<Uint8List>>{};
  static final _recentBytes = <String, int>{};
  static const _maxRecentEntries = 200;
  static const _maxRecentBytes = 24 << 20;
  static const _maxEntryBytes = 2 << 20;

  Future<Uint8List> fetchMedia({
    required Board board,
    required String url,
    Credentials? credentials,
  }) {
    final key = '${channel.name}\u0000${board.name}\u0000$url';
    final cached = _recent.remove(key);
    if (cached != null) return _recent[key] = cached;
    final future = _fetchMedia(
      board: board,
      url: url,
      credentials: credentials,
    );
    _recent[key] = future;
    future.then(
      (bytes) {
        if (!identical(_recent[key], future)) return;
        if (bytes.length > _maxEntryBytes) {
          _recent.remove(key);
        } else {
          _recentBytes[key] = bytes.length;
        }
        _trimRecent();
      },
      onError: (Object _) {
        if (identical(_recent[key], future)) _recent.remove(key);
      },
    );
    _trimRecent();
    return future;
  }

  static void _trimRecent() {
    _recentBytes.removeWhere((key, _) => !_recent.containsKey(key));
    var total = _recentBytes.values.fold(0, (sum, size) => sum + size);
    while (_recent.length > _maxRecentEntries || total > _maxRecentBytes) {
      final oldest = _recent.keys.first;
      _recent.remove(oldest);
      total -= _recentBytes.remove(oldest) ?? 0;
    }
  }

  Future<Uint8List> _fetchMedia({
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
