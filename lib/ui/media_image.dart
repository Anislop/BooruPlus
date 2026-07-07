import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/services.dart';

class MediaImage extends StatefulWidget {
  const MediaImage({
    super.key,
    required this.url,
    required this.board,
    this.fit = BoxFit.contain,
    this.cacheWidth,
    this.cacheHeight,
    this.maxDimension,
    this.errorMessage = 'The original image is unavailable.',
    this.mediaService,
    this.errorWidget,
    this.loadingWidget,
    this.showProgress = false,
  });

  final String url;
  final Board board;
  final BoxFit fit;
  final int? cacheWidth;
  final int? cacheHeight;

  /// Caps the decoded size on the longest side, preserving aspect ratio.
  /// Overrides [cacheWidth] and [cacheHeight]; images are never upscaled.
  final int? maxDimension;
  final String errorMessage;
  final MediaService? mediaService;
  final Widget? errorWidget;
  final Widget? loadingWidget;

  /// Shows a progress bar while loading instead of [loadingWidget]; it fills
  /// as bytes arrive when the size is known (network images).
  final bool showProgress;

  /// Whether [url] is fetched and prepared natively rather than handed to
  /// [NetworkImage]: authenticated Gelbooru media, and Sankaku AVIF previews.
  /// Flutter decodes AVIF through Android's ImageDecoder while blocking the
  /// UI thread for the whole decode, so a grid of them freezes the app; the
  /// native side converts them on a background thread instead.
  static bool fetchesNatively(Board board, String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.scheme != 'https') return false;
    final host = uri.host.toLowerCase();
    return switch (board) {
      Board.gelbooru =>
        (host == 'gelbooru.com' || host.endsWith('.gelbooru.com')) &&
            uri.queryParameters['api_key']?.isNotEmpty == true &&
            uri.queryParameters['user_id']?.isNotEmpty == true,
      Board.sankaku || Board.idolcomplex =>
        (host == 'sankakucomplex.com' ||
                host.endsWith('.sankakucomplex.com')) &&
            uri.path.toLowerCase().endsWith('.avif'),
      _ => false,
    };
  }

  @override
  State<MediaImage> createState() => _MediaImageState();
}

class _MediaImageState extends State<MediaImage> {
  Future<Uint8List>? _mediaFuture;

  bool get _hasUrl => widget.url.trim().isNotEmpty;
  bool get _useNativeFetch =>
      _hasUrl && MediaImage.fetchesNatively(widget.board, widget.url);

  @override
  void initState() {
    super.initState();
    _updateFuture();
  }

  @override
  void didUpdateWidget(covariant MediaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.board != widget.board) {
      _updateFuture();
    }
  }

  void _updateFuture() {
    _mediaFuture = _useNativeFetch && _hasUrl
        ? (widget.mediaService ?? MediaService()).fetchMedia(
            board: widget.board,
            url: widget.url,
          )
        : null;
  }

  ImageProvider _bounded(ImageProvider provider) {
    final max = widget.maxDimension;
    if (max == null) {
      return ResizeImage.resizeIfNeeded(
        widget.cacheWidth,
        widget.cacheHeight,
        provider,
      );
    }
    return ResizeImage(
      provider,
      width: max,
      height: max,
      policy: ResizeImagePolicy.fit,
    );
  }

  Widget _error() =>
      widget.errorWidget ??
      Padding(
        padding: const EdgeInsets.all(24),
        child: Text(widget.errorMessage, textAlign: TextAlign.center),
      );

  Widget _loading([ImageChunkEvent? progress]) {
    if (!widget.showProgress) {
      return widget.loadingWidget ??
          const Center(child: CircularProgressIndicator());
    }
    final total = progress?.expectedTotalBytes;
    final value = total == null || total <= 0
        ? null
        : (progress!.cumulativeBytesLoaded / total).clamp(0.0, 1.0);
    return Center(
      child: SizedBox(
        width: 200,
        child: LinearProgressIndicator(
          key: const ValueKey('media_progress'),
          value: value,
          minHeight: 4,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasUrl) return _error();
    if (!_useNativeFetch) {
      return Image(
        image: _bounded(NetworkImage(widget.url)),
        fit: widget.fit,
        loadingBuilder: (_, child, progress) =>
            progress == null ? child : _loading(progress),
        errorBuilder: (_, _, _) => _error(),
      );
    }

    return FutureBuilder<Uint8List>(
      future: _mediaFuture,
      builder: (_, snapshot) {
        if (snapshot.hasError || !snapshot.hasData) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return _loading();
          }
          return _error();
        }
        return Image(
          image: _bounded(MemoryImage(snapshot.data!)),
          fit: widget.fit,
          errorBuilder: (_, _, _) => _error(),
        );
      },
    );
  }
}
