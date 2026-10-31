import 'edition.dart';
import 'models.dart';
import 'services.dart';

/// What an edition may show, fixed at compile time.
///
/// The Full edition is unrestricted ([ContentPolicy.full]). The Play edition
/// ([ContentPolicy.play]) offers a fixed set of websites, sends every search
/// with the website's safe rating, and keeps only posts that are rated
/// General (or come from a website without ratings that is safe by its own
/// rules), carry none of [blockedTags], and are tagged well enough to
/// screen. Settings, backups, links, and saved data can narrow this policy
/// but never widen it: there is no switch, remote flag, or backup field
/// that turns it off.
class ContentPolicy {
  const ContentPolicy._({
    required this.restricted,
    this.freeBoards = const {},
    this.premiumBoards = const {},
    this.unratedBoards = const {},
  });

  /// The Full edition: every website, no forced rules.
  static const full = ContentPolicy._(restricted: false);

  /// The Play edition.
  static const play = ContentPolicy._(
    restricted: true,
    freeBoards: {
      Board.safebooru,
      Board.danbooru,
      Board.konachan,
      Board.e926,
      Board.sankaku,
      Board.idolcomplex,
      Board.sakugabooru,
      Board.aibooru,
    },
    premiumBoards: {
      Board.yandere,
      Board.gelbooru,
      Board.mspabooru,
      Board.eshuushuu,
      Board.derpibooru,
    },
    // E-Shuushuu rates nothing, but its rules keep explicit images off the
    // site; unrated posts elsewhere are dropped.
    unratedBoards: {Board.eshuushuu},
  );

  /// This build's policy.
  static const current = kPlayEdition ? play : full;

  /// Whether the rules below apply at all.
  final bool restricted;

  /// Websites every user of the edition can open.
  final Set<Board> freeBoards;

  /// Websites that need Premium in the Play edition.
  final Set<Board> premiumBoards;

  /// Websites without ratings whose posts may still be shown.
  final Set<Board> unratedBoards;

  /// Whether [board] exists in this edition at all.
  bool offers(Board board) =>
      !restricted ||
      freeBoards.contains(board) ||
      premiumBoards.contains(board);

  /// Whether [board] needs Premium.
  bool needsPremium(Board board) => restricted && premiumBoards.contains(board);

  /// Whether the user may sign in to [board]. The Play edition keeps only
  /// the API keys a website requires (Gelbooru); optional sign-ins, which
  /// exist to reach more content, are left out.
  bool allowsSignIn(Board board) =>
      !restricted || (offers(board) && board.requiresAuth);

  /// The ratings settings may select.
  List<Rating> get ratings =>
      restricted ? const [Rating.general] : Rating.values;

  /// The safe `rating:` tag sent with every search on [board], or null where
  /// the website has no ratings.
  String? forcedRatingTag(Board board) {
    if (!restricted || !board.hasRatings) return null;
    return switch (board) {
      // Gelbooru names its levels; the other Gelbooru 0.2 boards use `safe`.
      Board.gelbooru => 'rating:general',
      _ => 'rating:${board.ratingQuery(Rating.general)}',
    };
  }

  /// The fewest tags a post on [board] needs: a post that is barely tagged
  /// cannot be screened. Sakugabooru and E-Shuushuu tag lightly.
  int minimumTagsFor(Board board) {
    if (!restricted) return 0;
    return switch (board) {
      Board.sakugabooru => 2,
      Board.eshuushuu => 3,
      _ => 5,
    };
  }

  /// Whether [tag] is on the forced blocklist for [board]. Names match
  /// ignoring case, separators (spaces, hyphens, underscores), and a
  /// trailing `_(qualifier)`.
  bool blocks(String tag, {Board? board}) {
    if (!restricted) return false;
    final name = looseTag(tag);
    if (name.isEmpty) return false;
    final bare = _unqualified(name);
    bool listed(String value) =>
        blockedTags.contains(value) ||
        (board == Board.idolcomplex && realPersonBlockedTags.contains(value));
    if (listed(name) || listed(bare)) return true;
    return _blockedPrefixes.any(bare.startsWith) ||
        _blockedSuffixes.any(bare.endsWith);
  }

  /// Whether [post] from [board] may be shown, downloaded, or saved here.
  bool allowsPost(Board board, MediaPost post) {
    if (!restricted) return true;
    if (!offers(board)) return false;
    if (board.hasRatings) {
      if (RatingInfo.parse(post.rating) != Rating.general) return false;
    } else if (!unratedBoards.contains(board)) {
      return false;
    }
    if (post.tags.length < minimumTagsFor(board)) return false;
    for (final tag in post.tags) {
      if (blocks(tag, board: board)) return false;
    }
    for (final tag in post.tagDetails) {
      if (blocks(tag.name, board: board)) return false;
    }
    return true;
  }

