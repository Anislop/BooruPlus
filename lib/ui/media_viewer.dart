import 'dart:async';
import 'dart:ui';

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../core/services.dart';
import 'downloads.dart';
import 'home.dart';
import 'media_image.dart';
import 'multi_search.dart';
import 'site_catalog.dart';
import 'theme.dart';

/// How a tag chosen in the viewer changes the search.
enum TagBrowseMode {
  /// Search the tag on its own.
  replace,

  /// Add the tag to the current search.
  add,

  /// Exclude the tag from the current search.
  exclude,
}

/// Returned when a tag is chosen, so the caller can search it and later
/// reopen the viewer on the post the user left from.
class ViewerTagBrowse {
  const ViewerTagBrowse(
    this.tag,
    this.index, {
    this.mode = TagBrowseMode.replace,
  });
  final String tag;
  final int index;
  final TagBrowseMode mode;
}

class MediaViewer extends StatefulWidget {
  const MediaViewer({
    super.key,
    required this.post,
    required this.board,
    required this.state,
    this.posts = const [],
    this.savedPosts = const [],
    this.initialIndex = 0,
    this.initialDetails = false,
    this.allSites = false,
    this.autoPlay = true,
  });
  final MediaPost post;
  final Board board;
  final AppState state;
  final List<MediaPost> posts;
  final List<SavedPost> savedPosts;
  final int initialIndex;

  /// Opens with the details panel showing.
  final bool initialDetails;

  /// Opened from Search all sites, which searches a chosen tag itself.
  final bool allSites;

  /// Whether the first post's video starts by itself. Off, it waits for
  /// the play button (opened from booruShorts, which already played it).
  final bool autoPlay;
  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<MediaViewer> with WidgetsBindingObserver {
  VideoPlayerController? _video;
  ChewieController? _player;
  late final PageController _pages;
  String? _videoError;
  bool _sharing = false;
  bool _details = false;

  // Heights of the controls and the details bar below the media. The media
  // keeps the space they take while the details are closed; opening the
  // details overlays it instead of shrinking it.
  double _controlsHeight = 0;
  double _detailsBarHeight = 0;
  bool _muted = false;
  late int _index;
  late int _quality;
  Offset? _pointerDown;
  int _pointers = 0;
  bool _multiTouch = false;
  bool _zoomed = false;
  int _videoGeneration = 0;
  int _streamQuality = 0;
  // The rendition streamed in place of an original this device could not
  // play, if any.
  VideoVariant? _streamFallback;
  // Where the video was, so a player that fails after opening (a dropped
  // connection, or Android reclaiming its decoder for another player)
  // reopens there, a few times per page.
  Duration _videoPosition = Duration.zero;
  bool _videoPlaying = false;
  int _videoRecoveries = 0;
  // The first video waits for the play button (MediaViewer.autoPlay).
  late bool _holdVideo = !widget.autoPlay;
  bool _revealed = false;
  // Slideshow: advances after the interval, or when a video ends.
  bool _slideshow = false;
  Timer? _slideshowTimer;
  // Data saver: whether the network is metered, and the pages whose
  // original was asked for anyway.
  bool _metered = false;
  final Set<int> _originalsRequested = {};
  bool _findingElsewhere = false;
  // Parent/child and related post lookups, by post, loaded when the
  // details open.
  final Map<String, Future<({MediaPost? parent, List<MediaPost> children})>>
  _families = {};
  final Map<String, Future<List<MediaPost>>> _related = {};
  // Original media sizes, by post, asked for once the details open.
  final Map<String, Future<int?>> _sizes = {};
  final _screenAwake = ScreenAwakeService();
  final _device = DeviceService();
  AppLifecycleState _lifecycle =
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    _index = _itemCount == 0
        ? 0
        : widget.initialIndex.clamp(0, _itemCount - 1).toInt();
    _quality = widget.state.settings.videoQuality;
    _details = widget.initialDetails;
    _pages = PageController(initialPage: _index);
    WidgetsBinding.instance.addObserver(this);
    if (_lifecycle == AppLifecycleState.resumed) {
      _screenAwake.setEnabled(true);
    }
    widget.state.recordBrowsedTags(_post.tags);
    HardwareKeyboard.instance.addHandler(_handleKey);
    if (widget.state.settings.dataSaver == DataSaverMode.mobileData) {
      _device.isMeteredNetwork().then((metered) {
        if (mounted && metered != _metered) setState(() => _metered = metered);
      });
    }
    _ensureVideo();
    _resolveMedia(_index);
  }

  /// Realbooru lists thumbnails only: asks for the file of the post at
  /// [index] and the next one (which the pager builds ahead), and shows it
  /// once it arrives.
  void _resolveMedia(int index) {
    for (final target in [index, index + 1]) {
      if (target >= _pageCount) continue;
      final board = _boardAt(target);
      if (!board.listsThumbnailsOnly) continue;
      widget.state.resolveMedia(_postAt(target), board: board).then((changed) {
        if (!mounted || !changed) return;
        setState(() {});
        if (target != _index) return;
        // While paging, the scroll end starts the video instead.
        if (!_pages.hasClients || !_pages.position.isScrollingNotifier.value) {
          _ensureVideo();
        }
        _scheduleSlide();
      });
    }
  }

