import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../core/services.dart';
import 'media_image.dart';
import 'media_viewer.dart';
import 'shorts_library.dart';
import 'site_catalog.dart';
import 'tag_input.dart';
import 'theme.dart';

/// booruShorts: a full-screen feed of videos from every usable website,
/// swiped vertically. See docs/booru-shorts.md.
class ShortsScreen extends StatefulWidget {
  const ShortsScreen({super.key, required this.state});
  final AppState state;

  @override
  State<ShortsScreen> createState() => _ShortsScreenState();
}

class _ShortsScreenState extends State<ShortsScreen>
    with WidgetsBindingObserver {
  late final ShortsFeed _feed = widget.state.shortsFeed();
  final _pages = PageController();
  final _screenAwake = ScreenAwakeService();
  final _device = DeviceService();

  // Players for the previous, current, and next video, by post identity.
  final Map<String, _Clip> _clips = {};
  final Set<String> _revealed = {};
  List<Board> _available = const [];
  bool _ready = false;
  int _index = 0;
  late bool _muted = widget.state.settings.shortsMuted;
  bool _userPaused = false;
  AppLifecycleState _lifecycle =
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
  // Picture-in-picture keeps playing while the app is inactive.
  late bool _pip = _device.pictureInPicture.value;
  bool get _resumed =>
      _lifecycle == AppLifecycleState.resumed ||
      (_pip && _lifecycle == AppLifecycleState.inactive);
  // The last picture-in-picture state sent, so playback ticks do not resend.
  String? _pipSent;
  // Set while the share sheet or a browser opens, so leaving for them does
  // not shrink into picture-in-picture.
  int _leaving = 0;
  ShortsMode _mode = ShortsMode.forYou;
  final Set<String> _liked = {};
  bool _autoScroll = false;
  // Watch time of the current video, reported when it is left.
  _Watch? _watch;
  // Pushed screens (full details) pause playback while they are open.
  int _suspended = 0;
  bool _metered = false;
  bool _sharing = false;
  VideoPlayerController? _watched;
  bool _advancing = false;

  // Filters for this visit only: one tag, or one website.
  String? _tagFilter;
  Board? _onlyBoard;
  // The feed before a tag filter, so back or clearing it returns there.
  ({ShortsFeedSnapshot feed, int index, Board? only})? _beforeFilter;

  AppSettings get _settings => widget.state.settings;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_resumed) _screenAwake.setEnabled(true);
    _device.pictureInPicture.addListener(_pipChanged);
    _feed.addListener(_syncClips);
    if (_settings.dataSaver == DataSaverMode.mobileData) {
      _device.isMeteredNetwork().then((metered) {
        if (mounted) _metered = metered;
      });
    }
    widget.state.shortsBoards().then((boards) {
      if (!mounted) return;
      setState(() {
        _available = boards;
        _ready = true;
      });
      _start();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    _screenAwake.setEnabled(_resumed);
    _applyPlayback();
  }

  void _pipChanged() {
    if (!mounted) return;
    setState(() => _pip = _device.pictureInPicture.value);
    _applyPlayback();
  }

  @override
  void dispose() {
    _reportWatch();
    WidgetsBinding.instance.removeObserver(this);
    _device.pictureInPicture.removeListener(_pipChanged);
    if (_pipSent != null) _device.setPictureInPicture(auto: false);
    _screenAwake.setEnabled(false);
    _watched?.removeListener(_onTick);
    for (final clip in _clips.values) {
      clip.dispose();
    }
    _clips.clear();
    _feed.removeListener(_syncClips);
    _feed.dispose();
    _pages.dispose();
    super.dispose();
  }

  /// Starts the feed over with the saved tags (or this visit's filter) on
  /// the available websites (or the one chosen for this visit).
  void _start() {
    _reportWatch();
    _disposeClips();
    _index = 0;
    _userPaused = false;
    if (_pages.hasClients) _pages.jumpToPage(0);
    final filter = _tagFilter;
    final only = _onlyBoard;
    _feed.start(
      tags: filter != null
          ? [filter]
          : _mode == ShortsMode.following
          ? _settings.shortsFollowing
          : _settings.shortsTags,
      boards: only != null ? [only] : _available,
      mode: _mode,
    );
  }

  void _setMode(ShortsMode mode) {
    if (mode == _mode) return;
    setState(() {
      _mode = mode;
      _tagFilter = null;
      _beforeFilter = null;
    });
    _start();
  }

  /// Reports the current video's watch time, once.
  void _reportWatch() {
    final watch = _watch;
    _watch = null;
    if (watch == null) return;
    _feed.watched(
      watch.saved,
      ShortsWatch(
        played: watch.played,
        duration: watch.duration,
        loops: watch.loops,
        visible:
            watch.played > Duration.zero || !_hiddenBehindBlur(watch.saved),
      ),
    );
  }

  /// Starts timing the current video when it changed.
  void _trackCurrent() {
    final posts = _feed.posts;
    final saved = _index < posts.length ? posts[_index] : null;
    if (_watch?.saved.identity == saved?.identity) return;
    _reportWatch();
    if (saved != null) _watch = _Watch(saved);
  }

  void _disposeClips() {
    _watched?.removeListener(_onTick);
    _watched = null;
    for (final clip in _clips.values) {
      clip.dispose();
    }
    _clips.clear();
  }

  /// The highest rendition tier Shorts streams: the viewer's quality
  /// setting capped at 720p, and at 480p while the data saver applies.
  int get _maxQuality {
    final chosen = _settings.videoQuality;
    var cap = chosen <= 0 ? 720 : min(chosen, 720);
    final saving = switch (_settings.dataSaver) {
      DataSaverMode.off => false,
      DataSaverMode.mobileData => _metered,
      DataSaverMode.always => true,
    };
    if (saving) cap = min(cap, 480);
    return cap;
  }

  String? get _currentKey {
    final posts = _feed.posts;
    return _index < posts.length ? posts[_index].identity : null;
  }

  /// Keeps players for the previous, current, and next videos only.
  void _syncClips() {
    if (!mounted) return;
    final posts = _feed.posts;
    final wanted = <String, SavedPost>{};
    for (final i in [_index, _index + 1, _index - 1]) {
      if (i < 0 || i >= posts.length) continue;
      wanted[posts[i].identity] = posts[i];
    }
    for (final key in _clips.keys.toList()) {
      if (wanted.containsKey(key)) continue;
      final clip = _clips.remove(key)!;
      if (identical(clip.controller, _watched)) {
        _watched?.removeListener(_onTick);
        _watched = null;
      }
      clip.dispose();
    }
    for (final entry in wanted.entries) {
      _clips.putIfAbsent(entry.key, () {
        final saved = widget.state.displayReady(entry.value);
        final clip = _Clip(
          saved,
          maxQuality: _maxQuality,
          onChanged: _clipChanged,
          streamable: ({required force}) => widget.state.streamablePost(
            saved.post,
            board: saved.board,
            force: force,
          ),
        );
        clip.start();
        return clip;
      });
    }
    // A video that failed while it waited (often for a decoder the other
    // players held) gets one more try once it is shown.
    final current = _clips[_currentKey];
    if (current != null && current.failed && !current.retried) current.retry();
    _applyPlayback();
  }

  void _clipChanged() {
    if (!mounted) return;
    setState(() {});
    _applyPlayback();
  }

  bool _shouldBlur(MediaPost post) {
    final rating = post.rating.trim().toLowerCase();
    if (rating.contains('explicit') || rating == 'e') {
      return _settings.blurExplicit;
    }
    return (rating.contains('questionable') || rating == 'q') &&
        _settings.blurQuestionable;
  }

  bool _hiddenBehindBlur(SavedPost saved) =>
      _shouldBlur(saved.post) && !_revealed.contains(saved.identity);

  /// Plays the current video when nothing stops it and pauses the rest.
  void _applyPlayback() {
    _trackCurrent();
    final current = _currentKey;
    final loop = !_settings.shortsAutoAdvance && !_autoScroll;
    var playing = false;
    for (final entry in _clips.entries) {
      final clip = entry.value;
      final controller = clip.controller;
      if (controller == null) continue;
      clip.configure(muted: _muted, loop: loop);
      final play =
          entry.key == current &&
          _resumed &&
          _suspended == 0 &&
          !_userPaused &&
          !_hiddenBehindBlur(clip.saved);
      if (play && !controller.value.isPlaying) controller.play();
      if (!play && controller.value.isPlaying) controller.pause();
      if (play) playing = true;
      if (entry.key == current && !identical(controller, _watched)) {
        _watched?.removeListener(_onTick);
        _watched = controller..addListener(_onTick);
      }
    }
    // The current video has no player yet: stop listening to the previous
    // one, whose seek back to the start would otherwise be timed.
    if (_clips[current]?.controller == null && _watched != null) {
      _watched?.removeListener(_onTick);
      _watched = null;
    }
    _syncPip(playing);
  }

  bool get _pipAllowed =>
      !_settings.appLock && !_settings.secureScreen && !_pip;

  /// Lets leaving the app shrink it into picture-in-picture while a video
  /// plays (Settings › booruShorts), shaped like the video.
  Future<void> _syncPip(bool playing) async {
    final auto =
        playing &&
        _settings.shortsPictureInPicture &&
        _pipAllowed &&
        _leaving == 0 &&
        _suspended == 0;
    final (width, height) = _pipShape;
    final key = auto ? '$width:$height' : 'off';
    if (key == _pipSent || (_pipSent == null && !auto)) return;
    _pipSent = key;
    await _device.setPictureInPicture(auto: auto, width: width, height: height);
  }

  (int, int) get _pipShape {
    final size = _clips[_currentKey]?.controller?.value.size ?? Size.zero;
    return size.width >= 1 && size.height >= 1
        ? (size.width.round(), size.height.round())
        : (9, 16);
  }

  Future<void> _enterPip() async {
    if (!_pipAllowed) {
      _notify(
        'Picture-in-picture is off while the app lock or Hide in recent apps is on.',
      );
      return;
    }
    final (width, height) = _pipShape;
    if (!await _device.enterPictureInPicture(width: width, height: height)) {
      _notify('Picture-in-picture is not available on this device.');
    }
  }

  /// Runs [action] (the share sheet, a browser) without shrinking into
  /// picture-in-picture when it takes the app to the background.
  Future<T> _leaveFor<T>(Future<T> Function() action) async {
    _leaving++;
    await _syncPip(false);
    try {
      return await action();
    } finally {
      _leaving--;
      if (mounted) _applyPlayback();
    }
  }

  /// Times the current video, and moves on when it ends (auto-advance or
  /// auto-scroll) or plays past the auto-scroll limit.
  void _onTick() {
    final controller = _watched;
    if (controller == null || !mounted) return;
    final watch = _watch;
    if (watch != null &&
        watch.saved.identity == _currentKey &&
        identical(controller, _clips[_currentKey]?.controller)) {
      watch.tick(controller.value);
      final limit = _settings.shortsAutoScrollSeconds;
      if (_autoScroll &&
          limit > 0 &&
          !_advancing &&
          watch.played >= Duration(seconds: limit)) {
        _advancing = true;
        _next();
        return;
      }
    }
    if (!(_settings.shortsAutoAdvance || _autoScroll) || _advancing) return;
    final value = controller.value;
    if (!value.isInitialized ||
        value.isPlaying ||
        value.duration <= Duration.zero ||
        value.position < value.duration - const Duration(milliseconds: 150)) {
      return;
    }
    _advancing = true;
    _next();
  }

  void _next() {
    if (!_pages.hasClients) {
      _advancing = false;
      return;
    }
    final from = _index;
    if (_settings.reduceMotion) {
      // The page after the last post is the loader, as with nextPage.
      if (from + 1 <= _feed.posts.length) {
        _pages.jumpToPage(from + 1);
      } else {
        _advancing = false;
      }
      return;
    }
    _pages
        .nextPage(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() {
          // Nowhere to go: let the next ending try again.
          if (mounted && _index == from) _advancing = false;
        });
  }

  void _handlePageChanged(int index) {
    // Before the seek below, which would read as a replay.
    _reportWatch();
    final previous = _clips[_currentKey];
    previous?.controller?.pause();
    previous?.controller?.seekTo(Duration.zero);
    _index = index;
    _userPaused = false;
    _advancing = false;
    final posts = _feed.posts;
    if (index >= posts.length - 3) _feed.loadMore();
    if (index < posts.length) {
      widget.state.recordBrowsedTags(posts[index].post.tags);
    }
    _syncClips();
    setState(() {});
  }

  /// Auto-scroll: moves on by itself when a video ends, or after the time
  /// limit in Settings › booruShorts.
  void _toggleAutoScroll() {
    setState(() {
      _autoScroll = !_autoScroll;
      _advancing = false;
    });
    _applyPlayback();
    if (_autoScroll) {
      final limit = _settings.shortsAutoScrollSeconds;
      _notify(
        limit > 0
            ? 'Auto-scroll is on: each video plays for up to $limit seconds.'
            : 'Auto-scroll is on: each video plays to the end.',
      );
    }
  }

  /// Opens a screen over Shorts, pausing playback while it is open.
  Future<void> _openPage(Future<void> Function() open) async {
    _suspended++;
    _applyPlayback();
    await open();
    _suspended--;
    if (mounted) _applyPlayback();
  }

  void _togglePlay() {
    final controller = _clips[_currentKey]?.controller;
    if (controller == null) return;
    _userPaused = controller.value.isPlaying;
    _applyPlayback();
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    widget.state.setShortsMuted(_muted);
    _applyPlayback();
  }

  void _reveal(SavedPost saved) {
    setState(() => _revealed.add(saved.identity));
    _applyPlayback();
  }

  void _filterTag(String tag) {
    widget.state.learnShortsTag(tag);
    _beforeFilter ??= (feed: _feed.snapshot(), index: _index, only: _onlyBoard);
    setState(() {
      _tagFilter = tag;
      _onlyBoard = null;
    });
    _start();
  }

  /// Leaves the tag filter for the feed as it was before it, at the video
  /// that was showing.
  void _clearTagFilter() {
    final before = _beforeFilter;
    if (before == null) {
      setState(() => _tagFilter = null);
      _start();
      return;
    }
    _reportWatch();
    _disposeClips();
    _userPaused = false;
    _advancing = false;
    setState(() {
      _tagFilter = null;
      _beforeFilter = null;
      _onlyBoard = before.only;
      _index = before.index;
    });
    _feed.restore(before.feed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pages.hasClients && _pages.page?.round() != _index) {
        _pages.jumpToPage(_index);
      }
    });
  }

  void _setOnlyBoard(Board? board) {
    setState(() => _onlyBoard = board);
    _start();
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _open(String url, String failure) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !['https', 'http'].contains(uri.scheme)) return;
    try {
      final opened = await _leaveFor(
        () => launchUrl(uri, mode: LaunchMode.externalApplication),
      );
      if (!opened) throw StateError('Unavailable');
    } catch (_) {
      _notify(failure);
    }
  }

  Future<void> _favorite(SavedPost saved) {
    final saving = !widget.state.isFavorite(saved.post, board: saved.board);
    _feed.feedback(saved, ShortsSignal.favorite, undo: !saving);
    return widget.state.toggleFavorite(saved.post, board: saved.board);
  }

  void _like(SavedPost saved) {
    final liked = _liked.contains(saved.identity);
    setState(() {
      if (liked) {
        _liked.remove(saved.identity);
      } else {
        _liked.add(saved.identity);
      }
    });
    _feed.feedback(saved, ShortsSignal.like, undo: liked);
  }

  /// Shows fewer videos like [saved] and moves on, with an undo.
  void _dislike(SavedPost saved) {
    if (_liked.remove(saved.identity)) {
      _feed.feedback(saved, ShortsSignal.like, undo: true);
    }
    _feed.feedback(saved, ShortsSignal.dislike);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Showing fewer videos like this.'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () =>
                _feed.feedback(saved, ShortsSignal.dislike, undo: true),
          ),
        ),
      );
    _next();
  }

  /// Hold a tag: show Shorts with it, follow it, or never see it again.
  Future<void> _tagMenu(String tag) async {
    final following = widget.state.followsShortsTag(tag);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          key: const ValueKey('shorts_tag_menu'),
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                '#${_display(tag)}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.filter_alt_outlined),
              title: const Text('Show booruShorts with this tag'),
              onTap: () => Navigator.pop(context, 'filter'),
            ),
            ListTile(
              key: const ValueKey('shorts_tag_follow'),
              leading: Icon(
                following
                    ? Icons.person_remove_outlined
                    : Icons.person_add_alt_1_outlined,
              ),
              title: Text(following ? 'Unfollow' : 'Follow'),
              subtitle: const Text('Followed tags fill the Following tab'),
              onTap: () => Navigator.pop(context, 'follow'),
            ),
            ListTile(
              key: const ValueKey('shorts_tag_mute'),
              leading: const Icon(Icons.not_interested_rounded),
              title: const Text('Not interested'),
              subtitle: const Text('Never show videos with this tag here'),
              onTap: () => Navigator.pop(context, 'mute'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'filter':
        _filterTag(tag);
      case 'follow':
        await widget.state.toggleShortsFollow(tag);
        if (!mounted) return;
        _notify(
          following
              ? 'Unfollowed #${_display(tag)}.'
              : 'Following #${_display(tag)}. Find it in the Following tab.',
        );
        if (_mode == ShortsMode.following && _tagFilter == null) _start();
      case 'mute':
        await _feed.muteTag(tag);
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('You won\'t see #${_display(tag)} here again.'),
              action: SnackBarAction(
                label: 'Undo',
                onPressed: () => widget.state.unmuteShortsTag(tag),
              ),
            ),
          );
    }
  }

  /// Why the details sheet says [saved] was picked, if it was.
  String? _why(SavedPost saved) {
    if (_mode == ShortsMode.following) {
      return _tagFilter == null ? 'From tags you follow.' : null;
    }
    if (!_feed.personalized) return null;
    if (_feed.explored(saved)) {
      return 'Something new, outside your usual interests.';
    }
    final reasons = widget.state.shortsProfile.reasons(saved);
    if (reasons.isEmpty) return null;
    return 'Because you like ${reasons.map((tag) => '#${_display(tag)}').join(', ')}.';
  }

  /// Queues the video in the Download Manager.
  Future<void> _download(SavedPost saved) async {
    if (_downloadingClip(saved)) return;
    final task = widget.state.downloads.add(saved);
    setState(() {});
    final result = await task.settled;
    if (mounted) setState(() {});
    switch (result) {
      case DownloadResult.saved:
        _feed.feedback(saved, ShortsSignal.download);
        _notify(
          _settings.autoFavoriteOnDownload
              ? 'Video saved to your download folder and favorited.'
              : 'Video saved to your download folder.',
        );
      case DownloadResult.folderLost:
        _notify(
          'Folder access expired. Choose your download folder again in Settings.',
        );
      case DownloadResult.failed:
        _notify(
          'Download failed. Check your connection, folder access, and free space.',
        );
      case DownloadResult.removed:
        break;
    }
  }

  bool _downloadingClip(SavedPost saved) =>
      widget.state.downloads.taskFor(saved.post, board: saved.board)?.active ??
      false;

  Future<void> _share(SavedPost saved) async {
    final url = mediaUrlOf(saved.post);
    if (url.isEmpty || _sharing) return;
    setState(() => _sharing = true);
    _notify('Preparing to share…');
    try {
      await _leaveFor(
        () => _device.shareMedia(
          url: url,
          name: mediaFileName(
            saved.board,
            saved.post,
            url,
            template: _settings.filenameTemplate,
          ),
        ),
      );
      _feed.feedback(saved, ShortsSignal.share);
      if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
    } catch (_) {
      _notify('Unable to share this video. Check your connection.');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _openFullDetails(SavedPost saved) async {
    _suspended++;
    _applyPlayback();
    final result = await Navigator.push<ViewerTagBrowse>(
      context,
      MaterialPageRoute(
        builder: (_) => MediaViewer(
          post: saved.post,
          board: saved.board,
          state: widget.state,
          savedPosts: [saved],
          initialDetails: true,
          // Shorts already played it; it plays here only when asked.
          autoPlay: false,
        ),
      ),
    );
    _suspended--;
    if (!mounted) return;
    _applyPlayback();
    if (result != null && result.mode != TagBrowseMode.exclude) {
      _filterTag(result.tag);
    }
  }

  Future<void> _showDetails(SavedPost saved) async {
    _feed.feedback(saved, ShortsSignal.details);
    final choice = await showModalBottomSheet<({String tag, bool menu})>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _ShortsDetails(
        saved: saved,
        why: _why(saved),
        onFullDetails: () {
          Navigator.pop(context);
          _openFullDetails(saved);
        },
        onOpenPost: () => _open(
          postBrowserUrl(saved.board, saved.post),
          'Unable to open this post.',
        ),
        onOpenSource: () =>
            _open(saved.post.source, 'Unable to open this source.'),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice.menu) {
      await _tagMenu(choice.tag);
    } else {
      _filterTag(choice.tag);
    }
  }

  Future<void> _showSite(SavedPost saved) async {
    final board = saved.board;
    final link = postBrowserUrl(board, saved.post);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: SiteLogo(board, size: 32, colored: true),
              title: Text(board.label),
              subtitle: Text(board.host),
            ),
            if (link.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.open_in_new_rounded),
                title: const Text('Open on website'),
                onTap: () => Navigator.pop(context, 'open'),
              ),
            if (_onlyBoard == null)
              ListTile(
                leading: const Icon(Icons.filter_alt_outlined),
                title: Text('Only ${board.label}'),
                subtitle: const Text('For this visit'),
                onTap: () => Navigator.pop(context, 'only'),
              )
            else
              ListTile(
                leading: const Icon(Icons.public_rounded),
                title: const Text('Show all websites'),
                onTap: () => Navigator.pop(context, 'all'),
              ),
            ListTile(
              leading: const Icon(Icons.block_rounded),
              title: Text('Hide ${board.label} from booruShorts'),
              subtitle: const Text('Switch it back on in Settings'),
              onTap: () => Navigator.pop(context, 'hide'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'open':
        await _open(link, 'Unable to open this post.');
      case 'only':
        _setOnlyBoard(board);
      case 'all':
        _setOnlyBoard(null);
      case 'hide':
        await widget.state.setShortsOff({..._settings.shortsOff, board});
        if (!mounted) return;
        setState(() {
          _available = _available.where((other) => other != board).toList();
          if (_onlyBoard == board) _onlyBoard = null;
          // The saved feed still has the hidden website's videos.
          _beforeFilter = null;
        });
        _start();
        _notify('${board.label} is hidden from booruShorts.');
    }
  }

  Future<void> _showMore(SavedPost saved) async {
    final link = postBrowserUrl(saved.board, saved.post);
    final uploader = saved.post.uploader.trim();
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (link.isNotEmpty) ...[
              ListTile(
                leading: const Icon(Icons.link_rounded),
                title: const Text('Copy post link'),
                onTap: () => Navigator.pop(context, 'copy'),
              ),
              if (!_settings.noShare)
                ListTile(
                  leading: const Icon(Icons.share_outlined),
                  title: const Text('Share post link'),
                  onTap: () => Navigator.pop(context, 'share_link'),
                ),
            ],
            ListTile(
              leading: const Icon(Icons.visibility_off_outlined),
              title: const Text('Hide this post'),
              onTap: () => Navigator.pop(context, 'hide'),
            ),
            if (uploader.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.person_off_outlined),
                title: Text('Hide posts by $uploader'),
                onTap: () => Navigator.pop(context, 'uploader'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: link));
        _notify('Post link copied.');
      case 'share_link':
        try {
          await _leaveFor(() => _device.shareText(link));
        } catch (_) {
          _notify('No app can share this link.');
        }
      case 'hide':
        _feed.feedback(saved, ShortsSignal.hide);
        await widget.state.hidePost(saved.post, board: saved.board);
        _notify('Post hidden.');
        _next();
      case 'uploader':
        await _hideUploader(saved, uploader);
    }
  }

  Future<void> _hideUploader(SavedPost saved, String uploader) async {
    final board = saved.board;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Hide posts by $uploader?'),
        content: Text(
          'Their posts on ${board.label} will no longer appear in feeds. Undo this in Settings › Hidden uploaders.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Hide'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.state.hideUploader(uploader, board: board);
      _notify('Posts by $uploader are hidden on ${board.label}.');
      _next();
    } catch (_) {
      _notify('Could not hide this uploader. Please try again.');
    }
  }

  /// The gear sheet: the tags Shorts searches and the ratings it keeps,
  /// editable in place. Saved and applied when the sheet closes, however
  /// it is closed.
  Future<void> _editTags() async {
    final following = _mode == ShortsMode.following;
    final before = following ? _settings.shortsFollowing : _settings.shortsTags;
    final contentBefore = _settings.shortsContent;
    var tags = before;
    var content = contentBefore;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _ShortsTagsSheet(
        tags: before,
        title: following ? 'Followed tags' : 'booruShorts tags',
        description: following
            ? 'The Following tab shows the newest videos with any of these tags, such as artists or characters.'
            : 'Shows videos with any of these tags. Leave it empty for every video.',
        autocomplete: widget.state.autocomplete,
        onChanged: (value) => tags = value,
        content: contentBefore,
        onContentChanged: (value) => content = value,
      ),
    );
    final tagsChanged = !listEquals(tags, before);
    if (!mounted || (!tagsChanged && content == contentBefore)) return;
    if (content != contentBefore) {
      await widget.state.setShortsContent(content);
    }
    if (tagsChanged) {
      if (following) {
        await widget.state.setShortsFollowing(tags);
      } else {
        await widget.state.setShortsTags(tags);
      }
    }
    if (!mounted) return;
    setState(() {
      _tagFilter = null;
      _beforeFilter = null;
    });
    _start();
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    // Back from a tag filter returns to the feed instead of leaving.
    canPop: _tagFilter == null,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _clearTagFilter();
    },
    child: AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: ListenableBuilder(
          listenable: Listenable.merge([_feed, widget.state]),
          builder: (context, _) => Stack(
            children: [
              Positioned.fill(child: _body()),
              if (!_pip)
                Positioned(left: 0, right: 0, top: 0, child: _topBar()),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _body() {
    final posts = _feed.posts;
    if (!_ready || (posts.isEmpty && (_feed.loading || _feed.hasMore))) {
      return const Center(
        child: CircularProgressIndicator(
          key: ValueKey('shorts_loading'),
          color: Colors.white,
        ),
      );
    }
    if (posts.isEmpty) return _emptyState();
    return PageView.builder(
      key: const ValueKey('shorts_pages'),
      controller: _pages,
      scrollDirection: Axis.vertical,
      physics: _pip ? const NeverScrollableScrollPhysics() : null,
      itemCount: posts.length + 1,
      onPageChanged: _handlePageChanged,
      itemBuilder: (context, index) {
        if (index >= posts.length) return _endPage();
        final saved = widget.state.displayReady(posts[index]);
        final clip = _clips[posts[index].identity];
        return _ShortsPage(
          key: ValueKey(posts[index].identity),
          saved: saved,
          controller: clip?.controller,
          failed: clip?.failed ?? false,
          active: index == _index,
          blurred: _hiddenBehindBlur(saved),
          favorite: widget.state.isFavorite(saved.post, board: saved.board),
          liked: _liked.contains(saved.identity),
          compact: _pip,
          downloading: _downloadingClip(saved),
          sharing: _sharing,
          onTogglePlay: _togglePlay,
          onRetry: () => clip?.retry(),
          onReveal: () => _reveal(saved),
          onFavorite: () => _favorite(saved),
          onLike: () => _like(saved),
          onDislike: () => _dislike(saved),
          onDetails: () => _showDetails(saved),
          onSite: () => _showSite(saved),
          onShare: _settings.noShare ? null : () => _share(saved),
          onDownload: () => _download(saved),
          onMore: () => _showMore(saved),
          onTag: _filterTag,
          onTagMenu: _tagMenu,
        );
      },
    );
  }

  Widget _endPage() {
    if (_feed.loading || _feed.hasMore) {
      if (!_feed.loading) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _feed.loadMore();
        });
      }
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    return _message(
      icon: Icons.check_circle_outline_rounded,
      text: "You're all caught up.",
      action: 'Start over',
      onAction: _start,
    );
  }

  Widget _emptyState() {
    if (_mode == ShortsMode.following &&
        _tagFilter == null &&
        _settings.shortsFollowing.isEmpty) {
      return _message(
        icon: Icons.person_add_alt_1_outlined,
        text: 'Follow artists or characters to see their newest videos here. Hold a tag in booruShorts, or add tags with the gear.',
        action: 'Add tags',
        onAction: _editTags,
      );
    }
    if (_available.isEmpty) {
      return _message(
        icon: Icons.videocam_off_outlined,
        text: 'No website with videos is available. Sign in to one, or switch websites on in Settings › booruShorts.',
      );
    }
    final errors = _feed.errors;
    if (errors.isNotEmpty) {
      return _message(
        icon: Icons.cloud_off_rounded,
        text: [
          for (final entry in errors.entries)
            '${entry.key.label}: ${entry.value}',
        ].join('\n'),
        action: 'Retry',
        onAction: _feed.retry,
      );
    }
    return _message(
      icon: Icons.search_off_rounded,
      text: _feed.tags.isEmpty
          ? 'No videos found.'
          : 'No videos found with ${_feed.tags.join(', ')}.',
      action: 'Edit tags',
      onAction: _editTags,
    );
  }

  Widget _message({
    required IconData icon,
    required String text,
    String? action,
    VoidCallback? onAction,
  }) => Center(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(32, 96, 32, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: Colors.white70),
          const SizedBox(height: 16),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, height: 1.4),
          ),
          if (action != null) ...[
            const SizedBox(height: 20),
            FilledButton.tonal(onPressed: onAction, child: Text(action)),
          ],
        ],
      ),
    ),
  );

  Widget _topBar() {
    const shadow = [Shadow(blurRadius: 8, color: Colors.black54)];
    final filter = _tagFilter;
    final only = _onlyBoard;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x99000000), Color(0x00000000)],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Back',
                    color: Colors.white,
                    icon: const Icon(Icons.arrow_back_rounded, shadows: shadow),
                    onPressed: () => Navigator.maybePop(context),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _Tab(
                            key: const ValueKey('shorts_tab_for_you'),
                            label: 'For you',
                            selected: _mode == ShortsMode.forYou,
                            onTap: () => _setMode(ShortsMode.forYou),
                          ),
                          _Tab(
                            key: const ValueKey('shorts_tab_following'),
                            label: 'Following',
                            selected: _mode == ShortsMode.following,
                            onTap: () => _setMode(ShortsMode.following),
                          ),
                        ],
                      ),
                    ),
                  ),
                  ..._topActions(),
                ],
              ),
              // Active filters sit on their own row below the bar so long
              // tags are not squeezed between the tabs and the buttons.
              if (_autoScroll || filter != null || only != null)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(6, 4, 14, 0),
                  child: Row(
                    children: [
                      if (_autoScroll)
                        _FilterChip(
                          key: const ValueKey('shorts_auto_scroll_chip'),
                          label: 'Auto-scroll',
                          onClear: _toggleAutoScroll,
                        ),
                      if (filter != null)
                        _FilterChip(
                          key: const ValueKey('shorts_tag_filter'),
                          label: filter,
                          onClear: _clearTagFilter,
                        ),
                      if (only != null)
                        _FilterChip(
                          label: only.label,
                          onClear: () => _setOnlyBoard(null),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _topActions() {
    const shadow = [Shadow(blurRadius: 8, color: Colors.black54)];
    return [
      IconButton(
        key: const ValueKey('shorts_mute'),
        tooltip: _muted ? 'Unmute' : 'Mute',
        color: Colors.white,
        icon: Icon(
          _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
          shadows: shadow,
        ),
        onPressed: _toggleMute,
      ),
      IconButton(
        key: const ValueKey('shorts_tags'),
        tooltip: _mode == ShortsMode.following
            ? 'Followed tags'
            : 'booruShorts tags',
        color: Colors.white,
        icon: const Icon(Icons.sell_outlined, shadows: shadow),
        onPressed: _editTags,
      ),
      PopupMenuButton<String>(
        key: const ValueKey('shorts_menu'),
        tooltip: 'More options',
        iconColor: Colors.white,
        icon: const Icon(Icons.settings_rounded, shadows: shadow),
        onSelected: (value) => switch (value) {
          'auto' => _toggleAutoScroll(),
          'pip' => _enterPip(),
          'history' => _openPage(
            () => openShortsHistory(context, widget.state),
          ),
          'interests' => _openPage(
            () => openShortsInterests(context, widget.state),
          ),
          _ => null,
        },
        itemBuilder: (context) => [
          // A trailing check instead of CheckedPopupMenuItem, whose space
          // reserved for the check leaves an odd indent while it is off.
          PopupMenuItem(
            key: const ValueKey('shorts_auto_scroll'),
            value: 'auto',
            child: Row(
              children: [
                const Expanded(child: Text('Auto-scroll')),
                if (_autoScroll) const Icon(Icons.check_rounded, size: 20),
              ],
            ),
          ),
          const PopupMenuItem(value: 'pip', child: Text('Picture-in-picture')),
          const PopupMenuItem(
            key: ValueKey('shorts_history_open'),
            value: 'history',
            child: Text('Watch history'),
          ),
          const PopupMenuItem(
            key: ValueKey('shorts_interests_open'),
            value: 'interests',
            child: Text('Your interests'),
          ),
        ],
      ),
    ];
  }
}

/// One video's player. Opens the rendition for [maxQuality] (or the
/// original), falling back to the original and then the first rendition
/// when one cannot be played.
class _Clip {
  _Clip(
    this.saved, {
    required this.maxQuality,
    required this.onChanged,
    required this.streamable,
  });
  final SavedPost saved;
  final int maxQuality;
  final VoidCallback onChanged;

  /// [AppState.streamablePost] for this clip's post.
  final Future<MediaPost> Function({required bool force}) streamable;
  VideoPlayerController? controller;
  bool failed = false;
  // Whether a failed clip was tried again (when shown, or Try again).
  bool retried = false;
  bool _disposed = false;
  bool? _muted, _loop;
  // Where playback was, so a player that fails after opening (a dropped
  // connection, or Android reclaiming its decoder for another player)
  // reopens there.
  Duration _position = Duration.zero;
  int _recoveries = 0;

  Future<void> start() async {
    if (await _openFirst() || _disposed) return;
    failed = true;
    onChanged();
  }

  /// Tries a clip that failed to open once more.
  void retry() {
    if (!failed || _disposed) return;
    retried = true;
    failed = false;
    _recoveries = 0;
    onChanged();
    start();
  }

  /// Whether a URL opened (at [at]), or this clip was disposed meanwhile.
  Future<bool> _openFirst({Duration at = Duration.zero}) async {
    final tried = <String>{};
    // Signed Sankaku URLs expire (403); a failed post is looked up once more.
    for (final force in saved.board.isSankakuFamily ? [false, true] : [false]) {
      final post = saved.board.isSankakuFamily
          ? await streamable(force: force)
          : saved.post;
      if (_disposed) return true;
      final variant = post.videoVariantFor(maxQuality);
      // The chosen rendition, then the original, then the first rendition
      // (usually H.264, for originals this device cannot decode).
      final urls = <String>{
        ?variant?.url,
        mediaUrlOf(post),
        if (post.videoVariants.isNotEmpty) post.videoVariants.first.url,
      };
      for (final url in urls) {
        if (!tried.add(url)) continue;
        if (await _open(url, at: at)) return true;
      }
    }
    return _disposed;
  }

  /// Whether [url] opened, or this clip was disposed meanwhile.
  Future<bool> _open(String url, {Duration at = Duration.zero}) async {
    if (_disposed) return true;
    final uri = Uri.tryParse(url);
    if (url.isEmpty || uri == null) return false;
    final video = VideoPlayerController.networkUrl(
      uri,
      httpHeaders: videoHeaders(saved.board),
    );
    try {
      await video.initialize();
      if (at > Duration.zero && !_disposed) await video.seekTo(at);
    } catch (_) {
      // dispose() never completes for a player whose creation failed.
      video.dispose().ignore();
      return false;
    }
    if (_disposed) {
      await video.dispose();
      return true;
    }
    // A new player starts with default sound and looping.
    _muted = null;
    _loop = null;
    controller = video..addListener(_watchError);
    onChanged();
    return true;
  }

  void _watchError() {
    final video = controller;
    if (video == null) return;
    final value = video.value;
    if (!value.hasError) {
      if (value.isInitialized) _position = value.position;
      return;
    }
    _recover(video);
  }

  /// Replaces a player that failed after it opened, a few times at most.
  Future<void> _recover(VideoPlayerController broken) async {
    if (_disposed || !identical(controller, broken)) return;
    broken.removeListener(_watchError);
    controller = null;
    broken.dispose().ignore();
    if (_recoveries < 3) {
      _recoveries++;
      // The preview and spinner show while it reopens.
      onChanged();
      if (await _openFirst(at: _position)) return;
    }
    if (_disposed) return;
    failed = true;
    onChanged();
  }

  /// Applies sound and looping, skipping platform calls that change
  /// nothing.
  void configure({required bool muted, required bool loop}) {
    final video = controller;
    if (video == null) return;
    if (_muted != muted) {
      _muted = muted;
      video.setVolume(muted ? 0 : 1);
    }
    if (_loop != loop) {
      _loop = loop;
      video.setLooping(loop);
    }
  }

  void dispose() {
    _disposed = true;
    controller
      ?..removeListener(_watchError)
      ..dispose();
    controller = null;
  }
}

class _ShortsPage extends StatefulWidget {
  const _ShortsPage({
    super.key,
    required this.saved,
    required this.controller,
    required this.failed,
    required this.active,
    required this.blurred,
    required this.favorite,
    required this.liked,
    required this.compact,
    required this.downloading,
    required this.sharing,
    required this.onTogglePlay,
    required this.onRetry,
    required this.onReveal,
    required this.onFavorite,
    required this.onLike,
    required this.onDislike,
    required this.onDetails,
    required this.onSite,
    required this.onShare,
    required this.onDownload,
    required this.onMore,
    required this.onTag,
    required this.onTagMenu,
  });
  final SavedPost saved;
  final VideoPlayerController? controller;
  final bool failed, active, blurred, favorite, liked, downloading, sharing;

  /// Picture-in-picture: the video only.
  final bool compact;
  final VoidCallback onTogglePlay, onRetry, onReveal, onFavorite, onLike;
  final VoidCallback onDislike;
  final VoidCallback onDetails, onSite, onDownload, onMore;

  /// Null hides the share button (Settings › No share).
  final VoidCallback? onShare;
  final ValueChanged<String> onTag, onTagMenu;

  @override
  State<_ShortsPage> createState() => _ShortsPageState();
}

class _ShortsPageState extends State<_ShortsPage> {
  int _flash = 0;
  IconData _flashIcon = Icons.play_arrow_rounded;
  // Double-tap skips ahead; the badge appears where the finger landed.
  int _skip = 0;
  Offset _skipAt = Offset.zero;
  Offset _lastDoubleTap = Offset.zero;
  bool _fast = false;

  MediaPost get _post => widget.saved.post;
  Board get _board => widget.saved.board;
  bool get _ready => widget.controller?.value.isInitialized == true;

  void _tap() {
    if (widget.blurred || !_ready) return;
    final playing = widget.controller!.value.isPlaying;
    widget.onTogglePlay();
    setState(() {
      _flash++;
      _flashIcon = playing ? Icons.pause_rounded : Icons.play_arrow_rounded;
    });
  }

  static const _skipBy = Duration(seconds: 5);

  void _doubleTap() {
    final controller = widget.controller;
    if (widget.blurred || !_ready || controller == null) return;
    final value = controller.value;
    final target = value.position + _skipBy;
    controller.seekTo(target < value.duration ? target : value.duration);
    setState(() {
      _skip++;
      _skipAt = _lastDoubleTap;
    });
  }

  void _setFast(bool fast) {
    final controller = widget.controller;
    if (!_ready || widget.blurred || controller == null) return;
    controller.setPlaybackSpeed(fast ? 2 : 1);
    setState(() => _fast = fast);
  }

  @override
  void didUpdateWidget(_ShortsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Leaving the page while holding resets the speed.
    if (!widget.active && _fast) {
      widget.controller?.setPlaybackSpeed(1);
      _fast = false;
    }
  }

  String get _preview =>
      _post.previewUrl.isNotEmpty && _post.previewUrl != _post.url
      ? _post.previewUrl
      : '';

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final controller = widget.controller;
    if (widget.compact) {
      return ColoredBox(color: Colors.black, child: _media(controller));
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_preview.isNotEmpty)
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: MediaImage(
              url: _preview,
              board: _board,
              fit: BoxFit.cover,
              maxDimension: 320,
              errorWidget: const SizedBox.shrink(),
            ),
          ),
        const ColoredBox(color: Color(0x8C000000)),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _tap,
          onDoubleTapDown: (details) => _lastDoubleTap = details.localPosition,
          onDoubleTap: _doubleTap,
          onLongPressStart: (_) => _setFast(true),
          onLongPressEnd: (_) => _setFast(false),
          onLongPressCancel: () => _setFast(false),
          child: _media(controller),
        ),
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 260,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x00000000), Color(0xB3000000)],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 16,
          right: 84,
          bottom: bottomInset + 28,
          child: _info(),
        ),
        // Scaled down to fit short screens and large text.
        Positioned(
          right: 6,
          top: MediaQuery.paddingOf(context).top + 64,
          bottom: bottomInset + 28,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.bottomCenter,
              child: _rail(),
            ),
          ),
        ),
        if (_flash > 0)
          IgnorePointer(
            child: Center(
              child: TweenAnimationBuilder<double>(
                key: ValueKey(_flash),
                tween: Tween(begin: 1, end: 0),
                duration: const Duration(milliseconds: 650),
                builder: (_, value, child) => Opacity(
                  opacity: value,
                  child: Transform.scale(
                    scale: 1 + (1 - value) * .3,
                    child: child,
                  ),
                ),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: const BoxDecoration(
                    color: Color(0x66000000),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(_flashIcon, size: 46, color: Colors.white),
                ),
              ),
            ),
          ),
        if (_skip > 0)
          Positioned(
            left: _skipAt.dx - 44,
            top: _skipAt.dy - 44,
            child: IgnorePointer(
              child: TweenAnimationBuilder<double>(
                key: ValueKey(_skip),
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 800),
                builder: (_, value, child) => Opacity(
                  opacity: value < .7 ? 1 : (1 - value) / .3,
                  child: Transform.scale(
                    scale: value < .2
                        ? value / .2 * 1.2
                        : 1.2 - (value - .2) * .25,
                    child: child,
                  ),
                ),
                child: const SizedBox.square(
                  key: ValueKey('shorts_skip'),
                  dimension: 88,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(0x66000000),
                      shape: BoxShape.circle,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.fast_forward_rounded,
                          size: 42,
                          color: Colors.white,
                        ),
                        Text(
                          '+5s',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (_fast)
          Positioned(
            // Clear of the top bar, including its row of active filters.
            top: MediaQuery.paddingOf(context).top + 112,
            left: 0,
            right: 0,
            child: const IgnorePointer(
              child: Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color(0x80000000),
                    borderRadius: BorderRadius.all(Radius.circular(20)),
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Text(
                      '2× ▸▸',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (controller != null && _ready && !widget.blurred)
          Positioned(
            left: 0,
            right: 0,
            bottom: bottomInset,
            child: _ScrubBar(controller: controller),
          ),
      ],
    );
  }

  Widget _media(VideoPlayerController? controller) {
    if (widget.blurred) {
      // Like the viewer: the poster stays recognizable as a shape only,
      // and the video waits until it is revealed.
      return Stack(
        alignment: Alignment.center,
        children: [
          if (_preview.isNotEmpty)
            Positioned.fill(
              key: const ValueKey('shorts_blurred_poster'),
              child: ClipRect(
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                  child: MediaImage(
                    url: _preview,
                    board: _board,
                    fit: BoxFit.contain,
                    maxDimension: 320,
                    errorWidget: const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          const Icon(
            Icons.visibility_off_outlined,
            size: 42,
            color: Colors.white54,
          ),
          if (widget.active)
            Padding(
              padding: const EdgeInsets.only(top: 110),
              child: FilledButton.icon(
                onPressed: widget.onReveal,
                icon: const Icon(Icons.visibility),
                label: const Text('Reveal'),
              ),
            ),
        ],
      );
    }
    if (controller != null && _ready) {
      final size = controller.value.size;
      final ratio = controller.value.aspectRatio;
      // Phone-shaped portrait video fills the screen; anything wider is
      // letterboxed so nothing important is cropped.
      final cover = ratio > 0 && ratio <= .7;
      return ClipRect(
        child: FittedBox(
          fit: cover ? BoxFit.cover : BoxFit.contain,
          child: SizedBox(
            width: size.width > 0 ? size.width : 1,
            height: size.height > 0 ? size.height : 1,
            child: VideoPlayer(controller),
          ),
        ),
      );
    }
    if (widget.failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "This video couldn't be played on this device.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
              if (!widget.compact) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const ValueKey('shorts_retry'),
                  onPressed: widget.onRetry,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Try again'),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_preview.isNotEmpty)
          MediaImage(
            url: _preview,
            board: _board,
            fit: BoxFit.contain,
            errorWidget: const SizedBox.shrink(),
          ),
        const Center(
          child: SizedBox.square(
            dimension: 36,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  Widget _info() {
    const shadow = [Shadow(blurRadius: 6, color: Colors.black87)];
    final grouped = groupedTags(_post);
    final artists = (grouped[TagCategory.artist] ?? const <TagInfo>[])
        .take(2)
        .map((tag) => tag.name)
        .toList();
    var featured = [
      ...?grouped[TagCategory.character],
      ...?grouped[TagCategory.copyright],
    ].take(3).toList();
    if (featured.isEmpty) {
      featured = (grouped[TagCategory.general] ?? const <TagInfo>[])
          .take(3)
          .toList();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          artists.isEmpty
              ? _board.label
              : '${artists.map(_display).join(', ')} · ${_board.label}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w700,
            shadows: shadow,
          ),
        ),
        if (featured.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in featured)
                Material(
                  color: const Color(0x40000000),
                  shape: const StadiumBorder(
                    side: BorderSide(color: Color(0x40FFFFFF)),
                  ),
                  child: InkWell(
                    customBorder: const StadiumBorder(),
                    onTap: () => widget.onTag(tag.name),
                    onLongPress: () => widget.onTagMenu(tag.name),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      child: Text(
                        '#${_display(tag.name)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _rail() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      _RailButton(
        key: const ValueKey('shorts_favorite'),
        icon: Icon(
          widget.favorite
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          color: widget.favorite ? const Color(0xFFFF3B5C) : Colors.white,
          size: 32,
          shadows: _RailButton.shadow,
        ),
        label: widget.favorite ? 'Saved' : 'Favorite',
        onTap: widget.onFavorite,
      ),
      _RailButton(
        key: const ValueKey('shorts_like'),
        icon: Icon(
          widget.liked ? Icons.thumb_up_rounded : Icons.thumb_up_outlined,
          color: widget.liked ? const Color(0xFF4DA3FF) : Colors.white,
          size: 28,
          shadows: _RailButton.shadow,
        ),
        label: widget.liked ? 'Liked' : 'Like',
        onTap: widget.onLike,
      ),
      _RailButton(
        key: const ValueKey('shorts_dislike'),
        icon: const Icon(
          Icons.thumb_down_outlined,
          color: Colors.white,
          size: 28,
          shadows: _RailButton.shadow,
        ),
        label: 'Not for me',
        onTap: widget.onDislike,
      ),
      _RailButton(
        key: const ValueKey('shorts_details'),
        icon: const Icon(
          Icons.info_outline_rounded,
          color: Colors.white,
          size: 30,
          shadows: _RailButton.shadow,
        ),
        label: 'Details',
        onTap: widget.onDetails,
      ),
      _RailButton(
        key: const ValueKey('shorts_site'),
        icon: SiteLogo(_board, size: 34, colored: true, showBorder: true),
        label: _board.label,
        onTap: widget.onSite,
      ),
      if (widget.onShare case final onShare?)
        _RailButton(
          icon: widget.sharing
              ? const _RailProgress()
              : const Icon(
                  Icons.share_rounded,
                  color: Colors.white,
                  size: 28,
                  shadows: _RailButton.shadow,
                ),
          label: 'Share',
          onTap: onShare,
        ),
      _RailButton(
        icon: widget.downloading
            ? const _RailProgress()
            : const Icon(
                Icons.download_rounded,
                color: Colors.white,
                size: 30,
                shadows: _RailButton.shadow,
              ),
        label: 'Download',
        onTap: widget.onDownload,
      ),
      _RailButton(
        icon: const Icon(
          Icons.more_horiz_rounded,
          color: Colors.white,
          size: 30,
          shadows: _RailButton.shadow,
        ),
        label: 'More',
        onTap: widget.onMore,
      ),
    ],
  );
}

String _display(String tag) => tag.replaceAll('_', ' ');

class _RailButton extends StatelessWidget {
  const _RailButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final Widget icon;
  final String label;
  final VoidCallback onTap;

  static const shadow = [Shadow(blurRadius: 8, color: Colors.black54)];

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 72,
    child: InkResponse(
      onTap: onTap,
      radius: 32,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: 36, child: Center(child: icon)),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                shadows: shadow,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// A tab in the top bar: For you or Following.
class _Tab extends StatelessWidget {
  const _Tab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : Colors.white70,
                fontSize: 16,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                shadows: const [Shadow(blurRadius: 8, color: Colors.black54)],
              ),
            ),
            const SizedBox(height: 3),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: 2.5,
              width: selected ? 22 : 0,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Played media time and loops for one visit to a video. Seeks (the scrub
/// bar, double-tap) are not counted, and nothing counts while paused.
class _Watch {
  _Watch(this.saved);
  final SavedPost saved;
  Duration played = Duration.zero;
  Duration duration = Duration.zero;
  int loops = 0;
  Duration? _last;

  void tick(VideoPlayerValue value) {
    if (!value.isInitialized) return;
    duration = value.duration;
    final position = value.position;
    final last = _last;
    _last = position;
    if (last == null || !value.isPlaying) return;
    final delta = position - last;
    if (delta > Duration.zero && delta <= const Duration(milliseconds: 2500)) {
      played += delta;
    } else if (delta < const Duration(seconds: -1) &&
        duration > Duration.zero &&
        last >= duration - const Duration(milliseconds: 1500) &&
        position <= const Duration(milliseconds: 1500)) {
      // From the end back to the start: a replay, not a seek.
      loops++;
    }
  }
}

class _RailProgress extends StatelessWidget {
  const _RailProgress();

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 24,
    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
  );
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({super.key, required this.label, required this.onClear});
  final String label;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 10),
    child: Material(
      color: const Color(0x59000000),
      shape: const StadiumBorder(side: BorderSide(color: Color(0x59FFFFFF))),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onClear,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _display(label),
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.close_rounded, size: 16, color: Colors.white70),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The draggable progress bar along the bottom. Touching it thickens it
/// and shows the time; dragging pauses and seeks, and releasing resumes.
class _ScrubBar extends StatefulWidget {
  const _ScrubBar({required this.controller});
  final VideoPlayerController controller;

  @override
  State<_ScrubBar> createState() => _ScrubBarState();
}

class _ScrubBarState extends State<_ScrubBar> {
  double? _drag;
  bool _resume = false;

  Duration get _duration => widget.controller.value.duration;

  void _seek(double fraction) {
    final ms = (_duration.inMilliseconds * fraction).round();
    widget.controller.seekTo(Duration(milliseconds: ms));
  }

  void _begin(double dx, double width) {
    _resume = widget.controller.value.isPlaying;
    widget.controller.pause();
    _update(dx, width);
  }

  void _update(double dx, double width) {
    if (width <= 0) return;
    final fraction = (dx / width).clamp(0.0, 1.0);
    setState(() => _drag = fraction);
    _seek(fraction);
  }

  void _end() {
    final fraction = _drag;
    setState(() => _drag = null);
    if (fraction != null) _seek(fraction);
    if (_resume) widget.controller.play();
  }

  static String _time(Duration value) {
    final minutes = value.inMinutes;
    final seconds = value.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final width = box.maxWidth;
      return GestureDetector(
        key: const ValueKey('shorts_scrub'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (details) =>
            _begin(details.localPosition.dx, width),
        onHorizontalDragUpdate: (details) =>
            _update(details.localPosition.dx, width),
        onHorizontalDragEnd: (_) => _end(),
        onHorizontalDragCancel: _end,
        onTapUp: (details) {
          if (width <= 0) return;
          _seek((details.localPosition.dx / width).clamp(0.0, 1.0));
        },
        child: ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: widget.controller,
          builder: (context, value, _) {
            final total = value.duration.inMilliseconds;
            final dragging = _drag != null;
            final played =
                _drag ??
                (total <= 0
                    ? 0.0
                    : (value.position.inMilliseconds / total).clamp(0.0, 1.0));
            var buffered = 0.0;
            for (final range in value.buffered) {
              if (total > 0) {
                buffered = max(buffered, range.end.inMilliseconds / total);
              }
            }
            final barHeight = dragging ? 6.0 : 2.5;
            return SizedBox(
              height: dragging ? 64 : 28,
              child: Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  if (dragging)
                    Positioned(
                      bottom: 18,
                      child: Text(
                        '${_time(Duration(milliseconds: (total * played).round()))} / ${_time(value.duration)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          shadows: [
                            Shadow(blurRadius: 8, color: Colors.black87),
                          ],
                        ),
                      ),
                    ),
                  // The track spans the width; played and buffered fill it
                  // from the left edge.
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: double.infinity,
                    height: barHeight,
                    margin: const EdgeInsets.only(bottom: 4),
                    color: const Color(0x33FFFFFF),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        FractionallySizedBox(
                          key: const ValueKey('shorts_scrub_buffered'),
                          alignment: Alignment.centerLeft,
                          widthFactor: buffered.clamp(0.0, 1.0),
                          child: const ColoredBox(color: Color(0x55FFFFFF)),
                        ),
                        FractionallySizedBox(
                          key: const ValueKey('shorts_scrub_played'),
                          alignment: Alignment.centerLeft,
                          widthFactor: played,
                          child: const ColoredBox(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
    },
  );
}

/// Post details for booruShorts: the essentials and grouped tags. Tapping
/// a tag closes the sheet with that tag, so Shorts can filter by it.
class _ShortsDetails extends StatelessWidget {
  const _ShortsDetails({
    required this.saved,
    required this.why,
    required this.onFullDetails,
    required this.onOpenPost,
    required this.onOpenSource,
  });
  final SavedPost saved;

  /// Why booruShorts picked this video, when it can tell.
  final String? why;
  final VoidCallback onFullDetails, onOpenPost, onOpenSource;

  static const _order = [
    TagCategory.artist,
    TagCategory.copyright,
    TagCategory.character,
    TagCategory.species,
    TagCategory.general,
    TagCategory.meta,
    TagCategory.lore,
    TagCategory.unknown,
  ];

  @override
  Widget build(BuildContext context) {
    final post = saved.post;
    final board = saved.board;
    final grouped = groupedTags(post);
    final source = Uri.tryParse(post.source.trim());
    final hasSource =
        source != null && ['http', 'https'].contains(source.scheme);
    final facts = [
      if (post.rating.trim().isNotEmpty) ('Rating', post.rating.trim()),
      ('Score', '${post.score}'),
      if (post.width > 0 && post.height > 0)
        ('Size', '${post.width} × ${post.height}'),
      if (post.uploader.trim().isNotEmpty) ('Uploader', post.uploader.trim()),
    ];
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .55,
      minChildSize: .3,
      maxChildSize: .92,
      builder: (context, scroll) => ListView(
        key: const ValueKey('shorts_details_sheet'),
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Row(
            children: [
              SiteLogo(board, size: 30, colored: true),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  post.hasId
                      ? '${board.label} · #${post.displayId}'
                      : board.label,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          if (why != null) ...[
            const SizedBox(height: 10),
            Row(
              key: const ValueKey('shorts_why'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.auto_awesome_outlined, size: 16, color: ink(.54)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    why!,
                    style: TextStyle(color: ink(.70), fontSize: 13),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 18,
            runSpacing: 8,
            children: [
              for (final (label, value) in facts)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(color: ink(.54), fontSize: 12),
                    ),
                    Text(value, style: TextStyle(color: ink(.87))),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: onFullDetails,
                icon: const Icon(Icons.article_outlined),
                label: const Text('Open full details'),
              ),
              if (postBrowserUrl(board, post).isNotEmpty)
                OutlinedButton.icon(
                  onPressed: onOpenPost,
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: const Text('Website'),
                ),
              if (hasSource)
                OutlinedButton.icon(
                  onPressed: onOpenSource,
                  icon: const Icon(Icons.link_rounded),
                  label: const Text('Source'),
                ),
            ],
          ),
          for (final category in _order)
            if (grouped[category]?.isNotEmpty == true) ...[
              const SizedBox(height: 16),
              Text(
                category.label,
                style: TextStyle(
                  color: ink(.54),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final tag in grouped[category]!)
                    GestureDetector(
                      onLongPress: () =>
                          Navigator.pop(context, (tag: tag.name, menu: true)),
                      child: ActionChip(
                        label: Text(
                          _display(tag.name),
                          style: TextStyle(color: tagColor(category)),
                        ),
                        tooltip: 'Show booruShorts with this tag. Hold to follow or mute it.',
                        onPressed: () => Navigator.pop(context, (
                          tag: tag.name,
                          menu: false,
                        )),
                      ),
                    ),
                ],
              ),
            ],
        ],
      ),
    );
  }
}

/// The gear sheet: the tags booruShorts searches and the ratings it
/// keeps. Reports every edit, including a tag still being typed, so
/// closing the sheet any way keeps it.
class _ShortsTagsSheet extends StatefulWidget {
  const _ShortsTagsSheet({
    required this.tags,
    required this.title,
    required this.description,
    required this.autocomplete,
    required this.onChanged,
    required this.content,
    required this.onContentChanged,
  });
  final List<String> tags;
  final String title, description;
  final Future<List<TagSuggestion>> Function(String query) autocomplete;
  final ValueChanged<List<String>> onChanged;
  final ShortsContent content;
  final ValueChanged<ShortsContent> onContentChanged;

  @override
  State<_ShortsTagsSheet> createState() => _ShortsTagsSheetState();
}

class _ShortsTagsSheetState extends State<_ShortsTagsSheet> {
  late List<String> _tags = List.of(widget.tags);
  late ShortsContent _content = widget.content;
  String _draft = '';

  List<String> get _result {
    final draft = _draft.trim();
    return [..._tags, if (draft.isNotEmpty && !_tags.contains(draft)) draft];
  }

  void _report() => widget.onChanged(_result);

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: EdgeInsets.fromLTRB(
      20,
      0,
      20,
      16 + MediaQuery.viewInsetsOf(context).bottom,
    ),
    child: Column(
      key: const ValueKey('shorts_tags_sheet'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          widget.description,
          style: TextStyle(color: ink(.60), fontSize: 13),
        ),
        const SizedBox(height: 14),
        TagInput(
          tags: _tags,
          onChanged: (tags) {
            setState(() => _tags = tags);
            _report();
          },
          onDraftChanged: (draft) {
            _draft = draft;
            _report();
          },
          autocomplete: widget.autocomplete,
          searchStyle: false,
          hint: 'Add a tag, then press space',
        ),
        const SizedBox(height: 16),
        Text('Content', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<ShortsContent>(
            key: const ValueKey('shorts_content'),
            showSelectedIcon: false,
            segments: [
              for (final value in ShortsContent.values)
                ButtonSegment(value: value, label: Text(value.label)),
            ],
            selected: {_content},
            onSelectionChanged: (choice) {
              setState(() => _content = choice.single);
              widget.onContentChanged(_content);
            },
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            if (_tags.isNotEmpty)
              TextButton(
                onPressed: () {
                  setState(() => _tags = []);
                  _report();
                },
                child: const Text('Clear all'),
              ),
            const Spacer(),
            FilledButton(
              key: const ValueKey('shorts_tags_done'),
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      ],
    ),
  );
}
