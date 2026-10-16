import 'dart:collection';
import 'dart:math';

import 'models.dart';

/// What the viewer did with a booruShorts video, and how much it says about
/// their taste. Explicit actions weigh more than watch time.
enum ShortsSignal {
  like(1.0),
  favorite(1.5),
  download(1.0),
  share(.5),
  details(.2),
  completed(.3),
  looped(.2),
  quickSkip(-.3),
  dislike(-1.5),
  hide(-2.0);

  const ShortsSignal(this.weight);
  final double weight;
}

extension ShortsExplorationInfo on ShortsExploration {
  /// The share of videos picked at random instead of by score.
  double get rate => switch (this) {
    ShortsExploration.low => .1,
    ShortsExploration.normal => .25,
    ShortsExploration.high => .45,
  };

  /// Random noise added to every score, so equal interests mix.
  double get noise => switch (this) {
    ShortsExploration.low => .05,
    ShortsExploration.normal => .15,
    ShortsExploration.high => .3,
  };
}

/// Played time, loops, and whether the video could be seen at all, for one
/// visit to a booruShorts video.
class ShortsWatch {
  const ShortsWatch({
    required this.played,
    required this.duration,
    this.loops = 0,
    this.visible = true,
  });

  /// Media time actually played, without seeks.
  final Duration played;

  /// The video's length; zero when it never loaded.
  final Duration duration;
  final int loops;

  /// False when the video stayed blurred and was never revealed.
  final bool visible;

  /// The implicit signals this visit gives, strongest last.
  List<ShortsSignal> get signals {
    if (!visible || duration <= Duration.zero) return const [];
    final total = duration.inMilliseconds;
    final watched = played.inMilliseconds;
    if (loops == 0 && watched < min(2000, total * .25)) {
      return const [ShortsSignal.quickSkip];
    }
    return [
      if (loops > 0 || watched >= total * .9) ShortsSignal.completed,
      for (var i = 0; i < min(loops, 3); i++) ShortsSignal.looped,
    ];
  }
}

