import 'dart:ui';

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../core/services.dart';
import 'media_image.dart';
import 'site_catalog.dart';
import 'theme.dart';

class MediaViewer extends StatefulWidget {
  const MediaViewer({
    super.key,
    required this.post,
    required this.board,
    required this.state,
    this.posts = const [],
    this.savedPosts = const [],
    this.initialIndex = 0,
  });
  final MediaPost post;
  final Board board;
  final AppState state;
  final List<MediaPost> posts;
  final List<SavedPost> savedPosts;
  final int initialIndex;
  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<MediaViewer> with WidgetsBindingObserver {
  VideoPlayerController? _video;
  ChewieController? _player;
  late final PageController _pages;
  String? _videoError;
  bool _downloading = false;
  bool _details = false;
  bool _muted = false;
  late int _index;
  late int _quality;
  Offset? _pointerDown;
  int _pointers = 0;
  bool _multiTouch = false;
  bool _zoomed = false;
  int _videoGeneration = 0;
  int _streamQuality = 0;
  bool _revealed = false;
  final _downloads = DownloadService();
  final _screenAwake = ScreenAwakeService();
  AppLifecycleState _lifecycle =
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    _index = _itemCount == 0
        ? 0
        : widget.initialIndex.clamp(0, _itemCount - 1).toInt();
    _quality = widget.state.settings.videoQuality;
    _pages = PageController(initialPage: _index);
    WidgetsBinding.instance.addObserver(this);
    if (_lifecycle == AppLifecycleState.resumed) {
      _screenAwake.setEnabled(true);
    }
    widget.state.recordBrowsedTags(_post.tags);
    _ensureVideo();
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
      : widget.posts.isEmpty
      ? widget.post
      : widget.posts[index];

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
    _pointerDown =
        widget.state.settings.gesturesEnabled && !_multiTouch
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
    video?.dispose();
  }

  void _handlePageChanged(int index) {
    if (index == _index) return;
    _disposeVideo();
    setState(() {
      _index = index;
      _revealed = false;
      _videoError = null;
      _details = false;
      _zoomed = false;
    });
    widget.state.recordBrowsedTags(_post.tags);
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
    if (_shouldBlur(post) && !_revealed) return;
    _initializeVideo();
  }

