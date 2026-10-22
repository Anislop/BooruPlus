import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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

/// The website answered that its API is switched off.
class ApiOffException implements Exception {
  const ApiOffException();
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
    'API_OFF' => const ApiOffException(),
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

  /// Download history, oldest first.
  Future<List<DownloadRecord>> loadDownloads();
  Future<void> saveDownloads(Iterable<DownloadRecord> records);

  /// Downloads still waiting, running, or paused, oldest first.
  Future<List<PendingDownload>> loadDownloadQueue();
  Future<void> saveDownloadQueue(Iterable<PendingDownload> downloads);

  /// The feeds to reopen after a restart, by website name; each is a
  /// JSON-safe map of sanitized posts and paging state.
  Future<Map<String, dynamic>> loadFeeds();
  Future<void> saveFeeds(Map<String, dynamic> feeds);
}

class MemoryPostStore implements PostStore {
  List<SavedPost> _favorites = const [];
  List<SavedPost> _hidden = const [];
  List<DownloadRecord> _downloads = const [];
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
  @override
  Future<List<DownloadRecord>> loadDownloads() async => _downloads;
  @override
  Future<void> saveDownloads(Iterable<DownloadRecord> records) async =>
      _downloads = List.unmodifiable(records);
  List<PendingDownload> _queue = const [];
  @override
  Future<List<PendingDownload>> loadDownloadQueue() async => _queue;
  @override
  Future<void> saveDownloadQueue(Iterable<PendingDownload> downloads) async =>
      _queue = List.unmodifiable(downloads);
  Map<String, dynamic> _feeds = const {};
  @override
  Future<Map<String, dynamic>> loadFeeds() async => _feeds;
  @override
  Future<void> saveFeeds(Map<String, dynamic> feeds) async =>
      _feeds = jsonDecode(jsonEncode(feeds)) as Map<String, dynamic>;
}

/// Where the booruShorts interest profile ([ShortsProfile.toMap]) is kept.
abstract interface class ShortsProfileStore {
  Future<Map<String, dynamic>?> load();
  Future<void> save(Map<String, dynamic> profile);
}

class MemoryShortsProfileStore implements ShortsProfileStore {
  Map<String, dynamic>? profile;
  @override
  Future<Map<String, dynamic>?> load() async => profile;
  @override
  Future<void> save(Map<String, dynamic> value) async =>
      profile = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
}

class LocalShortsProfileStore implements ShortsProfileStore {
  LocalShortsProfileStore({SharedPreferences? preferences}) {
    _preferences = preferences;
  }
  SharedPreferences? _preferences;
  Future<SharedPreferences> get prefs async =>
      _preferences ??= await SharedPreferences.getInstance();
  static const _key = 'shortsProfile.v1';