  /// Volume keys page between posts when that setting is on. Handled keys
  /// do not change the volume.
  bool _handleKey(KeyEvent event) {
    if (!widget.state.settings.volumeKeyPaging || !mounted) return false;
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    final key = event.logicalKey;
    final down = key == LogicalKeyboardKey.audioVolumeDown;
    if (!down && key != LogicalKeyboardKey.audioVolumeUp) return false;
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      _turnPage(down ? 1 : -1);
    }
    return true;
  }

  bool get _reduceMotion => widget.state.settings.reduceMotion;

  void _turnPage(int delta) {
    final target = _index + delta;
    if (_zoomed || target < 0 || target >= _pageCount) return;
    if (_reduceMotion) {
      _pages.jumpToPage(target);
      return;
    }
    _pages.animateToPage(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  /// Whether the viewer shows the website's sample for [post] at [index].
  bool _savesData(MediaPost post, int index) {
    if (post.isVideo ||
        post.sampleUrl.isEmpty ||
        _originalsRequested.contains(index)) {
      return false;
    }
    return switch (widget.state.settings.dataSaver) {
      DataSaverMode.off => false,
      DataSaverMode.mobileData => _metered,
      DataSaverMode.always => true,
    };
  }

  void _toggleSlideshow() {
    setState(() => _slideshow = !_slideshow);
    _video?.setLooping(!_slideshow);
    _scheduleSlide();
    _notify(_slideshow ? 'Slideshow started.' : 'Slideshow stopped.');
  }

  /// Images advance after the interval; videos when they finish (see
  /// [_watchVideoEnd]).
  void _scheduleSlide() {
    _slideshowTimer?.cancel();
    _slideshowTimer = null;
    if (!_slideshow) return;
    // A playable video moves on when it ends instead.
    final post = _post;
    if (post.isVideo &&
        _videoError == null &&
        !(_shouldBlur(post) && !_revealed)) {
      return;
    }
    _slideshowTimer = Timer(
      Duration(seconds: widget.state.settings.slideshowSeconds),
      _advanceSlide,
    );
  }

  void _advanceSlide() {
    if (!mounted || !_slideshow) return;
    if (_index + 1 >= _pageCount) {
      setState(() => _slideshow = false);
      _notify('Slideshow finished.');
      return;
    }
    // Wait while a gesture holds the page; try again after the interval.
    if (_zoomed || _pointers > 0 || _lifecycle != AppLifecycleState.resumed) {
      _scheduleSlide();
      return;
    }
    _turnPage(1);
  }

  void _watchVideoEnd() {
    final video = _video;
    if (!_slideshow || video == null) return;
    final value = video.value;
    if (value.isInitialized &&
        !value.isPlaying &&
        value.duration > Duration.zero &&
        value.position >= value.duration - const Duration(milliseconds: 300)) {
      _advanceSlide();
    }
  }

  int get _itemCount => widget.savedPosts.isNotEmpty
      ? widget.savedPosts.length
      : widget.posts.length;

  int get _pageCount => _itemCount == 0 ? 1 : _itemCount;

  Board _boardAt(int index) => widget.savedPosts.isNotEmpty
      ? widget.savedPosts[index].board
      : widget.board;

  MediaPost _postAt(int index) => widget.savedPosts.isNotEmpty
      ? widget.state.displayReady(widget.savedPosts[index]).post
      : widget.state.displayPost(
          widget.posts.isEmpty ? widget.post : widget.posts[index],
          board: widget.board,
        );

  Board get _currentBoard => _boardAt(_index);

  MediaPost get _post => _postAt(_index);

  // Paging pauses while zoomed (so the image pans) and while more than one
  // finger is down (so a pinch is not stolen by the page drag).
  bool get _pagingLocked =>
      _zoomed ||
      (_multiTouch && _pointers > 0) ||
      !widget.state.settings.gesturesEnabled;

  void _updatePointers(int delta) {
    final locked = _pagingLocked;
    _pointers = (_pointers + delta).clamp(0, 10).toInt();
    if (_pointers > 1) _multiTouch = true;
    if (locked != _pagingLocked) setState(() {});
  }

  // Horizontal swipes belong to the PageView; this only tracks vertical
  // swipes, which open details (up) or close details/the viewer (down).
  void _handlePointerDown(PointerDownEvent event) {
    if (_pointers == 0) _multiTouch = false;
    _updatePointers(1);
    _pointerDown = widget.state.settings.gesturesEnabled && !_multiTouch
        ? event.position
        : null;
  }

  void _handlePointerUp(PointerUpEvent event) {
    final start = _pointerDown;
    final multiTouch = _multiTouch;
    _pointerDown = null;
    _updatePointers(-1);
    if (start == null || multiTouch || _zoomed) return;
    if (!widget.state.settings.gesturesEnabled) return;
    final delta = event.position - start;
    if (delta.dy.abs() < 90 || delta.dy.abs() <= delta.dx.abs()) return;
    if (delta.dy > 0) {
      if (_details) {
        setState(() => _details = false);
      } else {
        Navigator.maybePop(context);
      }
    } else {
      setState(() => _details = true);
    }
  }

  void _handlePointerCancel(PointerCancelEvent _) {
    _pointerDown = null;
    _updatePointers(-1);
  }

  void _setZoomed(bool zoomed) {
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  void _disposeVideo() {
    _videoGeneration++;
    final player = _player;
    _player = null;
    player?.dispose();
    final video = _video;
    _video = null;
    video?.removeListener(_watchVideoEnd);
    video?.removeListener(_watchVideoError);
    video?.dispose();
  }

  void _handlePageChanged(int index) {
    if (index == _index) return;
    _disposeVideo();
    _holdVideo = false;
    _videoPosition = Duration.zero;
    _videoRecoveries = 0;
    setState(() {
      _index = index;
      _revealed = false;
      _videoError = null;
      _details = false;
      _zoomed = false;
    });
    widget.state.recordBrowsedTags(_post.tags);
    _scheduleSlide();
    _resolveMedia(index);
  }

  // Video starts once paging settles so fast swipes past videos do not
  // open a network stream for every page crossed.
  bool _handleScrollEnd(ScrollEndNotification notification) {
    if (notification.depth == 0) _ensureVideo();
    return false;
  }

  void _ensureVideo() {
    final post = _post;
    if (!post.isVideo || _video != null || _videoError != null) return;
    if (_holdVideo || (_shouldBlur(post) && !_revealed)) return;
    _initializeVideo();
  }

  void _playHeldVideo() {
    setState(() => _holdVideo = false);
    _ensureVideo();
  }

  /// Opens the current video again after it failed.
  void _retryVideo() {
    _disposeVideo();
    _videoRecoveries = 0;
    setState(() {
      _videoError = null;
      _holdVideo = false;
    });
    _ensureVideo();
    _scheduleSlide();
  }

  void _watchVideoError() {
    final video = _video;
    if (video == null) return;
    final value = video.value;
    if (!value.hasError) {
      if (value.isInitialized) {
        _videoPosition = value.position;
        _videoPlaying = value.isPlaying;
      }
      return;
    }
    // Past the limit, the player's own error message stays.
    if (_videoRecoveries >= 3) return;
    _videoRecoveries++;
    final fallback = _streamFallback;
    _disposeVideo();
    setState(() {});
    _initializeVideo(
      startAt: _videoPosition,
      autoPlay: _videoPlaying,
      fallback: fallback,
    );
  }

  Future<void> _selectQuality(int quality) async {
    _quality = quality;
    widget.state.setVideoQuality(quality);
    if (_holdVideo) return;
    final target = _post.videoVariantFor(quality)?.quality ?? 0;
    if (target == _streamQuality && _video != null) return;
    final position = _video?.value.position ?? Duration.zero;
    final playing = _video?.value.isPlaying ?? true;
    _disposeVideo();
    setState(() => _videoError = null);
    await _initializeVideo(startAt: position, autoPlay: playing);
  }

  Future<void> _initializeVideo({
    Duration startAt = Duration.zero,
    bool autoPlay = true,
    VideoVariant? fallback,
    bool relookup = false,
  }) async {
    final generation = ++_videoGeneration;
    final board = _currentBoard;
    var post = _post;
    if (board.isSankakuFamily) {
      // Signed Sankaku URLs expire; an expired one answers 403.
      post = await widget.state.streamablePost(
        post,
        board: board,
        force: relookup,
      );
      if (!mounted || generation != _videoGeneration) return;
    }
    final variant = fallback ?? post.videoVariantFor(_quality);
    final url = variant?.url ?? mediaUrlOf(post);
    if (url.isEmpty) {
      if (mounted) {
        setState(() => _videoError = 'This video has no playable URL.');
      }
      return;
    }
    final video = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: videoHeaders(board),
    );
    _video = video;
    _streamQuality = variant?.quality ?? 0;
    _streamFallback = fallback;
    bool stale() =>
        !mounted || generation != _videoGeneration || !identical(_video, video);
    try {
      await video.initialize();
      if (stale()) {
        await video.dispose();
        return;
      }
      if (startAt > Duration.zero) await video.seekTo(startAt);
      final player = ChewieController(
        videoPlayerController: video,
        autoPlay: false,
        // A slideshow moves on when the video ends instead of looping.
        looping: !_slideshow,
        allowFullScreen: true,
        allowMuting: true,
        showControls: true,
        showControlsOnInitialize: false,
        showPlayButton: false,
        pauseOnBackgroundTap: true,
        // The viewer's own bar has play and seek; no buttons over the video.
        customControls: const MaterialControls(showPlayButton: false),
        routePageBuilder: (context, _, _, provider) => Scaffold(
          resizeToAvoidBottomInset: false,
          body: Container(
            alignment: Alignment.center,
            color: Colors.black,
            child: _undimmedPlayer(context, provider),
          ),
        ),
        playbackSpeeds: const [.25, .5, .75, 1, 1.25, 1.5, 2],
        errorBuilder: (_, _) => _videoFailure(
          'This video could not be played. Check your connection and try again.',
        ),
      );
      if (stale()) {
        player.dispose();
        await video.dispose();
        return;
      }
      _player = player;
      video
        ..addListener(_watchVideoEnd)
        ..addListener(_watchVideoError);
      await video.setVolume(_muted ? 0 : 1);
      if (stale()) {
        player.dispose();
        await video.dispose();
        return;
      }
      if (autoPlay && _lifecycle == AppLifecycleState.resumed) {
        await video.play();
      }
      if (mounted && generation == _videoGeneration) setState(() {});
    } catch (_) {
      if (identical(_video, video)) _video = null;
      // dispose() never completes for a player whose creation failed, so
      // it must not gate the fallback below.
      video.dispose().ignore();
      if (!mounted || generation != _videoGeneration) return;
      // A signed URL can be refused before its stated expiry; look the
      // post up once more and retry with whatever URL comes back.
      if (board.isSankakuFamily && !relookup) {
        await _initializeVideo(
          startAt: startAt,
          autoPlay: autoPlay,
          relookup: true,
        );
        return;
      }
      // Some originals use codecs the device cannot decode; a provider
      // rendition (usually H.264 MP4) is the best remaining option.
      if (variant == null && post.videoVariants.isNotEmpty) {
        await _initializeVideo(
          startAt: startAt,
          autoPlay: autoPlay,
          fallback: post.videoVariants.first,
          // Already looked up; looking up again would retry endlessly.
          relookup: relookup,
        );
        return;
      }
      setState(
        () => _videoError = 'Unable to stream this video. The server or this device may not support its format.',
      );
      _scheduleSlide();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    _screenAwake.setEnabled(state == AppLifecycleState.resumed);
    if (state != AppLifecycleState.resumed) _video?.pause();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    _slideshowTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _screenAwake.setEnabled(false);
    _videoGeneration++;
    _player?.dispose();
    _video?.dispose();
    _pages.dispose();
    super.dispose();
  }

  /// Queues the post in the Download Manager and reports how it ended.
  Future<void> _download() async {
    final state = widget.state;
    final messenger = ScaffoldMessenger.of(context);
    final task = state.downloads.add(
      SavedPost(board: _currentBoard, post: _post),
    );
    final message = switch (await task.settled) {
      DownloadResult.saved =>
        state.settings.autoFavoriteOnDownload
            ? 'Media saved to your download folder and favorited.'
            : 'Media saved to your download folder.',
      DownloadResult.folderLost =>
        'Folder access expired. Choose your download folder again in Settings.',
      DownloadResult.failed => 'Download failed. Check your connection, folder access, and free space.',
      DownloadResult.removed => null,
    };
    if (message != null) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// The download button: the queued download's progress ring while it
  /// waits or runs (tapping opens the Download Manager), resume for a
  /// paused or failed one.
  Widget _downloadButton(MediaPost post, Board board) => ListenableBuilder(
    listenable: widget.state.downloads,
    builder: (context, _) {
      final state = widget.state;
      final task = state.downloads.taskFor(post, board: board);
      if (task != null && task.active) {
        return IconButton(
          tooltip: task.status == DownloadStatus.waiting
              ? 'Waiting to download · open downloads'
              : 'Downloading · open downloads',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => DownloadsScreen(state: state),
            ),
          ),
          icon: _DownloadProgress(value: task.fraction),
        );
      }
      if (task != null) {
        final failed = task.status == DownloadStatus.failed;
        return IconButton(
          tooltip: failed
              ? 'Download failed · retry'
              : 'Download paused · resume',
          onPressed: () => state.downloads.resume(task),
          icon: Icon(
            failed ? Icons.error_outline_rounded : Icons.pause_circle_outline,
          ),
        );
      }
      final downloaded = state.isDownloaded(post, board: board);
      return IconButton(
        tooltip: downloaded
            ? 'Downloaded · download again'
            : 'Download original media',
        onPressed: _download,
        icon: Icon(
          downloaded ? Icons.download_done_rounded : Icons.download_outlined,
        ),
      );
    },
  );

  Future<void> _openSource() async {
    final uri = Uri.tryParse(_post.source);
    if (uri == null || !['https', 'http'].contains(uri.scheme)) return;
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw StateError('Unavailable');
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to open this source.')),
        );
      }
    }
  }

  Future<void> _openPost() async {
    final uri = Uri.tryParse(postBrowserUrl(_currentBoard, _post));
    if (uri == null || !['https', 'http'].contains(uri.scheme)) return;
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw StateError('Unavailable');
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to open this post.')),
        );
      }
    }
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _copy(String text, String message) async {
    await Clipboard.setData(ClipboardData(text: text));
    _notify(message);
  }

  Future<void> _shareMedia() async {
    final post = _post;
    final url = mediaUrlOf(post);
    if (url.isEmpty || _sharing) return;
    setState(() => _sharing = true);
    _notify('Preparing to share…');
    try {
      await _device.shareMedia(
        url: url,
        name: mediaFileName(
          _currentBoard,
          post,
          url,
          template: widget.state.settings.filenameTemplate,
        ),
      );
      if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
    } catch (_) {
      _notify('Unable to share this media. Check your connection.');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _postAction(String action) async {
    final post = _post;
    final link = postBrowserUrl(_currentBoard, post);
    switch (action) {
      case 'share_link':
        try {
          await _device.shareText(link);
        } catch (_) {
          _notify('No app can share this link.');
        }
      case 'share_media':
        await _shareMedia();
      case 'copy_link':
        await _copy(link, 'Post link copied.');
      case 'copy_source':
        await _copy(post.source, 'Source copied.');
      case 'copy_tags':
        await _copy(post.tags.join(' '), 'Tags copied.');
      case 'set_as':
        await _imageAction(
          (url, name) => _device.setAs(url: url, name: name),
          preparing: 'Opening…',
          failure: 'No app can use this image.',
        );
      case 'copy_image':
        await _imageAction(
          (url, name) => _device.copyImage(url: url, name: name),
          preparing: 'Copying image…',
          done: 'Image copied.',
          failure: 'Unable to copy this image. Check your connection.',
        );
      case 'save_frame':
        await _saveFrame();
    }
  }

  /// Runs [action] with the current image's URL and file name, showing
  /// [preparing] while the image downloads.
  Future<void> _imageAction(
    Future<void> Function(String url, String name) action, {
    required String preparing,
    required String failure,
    String? done,
  }) async {
    final post = _post;
    final url = mediaUrlOf(post);
    if (url.isEmpty || _sharing) return;
    setState(() => _sharing = true);
    _notify(preparing);
    try {
      await action(
        url,
        mediaFileName(
          _currentBoard,
          post,
          url,
          template: widget.state.settings.filenameTemplate,
        ),
      );
      if (done != null) {
        _notify(done);
      } else if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
      }
    } catch (_) {
      _notify(failure);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  /// Saves the paused or playing video's current frame as a JPEG to the
  /// download folder.
  Future<void> _saveFrame() async {
    final video = _video;
    if (video == null || !video.value.isInitialized || _sharing) return;
    final post = _post;
    final position = video.value.position;
    final base = mediaFileName(
      _currentBoard,
      post,
      video.dataSource,
      template: widget.state.settings.filenameTemplate,
    ).replaceFirst(RegExp(r'\.[^.]*$'), '');
    setState(() => _sharing = true);
    _notify('Saving frame…');
    try {
      await _device.saveFrame(
        url: video.dataSource,
        name: '${base}_${position.inMilliseconds}ms.jpg',
        position: position,
        directory: widget.state.settings.downloadDirectory,
      );
      _notify('Frame saved to your download folder.');
    } on PlatformException catch (error) {
      _notify(
        error.code == 'DIRECTORY_ACCESS' || error.code == 'DIRECTORY_REQUIRED'
            ? 'Choose your download folder again in Settings.'
            : 'Unable to save this frame.',
      );
    } catch (_) {
      _notify('Unable to save this frame.');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Widget _moreMenu(MediaPost post, String link) {
    final share = !widget.state.settings.noShare;
    return PopupMenuButton<String>(
      tooltip: share ? 'Share or copy' : 'Copy',
      icon: _sharing
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.more_vert_rounded),
      onSelected: _postAction,
      itemBuilder: (_) => [
        if (share && link.isNotEmpty)
          const PopupMenuItem(
            value: 'share_link',
            child: ListTile(
              leading: Icon(Icons.share_outlined),
              title: Text('Share link'),
            ),
          ),
        if (share && mediaUrlOf(post).isNotEmpty)
          PopupMenuItem(
            value: 'share_media',
            enabled: !_sharing,
            child: ListTile(
              leading: const Icon(Icons.ios_share_rounded),
              title: Text(post.isVideo ? 'Share video' : 'Share image'),
            ),
          ),
        if (link.isNotEmpty)
          const PopupMenuItem(
            value: 'copy_link',
            child: ListTile(
              leading: Icon(Icons.link_rounded),
              title: Text('Copy post link'),
            ),
          ),
        if (post.source.trim().isNotEmpty)
          const PopupMenuItem(
            value: 'copy_source',
            child: ListTile(
              leading: Icon(Icons.content_copy_rounded),
              title: Text('Copy source'),
            ),
          ),
        if (post.tags.isNotEmpty)
          const PopupMenuItem(
            value: 'copy_tags',
            child: ListTile(
              leading: Icon(Icons.sell_outlined),
              title: Text('Copy tags'),
            ),
          ),
        if (!post.isVideo && mediaUrlOf(post).isNotEmpty) ...[
          PopupMenuItem(
            value: 'copy_image',
            enabled: !_sharing,
            child: const ListTile(
              leading: Icon(Icons.image_outlined),
              title: Text('Copy image'),
            ),
          ),
          if (share)
            PopupMenuItem(
              value: 'set_as',
              enabled: !_sharing,
              child: const ListTile(
                leading: Icon(Icons.wallpaper_rounded),
                title: Text('Set as…'),
                subtitle: Text('Wallpaper, contact photo'),
              ),
            ),
        ],
        if (post.isVideo && (_video?.value.isInitialized ?? false))
          PopupMenuItem(
            value: 'save_frame',
            enabled: !_sharing,
            child: const ListTile(
              leading: Icon(Icons.photo_camera_outlined),
              title: Text('Save this frame'),
            ),
          ),
      ],
    );
  }

  /// Opens the related posts search ([query] such as `parent:123`) in the
  /// feed, or tells the user it is only available from the feed.
  void _browseQuery(String query) {
    if (widget.savedPosts.isNotEmpty) {
      _copy(query, 'Search copied: $query');
      return;
    }
    Navigator.pop(context, ViewerTagBrowse(query, _index));
  }

  Future<void> _showPools() async {
    final post = _post;
    final board = _currentBoard;
    List<PostPool> pools;
    try {
      pools = await _device.pools(board: board, post: post);
    } catch (_) {
      _notify('Could not load pools. Check your connection.');
      return;
    }
    if (!mounted) return;
    if (pools.isEmpty) {
      _notify('This post is not in any pool.');
      return;
    }
    final pool = await showModalBottomSheet<PostPool>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              leading: Icon(Icons.collections_bookmark_outlined),
              title: Text('Pools'),
            ),
            for (final pool in pools)
              ListTile(
                title: Text(pool.name),
                subtitle: pool.postCount > 0
                    ? Text('${pool.postCount} posts')
                    : null,
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.pop(context, pool),
              ),
          ],
        ),
      ),
    );
    if (pool == null || !mounted) return;
    // Danbooru's ordpool: keeps the pool's reading order.
    _browseQuery(
      board == Board.danbooru ? 'ordpool:${pool.id}' : 'pool:${pool.id}',
    );
  }

  Future<void> _findElsewhere() async {
    final post = _post;
    final board = _currentBoard;
    if (_findingElsewhere) return;
    setState(() => _findingElsewhere = true);
    _notify('Searching other websites…');
    List<SavedPost> found;
    try {
      found = await widget.state.findOnOtherSites(post, board: board);
    } finally {
      if (mounted) setState(() => _findingElsewhere = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    if (found.isEmpty) {
      _notify('No other website has this file.');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.travel_explore_rounded),
              title: const Text('Also on'),
              subtitle: Text(
                '${found.length} match${found.length == 1 ? '' : 'es'} by file hash',
              ),
            ),
            for (final (index, saved) in found.indexed)
              ListTile(
                leading: SiteLogo(saved.board, size: 28, colored: true),
                title: Text(saved.board.label),
                subtitle: Text(
                  '#${saved.post.displayId} · ${saved.post.width} × ${saved.post.height}',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () {
                  Navigator.pop(sheetContext);
                  Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => MediaViewer(
                        post: saved.post,
                        board: saved.board,
                        state: widget.state,
                        savedPosts: found,
                        initialIndex: index,
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _hideUploader(String uploader) async {
    final board = _currentBoard;
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
    } catch (_) {
      _notify('Could not hide this uploader. Please try again.');
    }
  }

  Future<void> _toggleFavorite(MediaPost post, Board board) async {
    await widget.state.toggleFavorite(post, board: board);
    if (mounted) setState(() {});
  }

  Future<void> _showTagActions(String tag) async {
    final board = _currentBoard;
    // Adding to or excluding from the search only applies to the feed the
    // viewer was opened from.
    final fromFeed = widget.savedPosts.isEmpty;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  tag,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(board.label),
              ),
              ListTile(
                leading: const Icon(Icons.search_rounded),
                title: const Text('Search this tag'),
                onTap: () => Navigator.pop(context, 'search'),
              ),
              if (!widget.allSites)
                ListTile(
                  leading: const Icon(Icons.travel_explore_rounded),
                  title: const Text('Search on all sites'),
                  onTap: () => Navigator.pop(context, 'search_all'),
                ),
              if (fromFeed) ...[
                ListTile(
                  leading: const Icon(Icons.add_circle_outline_rounded),
                  title: const Text('Add to current search'),
                  onTap: () => Navigator.pop(context, 'add'),
                ),
                ListTile(
                  leading: const Icon(Icons.remove_circle_outline_rounded),
                  title: const Text('Exclude from current search'),
                  onTap: () => Navigator.pop(context, 'exclude'),
                ),
              ],
              ListTile(
                leading: const Icon(Icons.block_rounded),
                title: Text('Block on ${board.label}'),
                onTap: () => Navigator.pop(context, 'block'),
              ),
              ListTile(
                leading: const Icon(Icons.public_off_rounded),
                title: const Text('Block on all websites'),
                onTap: () => Navigator.pop(context, 'block_all'),
              ),
              ListTile(
                leading: const Icon(Icons.content_copy_rounded),
                title: const Text('Copy tag'),
                onTap: () => Navigator.pop(context, 'copy'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'search':
        _browseTag(tag);
      case 'search_all':
        widget.state.recordBrowsedTags([tag]);
        _video?.pause();
        if (_slideshow) _toggleSlideshow();
        Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) =>
                MultiSearchScreen(state: widget.state, initialTags: [tag]),
          ),
        );
      case 'add':
        _browseTag(tag, mode: TagBrowseMode.add);
      case 'exclude':
        _browseTag(tag, mode: TagBrowseMode.exclude);
      case 'block':
      case 'block_all':
        final everywhere = action == 'block_all';
        try {
          await widget.state.blockTag(tag, board: everywhere ? null : board);
          _notify(
            'Blocked $tag on ${everywhere ? 'all websites' : board.label}. Manage it in Settings › Blocked tags.',
          );
        } catch (_) {
          _notify('Could not block this tag. Please try again.');
        }
      case 'copy':
        await _copy(tag, 'Tag copied.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final post = _post;
    final board = _currentBoard;
    final browserUrl = postBrowserUrl(board, post);
    final favorited = widget.state.isFavorite(post, board: board);
    final page = Scaffold(
      backgroundColor: post.isVideo ? Colors.black : canvas,
      appBar: AppBar(
        backgroundColor: appBarSurface(board),
        title: Row(
          children: [
            SiteLogo(board, size: 26, colored: true),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  board.label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '#${post.displayId}',
                  style: TextStyle(color: ink(.38), fontSize: 11),
                ),
              ],
            ),
          ],
        ),
        actions: [
          if (_pageCount > 1)
            IconButton(
              tooltip: _slideshow ? 'Stop slideshow' : 'Start slideshow',
              onPressed: _toggleSlideshow,
              icon: Icon(
                _slideshow
                    ? Icons.stop_circle_outlined
                    : Icons.slideshow_rounded,
              ),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Stack(
          children: [
            Positioned.fill(
              bottom: _controlsHeight + _detailsBarHeight,
              child: Listener(
                onPointerDown: _handlePointerDown,
                onPointerUp: _handlePointerUp,
                onPointerCancel: _handlePointerCancel,
                child: NotificationListener<ScrollEndNotification>(
                  onNotification: _handleScrollEnd,
                  child: PageView.builder(
                    controller: _pages,
                    // Neighbouring posts are built ahead of time so their
                    // media is already loading when a swipe reveals them.
                    allowImplicitScrolling: true,
                    physics: _pagingLocked
                        ? const NeverScrollableScrollPhysics()
                        : const _ViewerPagePhysics(
                            parent: ClampingScrollPhysics(),
                          ),
                    itemCount: _pageCount,
                    onPageChanged: _handlePageChanged,
                    itemBuilder: _buildPage,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizeReporter(
                    onHeight: (height) {
                      if (mounted && height != _controlsHeight) {
                        setState(() => _controlsHeight = height);
                      }
                    },
                    // Frosted only while the opened details lift these
                    // controls over the media. They then join the details
                    // into one sheet, taking over its rounded top so no
                    // unblurred media shows in the corners between them.
                    child: FrostedSurface(
                      color: panel,
                      active: _details,
                      opacity: detailsSurfaceOpacity,
                      borderRadius: _details
                          ? const BorderRadius.vertical(
                              top: Radius.circular(20),
                            )
                          : BorderRadius.zero,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (post.isVideo && _player != null)
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                IconButton(
                                  tooltip: 'Rewind 10 seconds',
                                  onPressed: () => _video!.seekTo(
                                    Duration(
                                      milliseconds:
                                          (_video!
                                                      .value
                                                      .position
                                                      .inMilliseconds -
                                                  10000)
                                              .clamp(
                                                0,
                                                _video!
                                                    .value
                                                    .duration
                                                    .inMilliseconds,
                                              ),
                                    ),
                                  ),
                                  icon: const Icon(Icons.replay_10),
                                ),
                                ValueListenableBuilder<VideoPlayerValue>(
                                  valueListenable: _video!,
                                  builder: (context, value, _) {
                                    final isPlaying = value.isPlaying;
                                    return IconButton(
                                      tooltip: isPlaying ? 'Pause' : 'Play',
                                      onPressed: () {
                                        if (isPlaying) {
                                          _video!.pause();
                                        } else {
                                          _video!.play();
                                        }
                                      },
                                      icon: Icon(
                                        isPlaying
                                            ? Icons.pause_rounded
                                            : Icons.play_arrow_rounded,
                                      ),
                                    );
                                  },
                                ),
                                IconButton(
                                  tooltip: 'Forward 10 seconds',
                                  onPressed: () => _video!.seekTo(
                                    Duration(
                                      milliseconds:
                                          (_video!
                                                      .value
                                                      .position
                                                      .inMilliseconds +
                                                  10000)
                                              .clamp(
                                                0,
                                                _video!
                                                    .value
                                                    .duration
                                                    .inMilliseconds,
                                              ),
                                    ),
                                  ),
                                  icon: const Icon(Icons.forward_10),
                                ),
                                IconButton(
                                  tooltip: 'Mute or unmute',
                                  onPressed: () {
                                    setState(() => _muted = !_muted);
                                    _video!.setVolume(_muted ? 0 : 1);
                                  },
                                  icon: Icon(
                                    _muted ? Icons.volume_off : Icons.volume_up,
                                  ),
                                ),
                              ],
                            ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              // Outside the player controls so a lower quality can be
                              // chosen even when the original fails to load.
                              if (post.isVideo && post.videoVariants.isNotEmpty)
                                _qualityMenu(post),
                              _moreMenu(post, browserUrl),
                              _downloadButton(post, board),
                              IconButton(
                                tooltip: _details
                                    ? 'Hide details'
                                    : 'Show details',
                                onPressed: () =>
                                    setState(() => _details = !_details),
                                icon: AnimatedRotation(
                                  turns: _details ? .5 : 0,
                                  duration: _reduceMotion
                                      ? Duration.zero
                                      : const Duration(milliseconds: 240),
                                  curve: Curves.easeOutCubic,
                                  child: const Icon(Icons.keyboard_arrow_up),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  FrostedSurface(
                    key: const ValueKey('post_details_panel'),
                    color: panel,
                    opacity: detailsSurfaceOpacity,
                    borderRadius: _details
                        ? BorderRadius.zero
                        : const BorderRadius.vertical(top: Radius.circular(20)),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizeReporter(
                          onHeight: (height) {
                            if (mounted && height != _detailsBarHeight) {
                              setState(() => _detailsBarHeight = height);
                            }
                          },
                          child: _detailsHeader(post, board, favorited),
                        ),
                        // Details slide up from the header when opened by a tap, the
                        // arrow button, or a swipe, and slide back down when closed.
                        AnimatedSwitcher(
                          duration: _reduceMotion
                              ? Duration.zero
                              : const Duration(milliseconds: 280),
                          reverseDuration: _reduceMotion
                              ? Duration.zero
                              : const Duration(milliseconds: 200),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder: (child, animation) => ClipRect(
                            child: SizeTransition(
                              sizeFactor: animation,
                              alignment: Alignment.topCenter,
                              child: SlideTransition(
                                position: Tween(
                                  begin: const Offset(0, .2),
                                  end: Offset.zero,
                                ).animate(animation),
                                child: FadeTransition(
                                  opacity: animation,
                                  child: child,
                                ),
                              ),
                            ),
                          ),
                          child: _details
                              ? KeyedSubtree(
                                  key: const ValueKey('post_details'),
                                  child: _detailsBody(post, board, browserUrl),
                                )
                              : const SizedBox(
                                  key: ValueKey('post_details_closed'),
                                  width: double.infinity,
                                ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    // Back slides open details down before it leaves the viewer.
    return PopScope<void>(
      canPop: !_details,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _details) setState(() => _details = false);
      },
      child: page,
    );
  }

  /// The original media's size, asked for the first time the details open
  /// on [post] and remembered while the viewer is open.
  Future<int?>? _sizeOf(MediaPost post, Board board) {
    final key = _linkKey(post, board);
    final known = _sizes[key];
    if (known != null || !_details) return known;
    if (_sizes.length > 40) _sizes.clear();
    return _sizes[key] = widget.state.mediaSize(post, board: board);
  }

  /// The bar under the media: rating, size, score, and favorite. Tapping
  /// or swiping it opens and closes the details.
  Widget _detailsHeader(
    MediaPost post,
    Board board,
    bool favorited,
  ) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onVerticalDragUpdate: (drag) {
      final dy = drag.primaryDelta ?? 0;
      if (_details && dy > 8) {
        setState(() => _details = false);
      } else if (!_details && dy < -8) {
        setState(() => _details = true);
      }
    },
    child: Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () => setState(() => _details = !_details),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 8),
              decoration: BoxDecoration(
                color: ink(.24),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 8, 10),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      post.rating.toUpperCase(),
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: accent,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Tags & details',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        FutureBuilder<int?>(
                          future: _sizeOf(post, board),
                          builder: (context, size) => Text(
                            '${post.width} × ${post.height} · ${post.fileType.isEmpty ? (post.isVideo ? 'Video' : 'Image') : '${post.fileType} ${post.isVideo ? 'video' : 'image'}'}${size.data == null ? '' : ' · ${formatBytes(size.data!)}'} · ${post.tags.length} tag${post.tags.length == 1 ? '' : 's'}',
                            key: const ValueKey('viewer_details_summary'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: ink(.54), fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.thumb_up_alt_outlined, size: 14, color: ink(.54)),
                  const SizedBox(width: 4),
                  Text(
                    '${post.score}',
                    style: TextStyle(color: ink(.54), fontSize: 12),
                  ),
                  IconButton(
                    tooltip: favorited
                        ? 'Remove from favorites'
                        : 'Add to favorites',
                    onPressed: () => _toggleFavorite(post, board),
                    icon: Icon(
                      favorited
                          ? Icons.favorite_rounded
                          : Icons.favorite_border,
                      size: 19,
                      color: favorited ? const Color(0xFFFF77A8) : ink(.38),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  /// The opened details: post information, parent and child posts, links,
  /// tags, and related posts. Pulling down at the top closes them.
  Widget _detailsBody(MediaPost post, Board board, String browserUrl) =>
      ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .5,
        ),
        child: SizedBox(
          width: double.infinity,
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              // Only the details' own scrolling; the thumbnail rows scroll
              // sideways.
              if (notification.depth != 0) return false;
              if (notification is OverscrollNotification &&
                  notification.overscroll < -6) {
                setState(() => _details = false);
                return true;
              }
              if (notification is ScrollUpdateNotification &&
                  notification.metrics.pixels <= 0 &&
                  (notification.scrollDelta ?? 0) < -6) {
                setState(() => _details = false);
                return true;
              }
              return false;
            },
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _infoCard(post, browserUrl),
                  _familySection(post, board),
                  if (_hasPools(board, post) || post.md5.isNotEmpty) ...[
                    const SectionLabel('More'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        if (_hasPools(board, post))
                          ActionChip(
                            avatar: const Icon(
                              Icons.collections_bookmark_outlined,
                              size: 16,
                            ),
                            label: const Text('Pools'),
                            onPressed: _showPools,
                          ),
                        if (post.md5.isNotEmpty)
                          ActionChip(
                            avatar: _findingElsewhere
                                ? const SizedBox.square(
                                    dimension: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(
                                    Icons.travel_explore_rounded,
                                    size: 16,
                                  ),
                            label: const Text('Find on other sites'),
                            onPressed: _findingElsewhere
                                ? null
                                : _findElsewhere,
                          ),
                      ],
                    ),
                  ],
                  if (post.description.isNotEmpty) ...[
                    const SectionLabel('Description'),
                    SelectableText(post.description),
                  ],
                  const SectionLabel('Tags · tap to search, hold for more'),
                  for (final entry in groupedTags(post).entries) ...[
                    Text(
                      _categoryLabel(entry.key),
                      style: TextStyle(
                        color: tagColor(entry.key),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final tag in entry.value)
                          GestureDetector(
                            onLongPress: () => _showTagActions(tag.name),
                            child: ActionChip(
                              label: Text(
                                tag.name,
                                style: const TextStyle(fontSize: 12),
                              ),
                              side: BorderSide(
                                color: tagColor(tag.category)
                                    .withValues(alpha: .6),
                              ),
                              onPressed: () => _browseTag(tag.name),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                  _relatedSection(post, board),
                ],
              ),
            ),
          ),
        ),
      );

  /// Uploader, source, and links to the post and its source.
  Widget _infoCard(MediaPost post, String browserUrl) {
    Widget row(IconData icon, String label, Widget value, {Widget? action}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Icon(icon, size: 18, color: ink(.54)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(color: ink(.54), fontSize: 11),
                    ),
                    const SizedBox(height: 2),
                    value,
                  ],
                ),
              ),
              ?action,
            ],
          ),
        );
    final missing = TextStyle(color: ink(.38));
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(
        color: ink(.04),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          row(
            Icons.person_outline_rounded,
            'Uploaded by',
            post.uploader.trim().isEmpty
                ? Text('Not supplied by this website', style: missing)
                : SelectableText(post.uploader),
            action: post.uploader.trim().isEmpty
                ? null
                : TextButton.icon(
                    onPressed: () => _hideUploader(post.uploader),
                    icon: const Icon(Icons.person_off_outlined, size: 16),
                    label: const Text('Hide uploader'),
                  ),
          ),
          row(
            Icons.link_rounded,
            'Original source',
            post.source.isEmpty
                ? Text('Not supplied by this website', style: missing)
                : SelectableText(
                    post.source,
                    maxLines: 2,
                    style: TextStyle(fontSize: 12, color: ink(.70)),
                  ),
          ),
          Wrap(
            spacing: 4,
            children: [
              if (browserUrl.isNotEmpty)
                TextButton.icon(
                  onPressed: _openPost,
                  icon: const Icon(Icons.open_in_browser, size: 16),
                  label: const Text('Open in browser'),
                ),
              if (post.source.isNotEmpty)
                TextButton.icon(
                  onPressed: _openSource,
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('Open original source'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _linkKey(MediaPost post, Board board) =>
      SavedPost(board: board, post: post).identity;

  /// The parent post and child posts as thumbnails that open in the
  /// viewer, with searches for them below.
  Widget _familySection(MediaPost post, Board board) {
    final children = post.hasChildren && post.hasId;
    if (post.parentId == null && !children) return const SizedBox.shrink();
    if (_families.length > 40) _families.clear();
    final future = _families.putIfAbsent(
      _linkKey(post, board),
      () => widget.state.postFamily(post, board: board),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel('Parent & child posts'),
        FutureBuilder(
          future: future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return _stripPlaceholder();
            }
            if (snapshot.hasError) {
              return _lookupFailed(
                () => _families.remove(_linkKey(post, board)),
              );
            }
            final family = snapshot.data;
            final entries = <(MediaPost, String?)>[
              if (family?.parent case final parent?) (parent, 'Parent'),
              for (final child in family?.children ?? const <MediaPost>[])
                (child, 'Child'),
            ];
            if (entries.isEmpty) {
              return Text(
                'These posts are no longer available.',
                style: TextStyle(color: ink(.38)),
              );
            }
            return _postStrip(board, entries);
          },
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (post.parentId != null)
              ActionChip(
                avatar: const Icon(Icons.north_west_rounded, size: 16),
                label: const Text('Parent post'),
                onPressed: () => _browseQuery('id:${post.parentId}'),
              ),
            if (children)
              ActionChip(
                avatar: const Icon(Icons.account_tree_outlined, size: 16),
                label: const Text('Child posts'),
                onPressed: () => _browseQuery('parent:${post.displayId}'),
              ),
          ],
        ),
      ],
    );
  }

  /// Posts sharing this post's artists and characters, best match first.
  Widget _relatedSection(MediaPost post, Board board) {
    if (post.tags.isEmpty) return const SizedBox.shrink();
    if (_related.length > 40) _related.clear();
    final future = _related.putIfAbsent(
      _linkKey(post, board),
      () => widget.state.relatedPosts(post, board: board),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel('Related posts'),
        FutureBuilder(
          future: future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return _stripPlaceholder();
            }
            if (snapshot.hasError) {
              return _lookupFailed(
                () => _related.remove(_linkKey(post, board)),
              );
            }
            final posts = snapshot.data ?? const <MediaPost>[];
            if (posts.isEmpty) {
              return Text(
                'No related posts found.',
                style: TextStyle(color: ink(.38)),
              );
            }
            return _postStrip(board, [for (final item in posts) (item, null)]);
          },
        ),
      ],
    );
  }

  /// A failed lookup, with a retry that forgets the cached failure.
  Widget _lookupFailed(VoidCallback forget) => Row(
    children: [
      Expanded(
        child: Text(
          'Could not load these posts.',
          style: TextStyle(color: ink(.38)),
        ),
      ),
      TextButton.icon(
        onPressed: () {
          forget();
          setState(() {});
        },
        icon: const Icon(Icons.refresh_rounded, size: 16),
        label: const Text('Retry'),
      ),
    ],
  );

  static const _stripHeight = 132.0;

  Widget _stripPlaceholder() => SizedBox(
    height: _stripHeight,
    child: Row(
      children: [
        for (var i = 0; i < 3; i++)
          Container(
            width: 100,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: ink(.06),
              borderRadius: BorderRadius.circular(12),
            ),
          ),
      ],
    ),
  );

  /// A horizontal row of post thumbnails, each with an optional label.
  Widget _postStrip(Board board, List<(MediaPost, String?)> entries) {
    final state = widget.state;
    final posts = [for (final (item, _) in entries) item];
    return SizedBox(
      height: _stripHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final (item, label) = entries[index];
          final shown = state.displayPost(item, board: board);
          return SizedBox(
            width: 100,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  MediaTile(
                    key: ValueKey(_linkKey(item, board)),
                    post: shown,
                    board: board,
                    hidePostTags: true,
                    isFavorite: state.isFavorite(shown, board: board),
                    isDownloaded: state.isDownloaded(shown, board: board),
                    blur: shouldBlurPost(state, shown),
                    onTap: () => _openPosts(board, posts, index),
                  ),
                  if (label != null)
                    Positioned(
                      left: 6,
                      top: 6,
                      child: IgnorePointer(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            label,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Opens [posts] in a viewer on top of this one, at [index].
  void _openPosts(Board board, List<MediaPost> posts, int index) {
    final saved = [
      for (final item in posts)
        widget.state.displayReady(SavedPost(board: board, post: item)),
    ];
    _video?.pause();
    if (_slideshow) _toggleSlideshow();
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => MediaViewer(
          post: saved[index].post,
          board: saved[index].board,
          state: widget.state,
          savedPosts: saved,
          initialIndex: index,
        ),
      ),
    );
  }

  void _browseTag(String tag, {TagBrowseMode mode = TagBrowseMode.replace}) {
    if (mode != TagBrowseMode.exclude) widget.state.recordBrowsedTags([tag]);
    Navigator.pop(context, ViewerTagBrowse(tag, _index, mode: mode));
  }

  Widget _buildPage(BuildContext context, int index) {
    final post = _postAt(index);
    final board = _boardAt(index);
    final active = index == _index;
    if (post.isVideo) return _videoPage(post, board, active: active);
    if (mediaUrlOf(post).isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'The original image is unavailable. It may have been removed or require website access.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final sample = _savesData(post, index);
    return Stack(
      fit: StackFit.expand,
      children: [
        _ZoomableMedia(
          active: active,
          onZoomChanged: _setZoomed,
          onDoubleTap: widget.state.settings.doubleTapFavorite
              ? () => _doubleTapFavorite(post, board)
              : null,
          child: _viewerImage(post, board, active: active, sample: sample),
        ),
        if (sample && active)
          Positioned(
            left: 12,
            bottom: 12,
            child: FilledButton.tonalIcon(
              onPressed: () => setState(() => _originalsRequested.add(index)),
              icon: const Icon(Icons.hd_outlined, size: 18),
              label: const Text('Load original'),
            ),
          ),
      ],
    );
  }

  Future<void> _doubleTapFavorite(MediaPost post, Board board) async {
    final adding = !widget.state.isFavorite(post, board: board);
    await _toggleFavorite(post, board);
    _notify(adding ? 'Added to favorites.' : 'Removed from favorites.');
  }

  Widget _viewerImage(
    MediaPost post,
    Board board, {
    required bool active,
    bool sample = false,
  }) {
    final image = MediaImage(
      url: sample ? post.sampleUrl : mediaUrlOf(post),
      board: board,
      fit: BoxFit.contain,
      // Bounded decoding keeps huge originals under common GPU texture
      // limits and out of multi-hundred-megabyte bitmaps, while leaving
      // enough detail for zooming.
      maxDimension: 4096,
      showProgress: true,
      errorMessage: 'The original image is unavailable. It may have been removed or require website access.',
    );
    if (!_shouldBlur(post) || (active && _revealed)) return image;
    return Stack(
      alignment: Alignment.center,
      children: [
        ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: image,
        ),
        if (active)
          FilledButton.icon(
            onPressed: () => setState(() => _revealed = true),
            icon: const Icon(Icons.visibility),
            label: const Text('Reveal media'),
          ),
      ],
    );
  }

  Widget _videoPage(MediaPost post, Board board, {required bool active}) {
    if (_shouldBlur(post) && !(active && _revealed)) {
      return _blurredVideo(post, board, active: active);
    }
    if (!active) return _videoPoster(post, board);
    final error = _videoError;
    if (error != null) return _videoFailure(error);
    final player = _player;
    if (player == null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          _videoPoster(post, board),
          if (_holdVideo)
            Center(
              child: IconButton.filled(
                key: const ValueKey('video_play'),
                tooltip: 'Play',
                iconSize: 40,
                onPressed: _playHeldVideo,
                icon: const Icon(Icons.play_arrow_rounded),
              ),
            )
          else
            const Align(
              alignment: Alignment.bottomCenter,
              child: LinearProgressIndicator(
                key: ValueKey('video_progress'),
                minHeight: 4,
              ),
            ),
        ],
      );
    }
    return Container(
      color: Colors.black,
      child: _undimmedPlayer(context, Chewie(controller: player)),
    );
  }

  Widget _videoFailure(String message) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const ValueKey('video_retry'),
            onPressed: _retryVideo,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
          ),
        ],
      ),
    ),
  );

  // Chewie lays a black scrim over the video whenever its controls show,
  // except on iOS. Reporting iOS to the player subtree drops that scrim;
  // the explicit MaterialControls keep the Android control style.
  Widget _undimmedPlayer(BuildContext context, Widget child) => Theme(
    data: Theme.of(context).copyWith(platform: TargetPlatform.iOS),
    child: child,
  );

  Widget _videoPoster(MediaPost post, Board board) {
    final preview = post.previewUrl;
    if (preview.isEmpty || preview == post.url) return const SizedBox.expand();
    return MediaImage(
      url: preview,
      board: board,
      fit: BoxFit.contain,
      errorWidget: const SizedBox.shrink(),
    );
  }

  Widget _blurredVideo(MediaPost post, Board board, {required bool active}) {
    final preview = post.previewUrl.isNotEmpty
        ? post.previewUrl
        : mediaUrlOf(post);
    return Stack(
      alignment: Alignment.center,
      children: [
        if (preview.isNotEmpty)
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: MediaImage(url: preview, board: board, fit: BoxFit.contain),
          )
        else
          const Icon(Icons.visibility_off_outlined, size: 42),
        if (active)
          FilledButton.icon(
            onPressed: () {
              setState(() => _revealed = true);
              _ensureVideo();
              _scheduleSlide();
            },
            icon: const Icon(Icons.visibility),
            label: const Text('Reveal media'),
          ),
      ],
    );
  }

  Widget _qualityMenu(MediaPost post) {
    // Renditions at or above the original's tier add nothing selectable.
    final original = post.videoQuality;
    final tiers = <int>{};
    final options = <VideoVariant>[];
    for (final variant in post.videoVariants) {
      if (original > 0 && variant.quality >= original) continue;
      if (tiers.add(variant.quality)) options.add(variant);
    }
    return PopupMenuButton<int>(
      tooltip: 'Video quality',
      onSelected: _selectQuality,
      icon: const Icon(Icons.high_quality_outlined),
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          value: 0,
          checked: _streamQuality == 0,
          child: Text(original > 0 ? 'Original · ${original}p' : 'Original'),
        ),
        for (final variant in options)
          CheckedPopupMenuItem(
            value: variant.quality,
            checked: _streamQuality == variant.quality,
            child: Text(variant.label),
          ),
      ],
    );
  }

  bool _shouldBlur(MediaPost post) {
    final settings = widget.state.settings;
    final rating = post.rating.trim().toLowerCase();
    if (rating.contains('explicit') || rating == 'e') {
      return settings.blurExplicit;
    }
    return (rating.contains('questionable') || rating == 'q') &&
        settings.blurQuestionable;
  }
}