  Future<void> _selectQuality(int quality) async {
    _quality = quality;
    widget.state.setVideoQuality(quality);
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
  }) async {
    final generation = ++_videoGeneration;
    final post = _post;
    final variant = fallback ?? post.videoVariantFor(_quality);
    final url = variant?.url ?? _mediaUrl(post);
    if (url.isEmpty) {
      if (mounted) {
        setState(() => _videoError = 'This video has no playable URL.');
      }
      return;
    }
    final video = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: _currentBoard == Board.gelbooru
          ? const {
              'Referer': 'https://gelbooru.com/',
              'User-Agent': 'BooruPlus/1.0',
            }
          : const {},
    );
    _video = video;
    _streamQuality = variant?.quality ?? 0;
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
        looping: true,
        allowFullScreen: true,
        allowMuting: true,
        showControls: true,
        showControlsOnInitialize: false,
        showPlayButton: false,
        pauseOnBackgroundTap: true,
        playbackSpeeds: const [.25, .5, .75, 1, 1.25, 1.5, 2],
        errorBuilder: (_, _) => const Center(
          child: Text('This video could not be played. Try reopening it.'),
        ),
      );
      if (stale()) {
        player.dispose();
        await video.dispose();
        return;
      }
      _player = player;
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
      // Some originals use codecs the device cannot decode; a provider
      // rendition (usually H.264 MP4) is the best remaining option.
      if (variant == null && post.videoVariants.isNotEmpty) {
        await _initializeVideo(
          startAt: startAt,
          autoPlay: autoPlay,
          fallback: post.videoVariants.first,
        );
        return;
      }
      setState(
        () => _videoError =
            'Unable to stream this video. The server or this device may not support its format.',
      );
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
    WidgetsBinding.instance.removeObserver(this);
    _screenAwake.setEnabled(false);
    _videoGeneration++;
    _player?.dispose();
    _video?.dispose();
    _pages.dispose();
    super.dispose();
  }

  Future<void> _download() async {
    setState(() => _downloading = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final url = _mediaUrl(_post);
      if (url.isEmpty) throw StateError('Missing media URL');
      final path = Uri.parse(url).path;
      final extension = path.contains('.')
          ? path.split('.').last.replaceAll(RegExp('[^a-zA-Z0-9]'), '')
          : 'jpg';
      await _downloads.download(
        url: url,
        name: '${_currentBoard.name}_${_post.id}.$extension',
        directory: widget.state.settings.downloadDirectory,
      );
      messenger.showSnackBar(
        const SnackBar(content: Text('Media saved to your download folder.')),
      );
    } on PlatformException catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e.code == 'DIRECTORY_ACCESS'
                ? 'Folder access expired. Choose your download folder again in Settings.'
                : 'Download failed. Check your connection, folder access, and free space.',
          ),
        ),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Download unavailable. Please try again.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

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
    final uri = Uri.tryParse(_postBrowserUrl(_currentBoard, _post));
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

  @override
  Widget build(BuildContext context) {
    final post = _post;
    final board = _currentBoard;
    final site = appearanceFor(board);
    final browserUrl = _postBrowserUrl(board, post);
    final favorited = widget.state.isFavorite(post, board: board);
    return Scaffold(
      backgroundColor: post.isVideo ? Colors.black : canvas,
      appBar: AppBar(
        backgroundColor: site.surface,
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
                  '#${post.id}',
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ],
            ),
          ],
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
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
            if (post.isVideo && _player != null)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Rewind 10 seconds',
                    onPressed: () => _video!.seekTo(
                      Duration(
                        milliseconds:
                            (_video!.value.position.inMilliseconds - 10000)
                                .clamp(
                                  0,
                                  _video!.value.duration.inMilliseconds,
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
                            (_video!.value.position.inMilliseconds + 10000)
                                .clamp(
                                  0,
                                  _video!.value.duration.inMilliseconds,
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
                    icon: Icon(_muted ? Icons.volume_off : Icons.volume_up),
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
                IconButton(
                  tooltip: 'Download original media',
                  onPressed: _downloading ? null : _download,
                  icon: _downloading
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_outlined),
                ),
                IconButton(
                  tooltip: _details ? 'Hide details' : 'Show details',
                  onPressed: () => setState(() => _details = !_details),
                  icon: Icon(
                    _details
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_up,
                  ),
                ),
              ],
            ),
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragUpdate: (drag) {
                if (_details && (drag.primaryDelta ?? 0) > 8) {
                  setState(() => _details = false);
                }
              },
              child: Material(
                color: panel,
                child: InkWell(
                  onTap: () => setState(() => _details = !_details),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 16,
                    ),
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
                        const Expanded(
                          child: Text(
                            'Tags & details',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        IconButton(
                          tooltip: favorited
                              ? 'Remove from favorites'
                              : 'Add to favorites',
                          onPressed: () async {
                            await widget.state.toggleFavorite(
                              post,
                              board: board,
                            );
                            if (mounted) setState(() {});
                          },
                          icon: Icon(
                            favorited
                                ? Icons.favorite_rounded
                                : Icons.favorite_border,
                            size: 19,
                            color: favorited
                                ? const Color(0xFFFF77A8)
                                : Colors.white38,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          '${post.score}',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: 12),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (_details)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * .42,
                ),
                child: Container(
                  color: panel,
                  width: double.infinity,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
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
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Divider(),
                          Text(
                            '${post.width} × ${post.height} · ${post.isVideo ? 'Video' : 'Image'}',
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                          const SectionLabel('Uploaded by'),
                          SelectableText(
                            post.uploader.isEmpty
                                ? 'Not supplied by this website'
                                : post.uploader,
                          ),
                          if (post.description.isNotEmpty) ...[
                            const SectionLabel('Description'),
                            SelectableText(post.description),
                          ],
                          if (browserUrl.isNotEmpty)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                onPressed: _openPost,
                                icon: const Icon(
                                  Icons.open_in_browser,
                                  size: 16,
                                ),
                                label: const Text('Open in browser'),
                              ),
                            ),
                          const SectionLabel('Original source'),
                          if (post.source.isEmpty)
                            const Text(
                              'Not supplied by this website',
                              style: TextStyle(color: Colors.white38),
                            )
                          else
                            Wrap(
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                TextButton.icon(
                                  onPressed: _openSource,
                                  icon: const Icon(Icons.open_in_new, size: 16),
                                  label: const Text('Open original source'),
                                ),
                                SelectableText(
                                  post.source,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.white54,
                                  ),
                                ),
                              ],
                            ),
                          const SectionLabel('Tags · tap to search'),
                          for (final entry in _groupedTags(post).entries) ...[
                            Text(
                              _categoryLabel(entry.key),
                              style: TextStyle(
                                color: _tagColor(entry.key),
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
                                  ActionChip(
                                    label: Text(
                                      tag.name,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    side: BorderSide(
                                      color: _tagColor(tag.category)
                                          .withValues(alpha: .6),
                                    ),
                                    onPressed: () =>
                                        _browseTag(tag.name),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _browseTag(String tag) {
    widget.state.recordBrowsedTags([tag]);
    Navigator.pop(context, tag);
  }

  Widget _buildPage(BuildContext context, int index) {
    final post = _postAt(index);
    final board = _boardAt(index);
    final active = index == _index;
    if (post.isVideo) return _videoPage(post, board, active: active);
    if (_mediaUrl(post).isEmpty) {
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
    return _ZoomableMedia(
      active: active,
      onZoomChanged: _setZoomed,
      child: _viewerImage(post, board, active: active),
    );
  }

  Widget _viewerImage(MediaPost post, Board board, {required bool active}) {
    final image = MediaImage(
      url: _mediaUrl(post),
      board: board,
      fit: BoxFit.contain,
      // Bounded decoding keeps huge originals under common GPU texture
      // limits and out of multi-hundred-megabyte bitmaps, while leaving
      // enough detail for zooming.
      maxDimension: 4096,
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
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(error, textAlign: TextAlign.center),
        ),
      );
    }
    final player = _player;
    if (player == null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          _videoPoster(post, board),
          const Center(child: CircularProgressIndicator()),
        ],
      );
    }
    return Container(color: Colors.black, child: Chewie(controller: player));
  }

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
        : _mediaUrl(post);
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
          child: Text(
            original > 0 ? 'Original · ${original}p' : 'Original',
          ),
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

String _mediaUrl(MediaPost post) {
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

String _postBrowserUrl(Board board, MediaPost post) {
  final provided = post.postUrl?.trim();
  if (provided != null && provided.isNotEmpty) {
    final uri = Uri.tryParse(provided);
    if (uri != null &&
        ['http', 'https'].contains(uri.scheme.toLowerCase()) &&
        uri.host.toLowerCase() == board.host.toLowerCase()) {
      return provided;
    }
  }
  if (post.id <= 0) return '';
  return switch (board) {
    Board.danbooru => 'https://${board.host}/posts/${post.id}',
    Board.e621 || Board.e926 => 'https://${board.host}/posts/${post.id}',
    Board.konachan ||
    Board.yandere => 'https://${board.host}/post/show/${post.id}',
    _ => 'https://${board.host}/index.php?page=post&s=view&id=${post.id}',
  };
}

String _categoryLabel(TagCategory category) => category.label;

Color _tagColor(TagCategory category) => switch (category) {
  TagCategory.artist => const Color(0xFFE8A0FF),
  TagCategory.character => const Color(0xFF8BC8FF),
  TagCategory.copyright => const Color(0xFFFFA56B),
  TagCategory.species => const Color(0xFF91D99B),
  TagCategory.meta => const Color(0xFFFFD166),
  TagCategory.lore => const Color(0xFFC1A7FF),
  _ => Colors.white70,
};

Map<TagCategory, List<TagInfo>> _groupedTags(MediaPost post) {
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
  });
  final bool active;
  final ValueChanged<bool> onZoomChanged;
  final Widget child;

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
    onDoubleTap: _toggleZoom,
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
/// swipe settles on the next post quickly instead of drifting.
class _ViewerPagePhysics extends ScrollPhysics {
  const _ViewerPagePhysics({super.parent});

  @override
  _ViewerPagePhysics applyTo(ScrollPhysics? ancestor) =>
      _ViewerPagePhysics(parent: buildParent(ancestor));

  @override
  SpringDescription get spring =>
      SpringDescription.withDampingRatio(mass: .5, stiffness: 180, ratio: 1);
}