  @override
  Future<Map<String, dynamic>?> load() async {
    final value = (await prefs).getString(_key);
    if (value == null) return null;
    try {
      return jsonDecode(value) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(Map<String, dynamic> profile) async =>
      (await prefs).setString(_key, jsonEncode(profile));
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

  @override
  Future<List<DownloadRecord>> loadDownloads() async {
    final values = (await prefs).getStringList('posts.downloads') ?? const [];
    return values
        .map((value) {
          try {
            return DownloadRecord.fromMap(jsonDecode(value) as Map);
          } catch (_) {
            return null;
          }
        })
        .whereType<DownloadRecord>()
        .toList(growable: false);
  }

  @override
  Future<void> saveDownloads(Iterable<DownloadRecord> records) async {
    // DownloadRecord.toMap stores the post without credentials.
    final values = records
        .map((record) => jsonEncode(record.toMap()))
        .toList(growable: false);
    await (await prefs).setStringList('posts.downloads', values);
  }

  @override
  Future<List<PendingDownload>> loadDownloadQueue() async {
    final values = (await prefs).getStringList('posts.downloadQueue') ?? [];
    return values
        .map((value) {
          try {
            return PendingDownload.fromMap(jsonDecode(value) as Map);
          } catch (_) {
            return null;
          }
        })
        .whereType<PendingDownload>()
        .toList(growable: false);
  }

  @override
  Future<void> saveDownloadQueue(Iterable<PendingDownload> downloads) async {
    // PendingDownload.toMap stores the post without credentials.
    final values = downloads
        .map((download) => jsonEncode(download.toMap()))
        .toList(growable: false);
    await (await prefs).setStringList('posts.downloadQueue', values);
  }

  @override
  Future<Map<String, dynamic>> loadFeeds() async {
    final value = (await prefs).getString('feeds.resume');
    if (value == null) return const {};
    try {
      return jsonDecode(value) as Map<String, dynamic>;
    } catch (_) {
      return const {};
    }
  }

  @override
  Future<void> saveFeeds(Map<String, dynamic> feeds) async =>
      (await prefs).setString('feeds.resume', jsonEncode(feeds));

  SavedPost _sanitized(SavedPost value) =>
      SavedPost(board: value.board, post: _sanitizePost(value.post));

  MediaPost _sanitizePost(MediaPost value) => value.withUrls(
    url: _sanitizeUrl(value.url),
    previewUrl: _sanitizeUrl(value.previewUrl),
    sampleUrl: _sanitizeUrl(value.sampleUrl),
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

/// Bytes saved so far, and the file's size when the host reports it.
typedef DownloadProgress = void Function(int received, int? total);

/// A download was paused ([DownloadControl.pause], or the app closing). The
/// partial file stays at [partial], when one was written, for
/// [DownloadControl.resume].
class DownloadPausedException implements Exception {
  const DownloadPausedException([this.partial]);
  final String? partial;
}

/// Pauses one [DownloadService.download] and learns where it writes, so a
/// later download can continue the same file.
class DownloadControl {
  DownloadControl({this.resume, this.resumeTotal});

  /// The partial file of an earlier, paused download of the same media,
  /// and the size the website reported then. The platform appends to it
  /// only when the website reports the same size again, and rewrites it
  /// otherwise.
  final String? resume;
  final int? resumeTotal;

  /// The file this download writes, once the platform created it.
  String? target;

  /// Called once [target] is known.
  void Function(String uri)? onTarget;

  int? _id;
  MethodChannel? _channel;
  bool _paused = false;
  bool get paused => _paused;

  /// Stops the download, keeping what was saved. It then fails with
  /// [DownloadPausedException].
  Future<void> pause() async {
    if (_paused) return;
    _paused = true;
    final id = _id, channel = _channel;
    if (id == null || channel == null) return;
    try {
      await channel.invokeMethod<void>('pauseDownload', {'id': id});
    } catch (_) {
      // Without the Android host there is no transfer to stop.
    }
  }

  void _target(String uri) {
    target = uri;
    onTarget?.call(uri);
  }
}

class DownloadService {
  DownloadService({MethodChannel? channel, MethodChannel? progressChannel})
    : channel = channel ?? const MethodChannel('booruplus/platform'),
      progressChannel =
          progressChannel ?? const MethodChannel('booruplus/downloads');
  final MethodChannel channel;

  /// Native-to-Dart `progress` calls (`id`, `received`, nullable `total`)
  /// and `target` calls (`id`, `uri`).
  final MethodChannel progressChannel;

  static final _listeners = <int, DownloadProgress>{};
  static final _controls = <int, DownloadControl>{};
  static final _listening = <String>{};
  static var _nextId = 0;

  Future<String?> chooseDirectory() =>
      channel.invokeMethod<String?>('pickDownloadDirectory');

  /// Saves [url] as [name]. With [control] it can be paused, which throws
  /// [DownloadPausedException], and continue a partial file
  /// ([DownloadControl.resume]).
  Future<String> download({
    required String url,
    required String name,
    String? directory,
    DownloadProgress? onProgress,
    DownloadControl? control,
  }) async {
    if (control?.paused == true) throw DownloadPausedException(control?.resume);
    try {
      final value = await reporting(onProgress, (id) {
        if (control != null && id != null) {
          control
            .._id = id
            .._channel = channel;
          _controls[id] = control;
        }
        return channel.invokeMethod<String>('download', {
          'url': url,
          'name': name,
          'directory': directory,
          'id': ?id,
          'resume': ?control?.resume,
          'resumeTotal': ?control?.resumeTotal,
        });
      }, track: control != null);
      return value ?? '';
    } on PlatformException catch (error) {
      if (error.code != 'PAUSED') rethrow;
      final details = error.details;
      final uri = details is Map ? details['uri'] : null;
      throw DownloadPausedException(
        uri is String ? uri : control?.target ?? control?.resume,
      );
    }
  }

  /// Deletes the partial file a paused download left at [uri].
  Future<void> discard(String uri, {String? directory}) async {
    try {
      await channel.invokeMethod<Object?>('discardDownload', {
        'uri': uri,
        'directory': directory,
      });
    } catch (_) {
      // A file that cannot be removed now is left to the system.
    }
  }

  /// Keeps the app running in the foreground while downloads are [active],
  /// with a notification showing [text] and [percent] (null when unknown).
  Future<void> keepAlive({
    required bool active,
    String text = '',
    int? percent,
  }) async {
    try {
      await channel.invokeMethod<void>('setDownloadsActive', {
        'active': active,
        'text': text,
        'percent': percent ?? -1,
      });
    } catch (_) {
      // Not available in widget tests or without the Android host.
    }
  }

  /// Runs a native [request] that sends `progress` calls with the id it is
  /// given; they reach [onProgress]. The id is null without [onProgress],
  /// unless [track] asks for one.
  Future<T> reporting<T>(
    DownloadProgress? onProgress,
    Future<T> Function(int? id) request, {
    bool track = false,
  }) async {
    int? id;
    if (onProgress != null || track) {
      _listen();
      id = ++_nextId;
      if (onProgress != null) _listeners[id] = onProgress;
    }
    try {
      return await request(id);
    } finally {
      _listeners.remove(id);
      _controls.remove(id);
    }
  }

  /// The size in bytes of the media at [url], or null when the host does
  /// not report it or the request fails.
  Future<int?> mediaSize(String url) async {
    try {
      final value = await channel.invokeMethod<Object?>('mediaSize', {
        'url': url,
      });
      return value is num && value > 0 ? value.toInt() : null;
    } catch (_) {
      return null;
    }
  }

  void _listen() {
    if (!_listening.add(progressChannel.name)) return;
    progressChannel.setMethodCallHandler((call) async {
      final args = call.arguments;
      if (args is! Map) return;
      final id = args['id'];
      if (id is! num) return;
      if (call.method == 'target') {
        final uri = args['uri'];
        if (uri is String) _controls[id.toInt()]?._target(uri);
        return;
      }
      final received = args['received'], total = args['total'];
      if (call.method != 'progress' || received is! num) return;
      _listeners[id.toInt()]?.call(
        received.toInt(),
        total is num && total > 0 ? total.toInt() : null,
      );
    });
  }
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

  /// Drops every shared response, for the Settings "Clear cache" action.
  static void clearRecent() {
    _recent.clear();
    _recentBytes.clear();
  }

  /// Approximate bytes held by settled shared responses.
  static int get recentBytes =>
      _recentBytes.values.fold(0, (sum, size) => sum + size);

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

/// The device has no screen lock, so the app lock cannot verify the user.
class DeviceLockUnavailableException implements Exception {
  const DeviceLockUnavailableException();
}

/// Privacy, sharing, and backup-file capabilities of the Android host.
class DeviceService {
  DeviceService({MethodChannel? channel})
    : channel = channel ?? const MethodChannel('booruplus/platform');
  final MethodChannel channel;

  /// Whether any verification prompt is showing. The prompt sends the app to
  /// the background, which must not count as leaving it.
  static bool get authenticating => _authenticating;
  static bool _authenticating = false;

  /// Hides the window from the recent-apps screen and screenshots.
  Future<void> setSecureScreen(bool enabled) async {
    try {
      await channel.invokeMethod<void>('setSecureScreen', {'enabled': enabled});
    } catch (_) {
      // Not available in widget tests or without the Android host.
    }
  }

  /// Shows the device's biometric or screen-lock prompt. Returns false when
  /// the prompt is dismissed or cannot start; throws
  /// [DeviceLockUnavailableException] only when the device has no screen
  /// lock.
  Future<bool> authenticate({String title = 'Unlock BooruPlus'}) async {
    _authenticating = true;
    try {
      return await channel.invokeMethod<bool>('authenticate', {
            'title': title,
          }) ??
          false;
    } on PlatformException catch (error) {
      if (error.code == 'UNAVAILABLE') {
        throw const DeviceLockUnavailableException();
      }
      return false;
    } finally {
      _authenticating = false;
    }
  }

  Future<void> shareText(String text) =>
      channel.invokeMethod<void>('share', {'text': text});

  /// Downloads [url] to a private cache and opens the share sheet with it.
  Future<void> shareMedia({
    required String url,
    required String name,
    String? text,
  }) => channel.invokeMethod<void>('share', {
    'url': url,
    'name': name,
    'text': ?text,
  });

  /// Lets the user choose where to save [content] (JSON, or plain text
  /// with [text]). Returns false when the picker is cancelled.
  Future<bool> exportFile({
    required String name,
    required String content,
    bool text = false,
  }) => channel
      .invokeMethod<bool>('exportFile', {
        'name': name,
        'content': content,
        if (text) 'mimeType': 'text/plain',
      })
      .then((value) => value ?? false);

  /// Opens Android's "Set as" chooser (wallpaper, contact photo) with the
  /// image at [url].
  Future<void> setAs({required String url, required String name}) =>
      channel.invokeMethod<void>('setAs', {'url': url, 'name': name});

  /// Copies the image at [url] to the clipboard.
  Future<void> copyImage({required String url, required String name}) =>
      channel.invokeMethod<void>('copyImage', {'url': url, 'name': name});

  /// Saves the frame at [position] of the video at [url] as a JPEG named
  /// [name] to the download folder; returns where it was saved.
  Future<String> saveFrame({
    required String url,
    required String name,
    required Duration position,
    String? directory,
  }) async =>
      await channel.invokeMethod<String>('saveFrame', {
        'url': url,
        'name': name,
        'positionMs': position.inMilliseconds,
        'directory': directory,
      }) ??
      '';

  /// Sends the app to the background instead of closing it, so downloads
  /// keep running.
  Future<void> moveToBack() async {
    try {
      await channel.invokeMethod<Object?>('moveToBack');
    } catch (_) {
      // Not available in widget tests or without the Android host.
    }
  }

  /// Reads a text file the user picks; null when the picker is cancelled.
  Future<String?> importFile() => channel.invokeMethod<String>('importFile');

  /// Reads a favorites list the user picks: a text or JSON file, or a
  /// LoliSnatcher `store.db` backup, whose favorites' post links the
  /// platform reads (`format` `lolisnatcher`, one link per line). Null when
  /// the picker is cancelled.
  Future<({String format, String text})?> importList() async {
    final value = await channel.invokeMapMethod<String, Object?>('importFile', {
      'databases': true,
    });
    if (value == null) return null;
    return (
      format: value['format'] is String ? value['format'] as String : 'text',
      text: value['text'] is String ? value['text'] as String : '',
    );
  }

  /// Whether the active network is metered (usually mobile data). False
  /// when unknown.
  Future<bool> isMeteredNetwork() async {
    try {
      return await channel.invokeMethod<bool>('isMeteredNetwork') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Bytes in the app's cache folder (shared media and other temporary
  /// files).
  Future<int> cacheSize() async =>
      (await channel.invokeMethod<num>('cacheSize'))?.toInt() ?? 0;

  /// Deletes the app's cache folder contents.
  Future<void> clearCache() => channel.invokeMethod<void>('clearCache');

  /// Pools [post] belongs to, as `{id, name, postCount}` maps. Only Danbooru
  /// and e621/e926 report them.
  Future<List<PostPool>> pools({
    required Board board,
    required MediaPost post,
  }) async {
    final response = await channel.invokeMethod<List<dynamic>>('pools', {
      'board': board.name,
      'postId': post.displayId,
      'ids': post.pools,
    });
    return (response ?? const [])
        .whereType<Map>()
        .map(PostPool.fromMap)
        .where((pool) => pool.id.isNotEmpty)
        .toList(growable: false);
  }

  /// Replaces the launcher icon's shortcuts.
  Future<void> setShortcuts(List<AppShortcut> shortcuts) async {
    try {
      await channel.invokeMethod<void>('setShortcuts', {
        'items': [for (final shortcut in shortcuts) shortcut.toMap()],
      });
    } catch (_) {
      // Not available in widget tests or without the Android host.
    }
  }

  /// The launcher shortcut that opened the app, once.
  Future<AppShortcut?> takeShortcut() async {
    try {
      final value = await channel.invokeMethod<Map<dynamic, dynamic>>(
        'takeShortcut',
      );
      return value == null ? null : AppShortcut.fromMap(value);
    } catch (_) {
      return null;
    }
  }

  static final _shortcuts = StreamController<AppShortcut>.broadcast();
  static bool _listening = false;

  /// Calls from the Android host: launcher shortcuts and picture-in-picture
  /// changes.
  void _listen() {
    if (_listening) return;
    _listening = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'shortcut' && call.arguments is Map) {
        _shortcuts.add(AppShortcut.fromMap(call.arguments as Map));
      } else if (call.method == 'pictureInPicture') {
        _pictureInPicture.value = call.arguments == true;
      }
    });
  }

  /// Launcher shortcuts used while the app is running.
  Stream<AppShortcut> get shortcuts {
    _listen();
    return _shortcuts.stream;
  }

  static final _pictureInPicture = ValueNotifier(false);

  /// Whether the app shows as a small picture-in-picture window.
  ValueListenable<bool> get pictureInPicture {
    _listen();
    return _pictureInPicture;
  }

  /// Whether leaving the app (Home) shrinks it into a picture-in-picture
  /// window shaped like [width] x [height].
  Future<void> setPictureInPicture({
    required bool auto,
    int width = 9,
    int height = 16,
  }) async {
    _listen();
    try {
      await channel.invokeMethod<void>('setPictureInPicture', {
        'auto': auto,
        'width': width,
        'height': height,
      });
    } catch (_) {
      // Not available in widget tests or without the Android host.
    }
  }

  /// Shrinks the app into a picture-in-picture window now. False when the
  /// device does not allow it.
  Future<bool> enterPictureInPicture({int width = 9, int height = 16}) async {
    _listen();
    try {
      return await channel.invokeMethod<bool>('enterPictureInPicture', {
            'width': width,
            'height': height,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }
}

/// A pool a post belongs to.
class PostPool {
  const PostPool({required this.id, required this.name, this.postCount = 0});
  final String id, name;
  final int postCount;

  factory PostPool.fromMap(Map<dynamic, dynamic> map) => PostPool(
    id: '${map['id'] ?? ''}',
    name: '${map['name'] ?? ''}',
    postCount: map['postCount'] is num ? (map['postCount'] as num).toInt() : 0,
  );
}

/// A launcher icon shortcut: open favorites, or run a saved search. Also
/// carries a link opened with, or text shared to, the app (`link`), whose
/// [url] is read with [PostLink.parse].
class AppShortcut {
  const AppShortcut.favorites()
    : kind = 'favorites',
      id = 'favorites',
      label = 'Favorites',
      board = null,
      tags = const [],
      url = null;
  const AppShortcut.search({
    required this.id,
    required this.label,
    required Board this.board,
    required this.tags,
  }) : kind = 'search',
       url = null;

  /// The download notification: opens the Download Manager.
  const AppShortcut.downloads()
    : kind = 'downloads',
      id = 'downloads',
      label = 'Downloads',
      board = null,
      tags = const [],
      url = null;
  const AppShortcut.link(String this.url)
    : kind = 'link',
      id = 'link',
      label = '',
      board = null,
      tags = const [];

  final String kind, id, label;
  final Board? board;
  final List<String> tags;
  final String? url;

  Map<String, Object?> toMap() => {
    'id': id,
    'label': label,
    'kind': kind,
    'board': ?board?.name,
    if (tags.isNotEmpty) 'tags': tags.join(' '),
    'url': ?url,
  };

  factory AppShortcut.fromMap(Map<dynamic, dynamic> map) {
    final url = map['url'];
    if (map['kind'] == 'link' && url is String && url.trim().isNotEmpty) {
      return AppShortcut.link(url.trim());
    }
    if (map['kind'] == 'downloads') return const AppShortcut.downloads();
    final board = Board.values.asNameMap()['${map['board']}'];
    final tags = '${map['tags'] ?? ''}'
        .split(RegExp(r'\s+'))
        .where((tag) => tag.isNotEmpty)
        .toList(growable: false);
    return map['kind'] == 'search' && board != null
        ? AppShortcut.search(
            id: '${map['id'] ?? 'search'}',
            label: tags.join(' '),
            board: board,
            tags: tags,
          )
        : const AppShortcut.favorites();
  }
}