/// Request headers for streaming a video from [board].
Map<String, String> videoHeaders(Board board) => switch (board) {
  Board.gelbooru => const {
    'Referer': 'https://gelbooru.com/',
    'User-Agent': 'BooruPlus/1.0',
  },
  // Nozomi's media hosts answer 404 without the site as Referer.
  Board.nozomi => const {
    'Referer': 'https://nozomi.la/',
    'User-Agent': 'BooruPlus/1.0',
  },
  Board.realbooru => const {
    'Referer': 'https://realbooru.com/',
    'User-Agent': 'BooruPlus/1.0',
  },
  _ => const {},
};

String mediaUrlOf(MediaPost post) {
  final dynamic value = post;
  try {
    final authenticated = value.authenticatedUrl;
    if (authenticated is String && authenticated.isNotEmpty) {
      return authenticated;
    }
  } catch (_) {}
  try {
    final urls = value.urlMap;
    if (urls is Map) {
      for (final key in const ['original', 'file', 'url']) {
        final candidate = urls[key];
        if (candidate is String && candidate.isNotEmpty) return candidate;
      }
    }
  } catch (_) {}
  return post.url;
}

String postBrowserUrl(Board board, MediaPost post) {
  final provided = post.postUrl?.trim();
  if (provided != null && provided.isNotEmpty) {
    final uri = Uri.tryParse(provided);
    if (uri != null &&
        ['http', 'https'].contains(uri.scheme.toLowerCase()) &&
        uri.host.toLowerCase() == board.host.toLowerCase()) {
      return provided;
    }
  }
  if (!post.hasId) return '';
  return switch (board) {
    Board.danbooru || Board.aibooru => 'https://${board.host}/posts/${post.id}',
    Board.nozomi => 'https://${board.host}/post/${post.id}.html',
    Board.derpibooru => 'https://${board.host}/images/${post.id}',
    Board.e621 || Board.e926 => 'https://${board.host}/posts/${post.id}',
    Board.sankaku ||
    Board.idolcomplex => 'https://${board.host}/posts/${post.displayId}',
    Board.konachan ||
    Board.yandere ||
    Board.sakugabooru => 'https://${board.host}/post/show/${post.id}',
    Board.eshuushuu => 'https://${board.host}/image/${post.id}',
    Board.mikubooru => 'https://${board.host}/posts/${post.id}',
    Board.nanbooru => 'https://${board.host}/post/view/${post.id}',
    _ => 'https://${board.host}/index.php?page=post&s=view&id=${post.id}',
  };
}