  /// Whether a saved post may be shown.
  bool allowsSaved(SavedPost saved) => allowsPost(saved.board, saved.post);

  /// [tags] without what this edition never searches for: `rating:` and
  /// `status:` metatags (the forced rating is added separately), and blocked
  /// tags asked for, alone, as an either-or (`~tag`), inside a group, or
  /// through a wildcard. Excluding a blocked tag (`-tag`) is kept.
  ({List<String> tags, List<String> removed}) sanitize(
    List<String> tags, {
    Board? board,
  }) {
    if (!restricted) return (tags: tags, removed: const []);
    final kept = <String>[];
    final removed = <String>[];
    for (final raw in tags) {
      final tag = raw.trim();
      if (tag.isEmpty) continue;
      if (_forbidden(tag, board)) {
        removed.add(tag);
      } else {
        kept.add(tag);
      }
    }
    return (tags: kept, removed: removed);
  }

  bool _forbidden(String tag, Board? board) {
    final lower = tag.toLowerCase();
    final negated = lower.startsWith('-');
    final body = negated || lower.startsWith('~') ? lower.substring(1) : lower;
    if (_metatag.hasMatch(body)) return true;
    if (negated) return false;
    // A group such as `{a ~ b}` or `( a ~ b )` asks for each of its tags.
    final parts = body
        .replaceAll(RegExp(r'[{}()]'), ' ')
        .split(RegExp(r'\s+'))
        .map((part) => part.startsWith('~') ? part.substring(1) : part)
        .where((part) => part.isNotEmpty && part != '~');
    for (final part in parts) {
      if (_metatag.hasMatch(part)) return true;
      if (part.contains('*')) {
        final prefix = looseTag(part.split('*').first);
        if (prefix.length < 3 ||
            blockedTags.any((blocked) => blocked.startsWith(prefix))) {
          return true;
        }
        continue;
      }
      if (blocks(part, board: board)) return true;
    }
    return false;
  }

  static final _metatag = RegExp(r'^(rating|status|filter_id|my)[:.]');

  static final _separators = RegExp(r'[\s_-]+');
  static final _qualifier = RegExp(r'^(.+?)_\([^()]*\)$');

  /// [tag] lowercased with words joined by underscores.
  static String looseTag(String tag) =>
      tag.trim().toLowerCase().replaceAll(_separators, '_');

  static String _unqualified(String tag) =>
      _qualifier.firstMatch(tag)?.group(1) ?? tag;

  /// Tags never shown in the Play edition, on every website: sexual
  /// content and nudity, the sexualization of minors, fetish material, and
  /// gore. Kept in loose form (see [looseTag]). Tune against real feeds;
  /// never fetched remotely.
  static const blockedTags = {
    // Ratings that some websites (Derpibooru) store as tags.
    'explicit', 'questionable', 'suggestive', 'grimdark', 'semi_grimdark',
    'grotesque', 'nsfw', 'r_18', 'r18', 'lewd', 'ecchi', 'hentai', 'porn',
    'pornography',
    // Minors.
    'loli', 'lolicon', 'shota', 'shotacon', 'cub', 'young', 'toddlercon',
    'child_on_child', 'oppai_loli',
    // Nudity and sexual content.
    'nude', 'nudity', 'naked', 'completely_nude', 'partially_nude', 'topless',
    'bottomless', 'nipples', 'nipple', 'areolae', 'areola', 'breasts_out',
    'pussy', 'vagina', 'penis', 'erection', 'testicles', 'genitals', 'anus',
    'ass_visible_through_thighs', 'cameltoe', 'covered_nipples',
    'erect_nipples', 'pubic_hair', 'sex', 'vaginal', 'anal', 'oral',
    'fellatio', 'cunnilingus', 'paizuri', 'handjob', 'footjob', 'masturbation',
    'fingering', 'cum', 'semen', 'ejaculation', 'orgasm', 'ahegao', 'rape',
    'sex_toy', 'vibrator', 'dildo', 'condom', 'groping', 'breast_grab',
    'ass_grab', 'breast_sucking', 'kiss_mark', 'pantyshot', 'upskirt',
    'panties_aside', 'panty_pull', 'clothes_pull', 'shirt_lift', 'skirt_lift',
    'underwear_only',
    'lingerie',
    'see_through',
    'nipple_slip',
    'wardrobe_malfunction',
    'bondage', 'bdsm', 'shibari', 'restrained', 'gag', 'ball_gag', 'leash',
    'collar_and_leash', 'futanari', 'futa', 'yaoi', 'tentacle_sex',
    'tentacles_on_female', 'spread_legs', 'spread_pussy', 'presenting',
    'bent_over', 'pregnant', 'lactation', 'inflation', 'body_writing',
    'netorare', 'incest', 'bestiality', 'zoophilia', 'stripping', 'strip_tease',
    'implied_sex', 'after_sex', 'pinup', 'sexually_suggestive', 'fetish',
    // Waste and fluids fetishes.
    'scat', 'feces', 'urine', 'peeing', 'pee', 'watersports', 'diaper', 'vore',
    // Gore and violence.
    'gore', 'guro', 'blood_on_face', 'decapitation', 'dismemberment',
    'disembowelment', 'intestines', 'organs', 'corpse', 'severed_head',
    'severed_limb', 'suicide', 'self_harm', 'cutting', 'torture', 'snuff',
    'execution', 'hanging', 'impalement', 'cannibalism',
  };

