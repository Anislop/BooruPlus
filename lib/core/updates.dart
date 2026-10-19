import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'services.dart';

/// The GitHub repository (`owner/name`) whose releases this build updates
/// from. CD passes the repository that built it, since build numbers are
/// only comparable within one repository's release history.
const updateRepository = String.fromEnvironment(
  'UPDATE_REPOSITORY',
  defaultValue: 'Anislop/BooruPlus',
);

/// The installed app's version name and build number (Android versionCode).
class InstalledVersion {
  const InstalledVersion({required this.name, required this.build});
  final String name;
  final int build;

  String get label => '$name (build $build)';
}

/// A GitHub release carrying the uncensored APK.
class AppRelease {
  const AppRelease({
    required this.tag,
    required this.title,
    required this.version,
    required this.build,
    required this.apkUrl,
    required this.pageUrl,
    this.notes = '',
    this.size,
    this.prerelease = false,
  });
  final String tag, title, version, apkUrl, pageUrl, notes;
  final int build;
  final int? size;
  final bool prerelease;

  String get label => '$version (build $build)';

  /// CD writes a nightly's commit message into its notes and ends it with
  /// this marker; text after it is for the GitHub release page only.
  static const commitEnd = '<!-- end of commit message -->';

  /// The commit title and description from [notes]. Releases without the
  /// marker (versioned ones) use the release title and the whole notes.
  ({String title, String description}) get change {
    final text = notes.replaceAll('\r\n', '\n');
    final end = text.indexOf(commitEnd);
    if (end < 0) return (title: title, description: text.trim());
    final message = text.substring(0, end).trim();
    final lineEnd = message.indexOf('\n');
    final subject = (lineEnd < 0 ? message : message.substring(0, lineEnd))
        .trim();
    return (
      title: subject.isEmpty ? title : subject,
      description: lineEnd < 0 ? '' : message.substring(lineEnd + 1).trim(),
    );
  }

  /// CD attaches the release APK as
  /// `booruplus-<version>-<build>-uncensored.apk`.
  static final apkName = RegExp(
    r'^booruplus-(.+)-(\d+)-uncensored\.apk$',
    caseSensitive: false,
  );

  /// The release in a GitHub `releases` listing whose uncensored APK has the
  /// highest build number above [installedBuild], or null when none does.
  static AppRelease? newest(Object? listing, {required int installedBuild}) {
    if (listing is! List) return null;
    AppRelease? best;
    for (final release in listing) {
      if (release is! Map || release['draft'] == true) continue;
      final assets = release['assets'];
      if (assets is! List) continue;
      for (final asset in assets) {
        if (asset is! Map) continue;
        final match = apkName.firstMatch('${asset['name'] ?? ''}');
        final url = asset['browser_download_url'];
        final state = asset['state'];
        if (match == null || url is! String || !_fromGitHub(url)) continue;
        if (state != null && state != 'uploaded') continue;
        final build = int.tryParse(match.group(2)!) ?? 0;
        if (build <= installedBuild || build <= (best?.build ?? 0)) continue;
        final tag = '${release['tag_name'] ?? ''}';
        final page = release['html_url'];
        final size = asset['size'];
        best = AppRelease(
          tag: tag,
          title: '${release['name'] ?? ''}'.trim().isEmpty
              ? tag
              : '${release['name']}'.trim(),
          version: match.group(1)!,
          build: build,
          apkUrl: url,
          pageUrl: page is String && _fromGitHub(page) ? page : url,
          notes: '${release['body'] ?? ''}'.trim(),
          size: size is num && size > 0 ? size.toInt() : null,
          prerelease: release['prerelease'] == true,
        );
      }
    }
    return best;
  }

  static bool _fromGitHub(String value) {
    final uri = Uri.tryParse(value);
    return uri != null && uri.scheme == 'https' && uri.host == 'github.com';
  }
}

/// Why an update was not installed.
enum UpdateFailure { signature, notNewer, invalid, network }

class UpdateException implements Exception {
  const UpdateException(this.failure);
  final UpdateFailure failure;

  /// Whether trying again may succeed.
  bool get retryable => failure == UpdateFailure.network;

  String get message => switch (failure) {
    UpdateFailure.signature =>
      'This update is not signed with the same key as the installed app, so '
          'it cannot be verified as a genuine BooruPlus release and was not '
          'installed. Keep this version, and do not uninstall BooruPlus to '
          'install it. Confirm the release with the developer through a '
          'channel you already trust.',
    UpdateFailure.notNewer =>
      'This update is not newer than the installed app.',
    UpdateFailure.invalid => 'The downloaded file is not a BooruPlus update.',
    UpdateFailure.network =>
      'Could not download the update. Check your connection and try again.',
  };
}

/// Finds newer releases on GitHub and hands their APK to Android's package
/// installer.
class UpdateService {
  UpdateService({
    MethodChannel? channel,
    DownloadService? downloads,
    this.repository = updateRepository,
    Future<String> Function(Uri uri)? get,
  }) : channel = channel ?? const MethodChannel('booruplus/platform'),
       downloads = downloads ?? DownloadService(),
       _get = get ?? _httpGet;
  final MethodChannel channel;
  final DownloadService downloads;
  final String repository;
  final Future<String> Function(Uri uri) _get;

  /// The installed version, or null without the Android host.
  Future<InstalledVersion?> installedVersion() async {
    try {
      final value = await channel.invokeMethod<Map<dynamic, dynamic>>(
        'appVersion',
      );
      final build = value?['build'];
      if (value == null || build is! num) return null;
      return InstalledVersion(
        name: '${value['name'] ?? ''}',
        build: build.toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  /// The newest release built after the installed app, or null when it is
  /// up to date. Throws when the releases cannot be read.
  Future<AppRelease?> check() async {
    final installed = await installedVersion();
    if (installed == null) return null;
    final body = await _get(
      Uri.https('api.github.com', '/repos/$repository/releases', {
        'per_page': '10',
      }),
    );
    return AppRelease.newest(jsonDecode(body), installedBuild: installed.build);
  }

  /// Downloads [release]'s APK and opens the package installer with it.
  /// Throws [UpdateException] when it cannot.
  Future<void> install(
    AppRelease release, {
    DownloadProgress? onProgress,
  }) async {
    try {
      await downloads.reporting(
        onProgress,
        (id) => channel.invokeMethod<void>('installUpdate', {
          'url': release.apkUrl,
          'id': ?id,
        }),
      );
    } on PlatformException catch (error) {
      throw UpdateException(switch (error.code) {
        'UPDATE_SIGNATURE' => UpdateFailure.signature,
        'UPDATE_NOT_NEWER' => UpdateFailure.notNewer,
        'UPDATE_INVALID' => UpdateFailure.invalid,
        _ => UpdateFailure.network,
      });
    } on MissingPluginException {
      throw const UpdateException(UpdateFailure.network);
    }
  }

  static Future<String> _httpGet(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent = 'BooruPlus updater';
    try {
      final request = await client.getUrl(uri);
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      return await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 20));
    } finally {
      client.close(force: true);
    }
  }
}