/// Pools are listed for Danbooru (looked up by post) and e621/e926 (when
/// the post names any).
bool _hasPools(Board board, MediaPost post) =>
    post.hasId &&
    (board == Board.danbooru ||
        ((board == Board.e621 || board == Board.e926) &&
            post.pools.isNotEmpty));

String _categoryLabel(TagCategory category) => category.label;

Color tagColor(TagCategory category) => switch (category) {
  TagCategory.artist => tagTone(const Color(0xFFE8A0FF)),
  TagCategory.character => tagTone(const Color(0xFF8BC8FF)),
  TagCategory.copyright => tagTone(const Color(0xFFFFA56B)),
  TagCategory.species => tagTone(const Color(0xFF91D99B)),
  TagCategory.meta => tagTone(const Color(0xFFFFD166)),
  TagCategory.lore => tagTone(const Color(0xFFC1A7FF)),
  _ => ink(.70),
};

Map<TagCategory, List<TagInfo>> groupedTags(MediaPost post) {
  final tags = post.tagDetails.isEmpty
      ? post.tags
            .map((name) => TagInfo(name: name, category: TagCategory.general))
            .toList()
      : post.tagDetails;
  final grouped = <TagCategory, List<TagInfo>>{};
  for (final tag in tags) {
    grouped.putIfAbsent(tag.category, () => []).add(tag);
  }
  return grouped;
}

