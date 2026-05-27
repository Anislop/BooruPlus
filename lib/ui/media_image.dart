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

  @override
  State<MediaImage> createState() => _MediaImageState();
}

class _MediaImageState extends State<MediaImage> {
  Future<Uint8List>? _mediaFuture;

  bool get _hasUrl => widget.url.trim().isNotEmpty;
  bool get _useNativeFetch {
    if (widget.board != Board.gelbooru || !_hasUrl) return false;
    final uri = Uri.tryParse(widget.url);
    final host = uri?.host.toLowerCase() ?? '';
    final parameters = uri?.queryParameters;
    return uri?.scheme == 'https' &&
        (host == 'gelbooru.com' || host.endsWith('.gelbooru.com')) &&
        parameters?['api_key']?.isNotEmpty == true &&
        parameters?['user_id']?.isNotEmpty == true;
  }

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

  @override
  Widget build(BuildContext context) {
    if (!_hasUrl) return _error();
    if (!_useNativeFetch) {
      return Image(
        image: _bounded(NetworkImage(widget.url)),
        fit: widget.fit,
        loadingBuilder: (_, child, progress) => progress == null
            ? child
            : const Center(child: CircularProgressIndicator()),
        errorBuilder: (_, _, _) => _error(),
      );
    }

    return FutureBuilder<Uint8List>(
      future: _mediaFuture,
      builder: (_, snapshot) {
        if (snapshot.hasError || !snapshot.hasData) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
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
