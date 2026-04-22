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
    this.initialIndex = 0,
  });
  final MediaPost post;
  final Board board;
  final AppState state;
  final List<MediaPost> posts;
  final int initialIndex;
  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<MediaViewer> with WidgetsBindingObserver {
  VideoPlayerController? _video;
  ChewieController? _player;
  final _transform = TransformationController();
  String? _videoError;
  bool _downloading = false;
  bool _details = false;
  bool _muted = false;
  late int _index;
  Offset? _pointerDown;
  int _videoGeneration = 0;
  static const _videoControlsHeight = 160.0;
  final _downloads = DownloadService();
  AppLifecycleState _lifecycle =
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    _index = widget.posts.isEmpty
        ? 0
        : widget.initialIndex.clamp(0, widget.posts.length - 1).toInt();
    WidgetsBinding.instance.addObserver(this);
    if (_post.isVideo) _initializeVideo();
  }

  MediaPost get _post =>
      widget.posts.isEmpty ? widget.post : widget.posts[_index];

  void _handlePointerDown(PointerDownEvent event) {
    if (!widget.state.settings.gesturesEnabled) {
      _pointerDown = null;
      return;
    }
    final inVideoControls =
        _post.isVideo &&
        event.position.dy >=
            MediaQuery.sizeOf(context).height - _videoControlsHeight;
    _pointerDown = inVideoControls ? null : event.position;
  }

  void _handlePointerUp(PointerUpEvent event) {
    final start = _pointerDown;
    _pointerDown = null;
    if (start == null || !widget.state.settings.gesturesEnabled) return;
    final delta = event.position - start;
    if (delta.distance < 90) return;
    if (!(_post.isVideo || _transform.value.getMaxScaleOnAxis() <= 1)) return;
    if (delta.dx.abs() > delta.dy.abs()) {
      if (delta.dx < -90) _move(1);
      if (delta.dx > 90) _move(-1);
    } else if (delta.dy > 90) {
      if (_details) {
        setState(() => _details = false);
      } else {
        Navigator.maybePop(context);
      }
    } else if (delta.dy < -90) {
      setState(() => _details = true);
    }
  }

  void _handlePointerCancel(PointerCancelEvent _) => _pointerDown = null;

  void _disposeVideo() {
    _videoGeneration++;
    final player = _player;
    _player = null;
    player?.dispose();
    final video = _video;
    _video = null;
    video?.dispose();
  }

  void _move(int amount) {
    if (widget.posts.isEmpty) return;
    final next = _index + amount;
    if (next < 0 || next >= widget.posts.length) return;
    _disposeVideo();
    setState(() {
      _index = next;
      _videoError = null;
      _details = false;
      _transform.value = Matrix4.identity();
    });
    if (_post.isVideo) _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    final generation = ++_videoGeneration;
    final url = _mediaUrl(_post);
    if (url.isEmpty) {
      if (mounted) {
        setState(() => _videoError = 'This video has no playable URL.');
      }
      return;
    }
    final video = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: widget.board == Board.gelbooru
          ? const {
              'Referer': 'https://gelbooru.com/',
              'User-Agent': 'BooruPlus/1.0',
            }
          : const {},
    );
    _video = video;
    try {
      await video.initialize();
      if (!mounted ||
          generation != _videoGeneration ||
          !identical(_video, video)) {
        await video.dispose();
        return;
      }
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
      if (!mounted ||
          generation != _videoGeneration ||
          !identical(_video, video)) {
        player.dispose();
        await video.dispose();
        return;
      }
      _player = player;
      await video.setVolume(_muted ? 0 : 1);
      if (!mounted ||
          generation != _videoGeneration ||
          !identical(_video, video)) {
        player.dispose();
        await video.dispose();
        return;
      }
      if (_lifecycle == AppLifecycleState.resumed) await video.play();
      if (mounted && generation == _videoGeneration) setState(() {});
    } catch (_) {
      if (generation == _videoGeneration && mounted) {
        setState(
          () => _videoError = 'Unable to stream this video. The server or this device may not support its format.',
        );
      }
      if (generation == _videoGeneration && identical(_video, video)) {
        _video = null;
      }
      await video.dispose();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    if (state != AppLifecycleState.resumed) _video?.pause();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _videoGeneration++;
    _player?.dispose();
    _video?.dispose();
    _transform.dispose();
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
        name: '${widget.board.name}_${_post.id}.$extension',
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
    final uri = Uri.tryParse(_postBrowserUrl(widget.board, _post));
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
    final site = appearanceFor(widget.board);
    final browserUrl = _postBrowserUrl(widget.board, post);
    return Scaffold(
      backgroundColor: post.isVideo ? Colors.black : canvas,
      appBar: AppBar(
        backgroundColor: site.surface,
        title: Row(
          children: [
            SiteLogo(widget.board, size: 26, colored: true),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.board.label,
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
                child: post.isVideo
                    ? _videoError != null
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  _videoError!,
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            )
                          : _player == null
                          ? const Center(child: CircularProgressIndicator())
                          : Container(
                              color: Colors.black,
                              child: Chewie(controller: _player!),
                            )
                    : GestureDetector(
                        onDoubleTap: () => _transform.value =
                            _transform.value.getMaxScaleOnAxis() > 1
                            ? Matrix4.identity()
                            : Matrix4.diagonal3Values(2.5, 2.5, 1),
                        child: InteractiveViewer(
                          transformationController: _transform,
                          minScale: .5,
                          maxScale: 8,
                          child: Center(
                            child: _mediaUrl(post).isEmpty
                                ? const Padding(
                                    padding: EdgeInsets.all(24),
                                    child: Text(
                                      'The original image is unavailable. It may have been removed or require website access.',
                                      textAlign: TextAlign.center,
                                    ),
                                  )
                                : MediaImage(
                                    url: _mediaUrl(post),
                                    board: widget.board,
                                    fit: BoxFit.contain,
                                    errorMessage: 'The original image is unavailable. It may have been removed or require website access.',
                                  ),
                          ),
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
                      const Icon(
                        Icons.favorite_border,
                        size: 15,
                        color: Colors.white38,
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
                              icon: const Icon(Icons.open_in_browser, size: 16),
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
                                      Navigator.pop(context, tag.name),
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