/// Pinch/double-tap zoom for one viewer page. Reports zoom changes while
/// [active] so the pager can lock, and resets when the page is left.
class _ZoomableMedia extends StatefulWidget {
  const _ZoomableMedia({
    required this.active,
    required this.onZoomChanged,
    required this.child,
    this.onDoubleTap,
  });
  final bool active;
  final ValueChanged<bool> onZoomChanged;
  final Widget child;

  /// Replaces double-tap zoom (pinching still zooms).
  final VoidCallback? onDoubleTap;

  @override
  State<_ZoomableMedia> createState() => _ZoomableMediaState();
}

class _ZoomableMediaState extends State<_ZoomableMedia> {
  final _transform = TransformationController();
  Offset _doubleTapAt = Offset.zero;
  bool _zoomed = false;

  @override
  void didUpdateWidget(covariant _ZoomableMedia oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Neighbouring pages stay alive; return them to fit once left.
    if (oldWidget.active && !widget.active) {
      _transform.value = Matrix4.identity();
      _zoomed = false;
    }
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _report() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed == _zoomed) return;
    _zoomed = zoomed;
    if (widget.active) widget.onZoomChanged(zoomed);
  }

  void _toggleZoom() {
    const scale = 2.5;
    // Zoom around the tapped point rather than the top-left corner.
    _transform.value = _zoomed
        ? Matrix4.identity()
        : (Matrix4.diagonal3Values(scale, scale, 1)..setTranslationRaw(
            -_doubleTapAt.dx * (scale - 1),
            -_doubleTapAt.dy * (scale - 1),
            0,
          ));
    _report();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onDoubleTapDown: (details) => _doubleTapAt = details.localPosition,
    onDoubleTap: widget.onDoubleTap ?? _toggleZoom,
    child: InteractiveViewer(
      transformationController: _transform,
      minScale: .5,
      maxScale: 8,
      onInteractionEnd: (_) => _report(),
      child: Center(child: widget.child),
    ),
  );
}