/// The viewer's booruShorts interests, learned on this device from likes,
/// dislikes, and watch time: a weight per tag, website, and uploader, plus
/// the videos already shown. See docs/booru-shorts.md.
class ShortsProfile {
  ShortsProfile({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  static const maxTags = 2000;
  static const maxSeen = 2000;
  static const maxHistory = 100;
  static const maxMuted = 200;
  static const _limit = 3.0;
  static const _learningRate = .5;
  static const _halfLifeDays = 14.0;

  final Map<String, double> _tags = {};
  // How many watched videos carried each tag, for rarer tags to count more.
  final Map<String, int> _tagSeen = {};
  final Map<Board, double> _boards = {};
  final Map<String, double> _uploaders = {};
  final Set<String> _muted = {};
  // Newest last.
  final LinkedHashSet<String> _seen = LinkedHashSet();
  final List<SavedPost> _history = [];
  int _watched = 0;
  DateTime? _updatedAt;

  /// Tags that say nothing about taste because nearly every video has them.
  static const ignoredTags = {
    'video',
    'animated',
    'sound',
    'webm',
    'mp4',
    'highres',
    'absurdres',
    'video_with_sound',
    'has_audio',
    'no_sound',
    'tagme',
    'animated_png',
    'animated_gif',
    'loop',
    'long_playtime',
    'short_playtime',
    'mid_playtime',
    'translated',
    'commentary',
    'commentary_request',
  };

  bool get isEmpty =>
      _tags.isEmpty && _boards.isEmpty && _uploaders.isEmpty && _seen.isEmpty;

  /// Whether anything was learned that can reorder videos.
  bool get hasInterests =>
      _tags.isNotEmpty || _boards.isNotEmpty || _uploaders.isNotEmpty;

  Map<String, double> get tagWeights => Map.unmodifiable(_tags);
  Set<String> get mutedTags => Set.unmodifiable(_muted);

  /// Recently watched videos, newest first.
  List<SavedPost> get history => List.unmodifiable(_history.reversed);

  /// The [count] most liked tags, strongest first, that are not muted.
  List<String> topTags(int count, {double atLeast = .6}) {
    final entries =
        _tags.entries
            .where(
              (entry) => entry.value >= atLeast && !_muted.contains(entry.key),
            )
            .toList()
          ..sort((a, b) => b.value.compareTo(a.value));
    return [for (final entry in entries.take(count)) entry.key];
  }

  static String _uploaderKey(Board board, String uploader) =>
      '${board.name}:${uploader.trim().toLowerCase()}';

  /// The key a video is remembered by: its file hash when known, so the same
  /// file on another website counts as seen too.
  static String seenKey(SavedPost saved) {
    final md5 = saved.post.md5;
    if (md5.isNotEmpty) return 'md5:$md5';
    final identity = saved.identity;
    return identity.length > 160 ? identity.substring(0, 160) : identity;
  }

  bool hasSeen(SavedPost saved) => _seen.contains(seenKey(saved));

  /// The tags of [post] that carry meaning, with their category weight.
  static Map<String, double> _meaningful(MediaPost post, Board board) {
    final video = {...?board.shortsVideoQuery};
    final details = post.tagDetails.isEmpty
        ? [
            for (final name in post.tags)
              TagInfo(name: name, category: TagCategory.general),
          ]
        : post.tagDetails;
    final result = <String, double>{};
    for (final tag in details) {
      final name = tag.name.trim().toLowerCase();
      if (name.isEmpty ||
          name.contains(':') ||
          ignoredTags.contains(name) ||
          video.contains(name)) {
        continue;
      }
      final weight = switch (tag.category) {
        TagCategory.artist => 1.5,
        TagCategory.character => 1.3,
        TagCategory.copyright => 1.2,
        TagCategory.species => 1.0,
        TagCategory.general || TagCategory.unknown || TagCategory.lore => .6,
        TagCategory.meta => 0.0,
      };
      if (weight > 0) result[name] = weight;
    }
    return result;
  }

  /// Learns [signal] from [saved]; [undo] takes back an earlier one.
  void learn(SavedPost saved, ShortsSignal signal, {bool undo = false}) =>
      _learn(saved, signal.weight * (undo ? -1 : 1));

  void _learn(SavedPost saved, double amount) {
    _decay();
    final tags = _meaningful(saved.post, saved.board);
    if (tags.isNotEmpty) {
      final scale = _learningRate * amount / sqrt(tags.length);
      for (final MapEntry(key: tag, value: weight) in tags.entries) {
        _bump(_tags, tag, scale * weight);
      }
    }
    _bump(_boards, saved.board, .1 * amount);
    final uploader = saved.post.uploader.trim();
    if (uploader.isNotEmpty) {
      _bump(_uploaders, _uploaderKey(saved.board, uploader), .2 * amount);
    }
    _trim();
  }

  /// Learns interest in one [tag], such as one tapped to filter by.
  void learnTag(String tag, double amount) {
    final name = tag.trim().toLowerCase();
    if (name.isEmpty || ignoredTags.contains(name)) return;
    _decay();
    _bump(_tags, name, _learningRate * amount);
    _trim();
  }

  static void _bump<K>(Map<K, double> weights, K key, double amount) {
    final next = ((weights[key] ?? 0) + amount).clamp(-_limit, _limit);
    if (next.abs() < .01) {
      weights.remove(key);
    } else {
      weights[key] = next;
    }
  }

  /// Remembers that [saved] was shown, and adds it to the watch history
  /// when [watched].
  void observe(SavedPost saved, {required bool watched}) {
    final key = seenKey(saved);
    _seen.remove(key);
    _seen.add(key);
    while (_seen.length > maxSeen) {
      _seen.remove(_seen.first);
    }
    if (!watched) return;
    _watched++;
    for (final tag in _meaningful(saved.post, saved.board).keys) {
      _tagSeen[tag] = (_tagSeen[tag] ?? 0) + 1;
    }
    if (_tagSeen.length > maxTags * 2) {
      final kept =
          (_tagSeen.entries.toList()
                ..sort((a, b) => b.value.compareTo(a.value)))
              .take(maxTags)
              .toList();
      _tagSeen
        ..clear()
        ..addEntries(kept);
    }
    final sanitized = saved.sanitized();
    _history.removeWhere((other) => other.identity == sanitized.identity);
    _history.add(sanitized);
    if (_history.length > maxHistory) {
      _history.removeRange(0, _history.length - maxHistory);
    }
  }

  /// Never shows videos with [tag] again until it is unmuted.
  void mute(String tag) {
    final name = tag.trim().toLowerCase();
    if (name.isEmpty) return;
    _muted.add(name);
    _tags.remove(name);
    while (_muted.length > maxMuted) {
      _muted.remove(_muted.first);
    }
  }

  void unmute(String tag) => _muted.remove(tag.trim().toLowerCase());

  /// Forgets what was learned about [tag].
  void forgetTag(String tag) => _tags.remove(tag.trim().toLowerCase());

  bool isMuted(SavedPost saved) {
    if (_muted.isEmpty) return false;
    return saved.post.tags.any(
      (tag) => _muted.contains(tag.trim().toLowerCase()),
    );
  }

  /// Whether [saved] has a tag the viewer clearly dislikes.
  bool isDisliked(SavedPost saved) => saved.post.tags.any(
    (tag) => (_tags[tag.trim().toLowerCase()] ?? 0) <= -2,
  );

  /// How well [saved] matches the viewer's interests, without noise.
  double score(SavedPost saved) {
    final tags = _meaningful(saved.post, saved.board);
    var total = 0.0;
    if (tags.isNotEmpty) {
      for (final MapEntry(key: tag, value: weight) in tags.entries) {
        final learned = _tags[tag];
        if (learned == null) continue;
        total += weight * _rarity(tag) * learned;
      }
      total /= sqrt(tags.length);
    }
    total += .5 * (_boards[saved.board] ?? 0);
    final uploader = saved.post.uploader.trim();
    if (uploader.isNotEmpty) {
      total += .3 * (_uploaders[_uploaderKey(saved.board, uploader)] ?? 0);
    }
    return total;
  }

  double _rarity(String tag) =>
      _watched == 0 ? 1 : log(1 + (_watched + 1) / (1 + (_tagSeen[tag] ?? 0)));

  /// The liked tags that matter most to [saved]'s score, strongest first.
  List<String> reasons(SavedPost saved, {int count = 3}) {
    final contributions = <String, double>{};
    for (final MapEntry(key: tag, value: weight) in _meaningful(
      saved.post,
      saved.board,
    ).entries) {
      final learned = _tags[tag];
      if (learned != null && learned > 0) {
        contributions[tag] = weight * _rarity(tag) * learned;
      }
    }
    final sorted = contributions.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [for (final entry in sorted.take(count)) entry.key];
  }

  /// Older interests fade: weights halve every two weeks without activity.
  void _decay() {
    final now = _clock();
    final last = _updatedAt;
    _updatedAt = now;
    if (last == null) return;
    final days = now.difference(last).inMinutes / (60 * 24);
    if (days < 1) return;
    final factor = pow(.5, days / _halfLifeDays).toDouble();
    for (final weights in [_tags, _uploaders]) {
      for (final key in weights.keys.toList()) {
        _bump(weights, key, weights[key]! * (factor - 1));
      }
    }
    for (final key in _boards.keys.toList()) {
      _bump(_boards, key, _boards[key]! * (factor - 1));
    }
  }

  void _trim() {
    if (_tags.length <= maxTags) return;
    final kept =
        (_tags.entries.toList()
              ..sort((a, b) => b.value.abs().compareTo(a.value.abs())))
            .take(maxTags)
            .toList();
    _tags
      ..clear()
      ..addEntries(kept);
  }

  /// Forgets every interest; muted tags and the watch history stay.
  void resetInterests() {
    _tags.clear();
    _tagSeen.clear();
    _boards.clear();
    _uploaders.clear();
    _watched = 0;
    _updatedAt = null;
  }

  void clearHistory() {
    _seen.clear();
    _history.clear();
  }

  /// Interests only (no watch history), for backups.
  Map<String, dynamic> interestsToMap() => {
    'tags': _tags,
    'boards': {
      for (final entry in _boards.entries) entry.key.name: entry.value,
    },
    'uploaders': _uploaders,
    'muted': _muted.toList(),
    if (_updatedAt != null) 'updatedAt': _updatedAt!.toIso8601String(),
  };

  Map<String, dynamic> toMap() => {
    'version': 1,
    ...interestsToMap(),
    'tagSeen': _tagSeen,
    'watched': _watched,
    'seen': _seen.toList(),
    'history': [for (final saved in _history) saved.toMap()],
  };

  /// Reads [toMap] output. Damaged entries are skipped, and the watch
  /// history is kept unless [map] has its own.
  void loadMap(Map<dynamic, dynamic> map) {
    Map<String, double> weights(Object? value) => {
      if (value is Map)
        for (final entry in value.entries)
          if (entry.value is num && '${entry.key}'.trim().isNotEmpty)
            '${entry.key}': (entry.value as num).toDouble().clamp(
              -_limit,
              _limit,
            ),
    };
    _tags
      ..clear()
      ..addAll(weights(map['tags']));
    _uploaders
      ..clear()
      ..addAll(weights(map['uploaders']));
    _boards.clear();
    for (final MapEntry(:key, :value) in weights(map['boards']).entries) {
      final board = Board.values.where((board) => board.name == key);
      if (board.isNotEmpty) _boards[board.first] = value;
    }
    _muted
      ..clear()
      ..addAll(
        [
          if (map['muted'] is List)
            for (final tag in map['muted'] as List)
              if ('$tag'.trim().isNotEmpty) '$tag'.trim().toLowerCase(),
        ].take(maxMuted),
      );
    _updatedAt = DateTime.tryParse('${map['updatedAt'] ?? ''}');
    if (map.containsKey('tagSeen')) {
      _tagSeen
        ..clear()
        ..addAll({
          if (map['tagSeen'] is Map)
            for (final entry in (map['tagSeen'] as Map).entries)
              if (entry.value is num)
                '${entry.key}': (entry.value as num).toInt(),
        });
      _watched = map['watched'] is num ? (map['watched'] as num).toInt() : 0;
    }
    if (map.containsKey('seen') || map.containsKey('history')) {
      _seen
        ..clear()
        ..addAll(
          [
            if (map['seen'] is List)
              for (final key in map['seen'] as List) '$key',
          ].reversed.take(maxSeen).toList().reversed,
        );
      _history
        ..clear()
        ..addAll(
          [
                if (map['history'] is List)
                  for (final item in map['history'] as List)
                    if (item is Map) _savedOrNull(item),
              ]
              .whereType<SavedPost>()
              .toList()
              .reversed
              .take(maxHistory)
              .toList()
              .reversed,
        );
    }
    _trim();
  }

  static SavedPost? _savedOrNull(Map<dynamic, dynamic> map) {
    try {
      return SavedPost.fromMap(map).sanitized();
    } catch (_) {
      return null;
    }
  }
}

/// Picks the order of booruShorts videos from a pool of candidates: mostly
/// the best matches for the viewer's interests, some at random, without long
/// runs of one artist or website.
class ShortsRanker {
  ShortsRanker(this.profile, {Random? random}) : _random = random ?? Random();
  final ShortsProfile profile;
  final Random _random;

  /// Removes up to [count] videos from [pool], in the order to show them
  /// after [recent] (the videos shown last, oldest first). Videos already
  /// seen come last. Picks made at random are added to [explored].
  List<SavedPost> take(
    List<SavedPost> pool,
    int count, {
    required ShortsExploration exploration,
    List<SavedPost> recent = const [],
    Set<String>? explored,
  }) {
    final picked = <SavedPost>[];
    final history = [...recent];
    final noise = {
      for (final saved in pool)
        saved.identity: (_random.nextDouble() * 2 - 1) * exploration.noise,
    };
    while (picked.length < count && pool.isNotEmpty) {
      final fresh = pool.where((saved) => !profile.hasSeen(saved)).toList();
      final candidates = fresh.isNotEmpty ? fresh : List.of(pool);
      final varied = candidates
          .where((saved) => !_repeats(saved, history))
          .toList();
      final choices = varied.isNotEmpty ? varied : candidates;
      final SavedPost next;
      if (_random.nextDouble() < exploration.rate) {
        next = choices[_random.nextInt(choices.length)];
        explored?.add(next.identity);
      } else {
        next = choices.reduce(
          (best, saved) =>
              profile.score(saved) + noise[saved.identity]! >
                  profile.score(best) + noise[best.identity]!
              ? saved
              : best,
        );
      }
      pool.remove(next);
      picked.add(next);
      history.add(next);
    }
    return picked;
  }

  /// Whether [saved] would make a third video in a row by the same artist
  /// or a fourth from the same website.
  static bool _repeats(SavedPost saved, List<SavedPost> history) {
    bool run(int length, bool Function(SavedPost) same) =>
        history.length >= length &&
        history.skip(history.length - length).every(same);
    final artists = _artists(saved.post);
    return run(3, (other) => other.board == saved.board) ||
        (artists.isNotEmpty &&
            run(2, (other) => _artists(other.post).any(artists.contains)));
  }

  static Set<String> _artists(MediaPost post) => {
    for (final tag in post.tagDetails)
      if (tag.category == TagCategory.artist) tag.name.toLowerCase(),
  };
}
