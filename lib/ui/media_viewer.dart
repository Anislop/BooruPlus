import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import 'theme.dart';

class MediaViewer extends StatefulWidget {
  const MediaViewer({
    super.key,
    required this.post,
    required this.board,
    required this.state,
  });
  final MediaPost post;
  final Board board;
  final AppState state;
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
  AppLifecycleState _lifecycle =
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.post.isVideo) _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    final video = VideoPlayerController.networkUrl(Uri.parse(widget.post.url));
    _video = video;
    try {
      await video.initialize();
      if (!mounted) return;
      _player = ChewieController(
        videoPlayerController: video,
        autoPlay: false,
        looping: true,
        allowFullScreen: true,
        allowMuting: true,
        showControls: true,
        playbackSpeeds: const [.25, .5, .75, 1, 1.25, 1.5, 2],
        errorBuilder: (_, _) => const Center(
          child: Text('This video could not be played. Try reopening it.'),
        ),
      );
      if (_lifecycle == AppLifecycleState.resumed) await video.play();
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) {
        setState(
          () => _videoError = 'Unable to stream this video. The server or this device may not support its format.',
        );
      }
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
    _player?.dispose();
    _video?.dispose();
    _transform.dispose();
    super.dispose();
  }

  Future<void> _download() async {
    setState(() => _downloading = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = Uri.parse(widget.post.url).path;
      final extension = path.contains('.')
          ? path.split('.').last.replaceAll(RegExp('[^a-zA-Z0-9]'), '')
          : 'jpg';
      await const MethodChannel('booruplus/platform')
          .invokeMethod<String>('download', {
            'url': widget.post.url,
            'name': '${widget.board.name}_${widget.post.id}.$extension',
            'directory': widget.state.settings.downloadDirectory,
          });
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
    final uri = Uri.tryParse(widget.post.source);
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

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.board.label,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            Text(
              '#${post.id}',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Download original media',
            onPressed: _downloading ? null : _download,
            icon: _downloading
                ? const SizedBox.square(
                    dimension: 21,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_outlined),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
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
                        : Chewie(controller: _player!)
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
                          child: Image.network(
                            post.url,
                            fit: BoxFit.contain,
                            loadingBuilder: (_, child, progress) =>
                                progress == null
                                ? child
                                : Center(
                                    child: CircularProgressIndicator(
                                      value: progress.expectedTotalBytes == null
                                          ? null
                                          : progress.cumulativeBytesLoaded /
                                                progress.expectedTotalBytes!,
                                    ),
                                  ),
                            errorBuilder: (_, _, _) => const Padding(
                              padding: EdgeInsets.all(24),
                              child: Text(
                                'The original image is unavailable. It may have been removed or require website access.',
                                textAlign: TextAlign.center,
                              ),
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
                  IconButton(
                    tooltip: 'Mute or unmute',
                    onPressed: () {
                      setState(() => _muted = !_muted);
                      _video!.setVolume(_muted ? 0 : 1);
                    },
                    icon: Icon(_muted ? Icons.volume_off : Icons.volume_up),
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
                ],
              ),
            Material(
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
                      Icon(
                        _details
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_up,
                      ),
                    ],
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
                  child: SingleChildScrollView(
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
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            for (final tag in post.tags)
                              ActionChip(
                                label: Text(
                                  tag,
                                  style: const TextStyle(fontSize: 12),
                                ),
                                onPressed: () => Navigator.pop(context, tag),
                              ),
                          ],
                        ),
                      ],
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