/// Page physics with a stiffer, critically damped spring so a released
/// swipe settles on the next post quickly instead of drifting. A swipe
/// must also travel and move faster than the defaults before it turns the
/// page, so short flicks and slanted vertical swipes stay on the post.
class _ViewerPagePhysics extends ScrollPhysics {
  const _ViewerPagePhysics({super.parent});

  @override
  _ViewerPagePhysics applyTo(ScrollPhysics? ancestor) =>
      _ViewerPagePhysics(parent: buildParent(ancestor));

  @override
  double get minFlingVelocity => 400;

  @override
  double get minFlingDistance => 48;

  @override
  double get dragStartDistanceMotionThreshold => 24;

  @override
  SpringDescription get spring =>
      SpringDescription.withDampingRatio(mass: .5, stiffness: 180, ratio: 1);
}

/// The download button while saving: a ring that fills with the saved
/// fraction and shows it as a percentage, or spins until the size is known.
class _DownloadProgress extends StatelessWidget {
  const _DownloadProgress({required this.value});
  final double? value;

  @override
  Widget build(BuildContext context) {
    final value = this.value;
    return SizedBox.square(
      key: const ValueKey('viewer_download_progress'),
      dimension: 28,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: CircularProgressIndicator(
              value: value,
              strokeWidth: 2.5,
              color: accent,
              backgroundColor: ink(.12),
            ),
          ),
          if (value != null)
            Text(
              '${(value * 100).floor()}%',
              // The ring has a fixed size, so large text scales only a little.
              textScaler: MediaQuery.textScalerOf(context)
                  .clamp(maxScaleFactor: 1.15),
              style: TextStyle(
                color: ink(.87),
                fontSize: 9,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }
}