  /// Extra tags blocked on Idol Complex, which shows real people.
  static const realPersonBlockedTags = {
    'swimsuit',
    'bikini',
    'one_piece_swimsuit',
    'micro_bikini',
    'underwear',
    'panties',
    'bra',
    'cleavage',
    'gravure',
    'sideboob',
    'underboob',
    'wet_clothes',
    'bathing',
    'bath',
    'shower',
    'bed',
    'on_bed',
    'lying',
    'midriff',
    'navel',
    'thighs',
    'thighhighs',
    'pantyhose',
    'ass',
    'breasts',
    'large_breasts',
    'huge_breasts',
    'bodysuit',
    'leotard',
    'bunny_girl',
    'school_swimsuit',
    'towel',
    'cosplay_lingerie',
    'idol_photobook',
  };

  // Families of tags named by a shared start or end.
  static const _blockedPrefixes = [
    'nude_',
    'nipple_',
    'penis_',
    'pussy_',
    'vaginal_',
    'anal_',
    'cum_',
    'sex_',
    'futanari_',
    'hentai_',
    'nsfw_',
    'porn_',
    'gore_',
    'guro_',
    'lolicon_',
    'shotacon_',
  ];
  static const _blockedSuffixes = [
    '_sex',
    '_nude',
    '_nudity',
    '_penis',
    '_pussy',
    '_nipples',
    '_cum',
    '_bondage',
    '_gore',
    '_rape',
    '_masturbation',
    '_fellatio',
    '_paizuri',
  ];
}

/// The website is not part of this edition.
class EditionBoardException implements Exception {
  const EditionBoardException(this.board);
  final Board board;
}

/// A [BoardRepository] that holds every request to [policy]: websites the
/// edition does not offer are refused before any request, every search is
/// sanitized and carries the website's safe rating, and blocked tag
/// suggestions are dropped. Post eligibility is checked by the caller,
/// which needs the unfiltered count to know whether more pages exist.
class PolicyBoardRepository implements BoardRepository {
  PolicyBoardRepository(this._inner, this.policy);
  final BoardRepository _inner;
  final ContentPolicy policy;

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
  }) {
    if (!policy.offers(board)) {
      return Future.error(EditionBoardException(board));
    }
    final rating = policy.forcedRatingTag(board);
    return _inner.fetch(
      board: board,
      tags: [
        ...policy.sanitize(tags, board: board).tags,
        ?rating,
      ],
      limit: limit,
      page: page,
      random: random,
      randomSeed: randomSeed,
      credentials: policy.allowsSignIn(board) ? credentials : null,
      feed: feed,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> autocomplete({
    required Board board,
    required String query,
    required int limit,
    Credentials? credentials,
  }) async {
    if (!policy.offers(board)) throw EditionBoardException(board);
    if (policy.sanitize([query], board: board).tags.isEmpty) return const [];
    final suggestions = await _inner.autocomplete(
      board: board,
      query: query,
      limit: limit,
      credentials: policy.allowsSignIn(board) ? credentials : null,
    );
    return suggestions
        .where((map) {
          final name = '${map['name'] ?? map['tag'] ?? map['value'] ?? ''}';
          return policy.sanitize([name], board: board).tags.isNotEmpty;
        })
        .toList(growable: false);
  }
}
