import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/models.dart';
import '../core/services.dart';
import 'media_viewer.dart' show tagColor;
import 'theme.dart';

typedef TagWikiLoader = Future<TagWiki?> Function(Board board, String tag);

/// Shows a Sankaku-family tag's details and wiki article ("About tag").
/// Links in the article open that tag's article in place; [onSearch] is
/// called with the tag shown when the user chooses to search it.
Future<void> showTagWiki(
  BuildContext context, {
  required Board board,
  required String tag,
  required ValueChanged<String> onSearch,
  TagWikiLoader? load,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => TagWikiSheet(
    board: board,
    tag: tag,
    onSearch: onSearch,
    load: load ?? _loadCached,
  ),
);

// Articles change rarely; reopening one in a session needs no request.
final Map<String, Future<TagWiki?>> _cache = {};

Future<TagWiki?> _loadCached(Board board, String tag) {
  final key = '${board.name}\u0003$tag';
  final cached = _cache.remove(key);
  if (cached != null) return _cache[key] = cached;
  if (_cache.length >= 50) _cache.remove(_cache.keys.first);
  final future = DeviceService().tagWiki(board: board, tag: tag);
  // A failure is retried on the next open.
  future.catchError((Object _) {
    if (identical(_cache[key], future)) _cache.remove(key);
    return null;
  });
  return _cache[key] = future;
}

class TagWikiSheet extends StatefulWidget {
  const TagWikiSheet({
    super.key,
    required this.board,
    required this.tag,
    required this.onSearch,
    required this.load,
  });

  final Board board;
  final String tag;
  final ValueChanged<String> onSearch;
  final TagWikiLoader load;

  @override
  State<TagWikiSheet> createState() => _TagWikiSheetState();
}

class _TagWikiSheetState extends State<TagWikiSheet> {
  // Tags opened from article links, newest last; the first is widget.tag.
  late final List<String> _history = [widget.tag];
  late Future<TagWiki?> _wiki;
  final List<TapGestureRecognizer> _recognizers = [];
  List<WikiBlock>? _blocks;
  TagWiki? _parsed;

  String get _tag => _history.last;

  @override
  void initState() {
    super.initState();
    _wiki = widget.load(widget.board, _tag);
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  void _show(String tag) {
    setState(() {
      _history.add(tag);
      _wiki = widget.load(widget.board, tag);
    });
  }

  void _back() {
    if (_history.length < 2) return;
    setState(() {
      _history.removeLast();
      _wiki = widget.load(widget.board, _tag);
    });
  }

  void _retry() => setState(() => _wiki = widget.load(widget.board, _tag));

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !['https', 'http'].contains(uri.scheme)) return;
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw StateError('Unavailable');
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to open this link.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: .6,
    minChildSize: .3,
    maxChildSize: .92,
    builder: (context, controller) => FutureBuilder<TagWiki?>(
      future: _wiki,
      builder: (context, snapshot) {
        final Widget body;
        if (snapshot.connectionState != ConnectionState.done) {
          body = const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          );
        } else if (snapshot.hasError) {
          body = _message(
            'Could not load this tag. Check your connection.',
            action: TextButton(onPressed: _retry, child: const Text('Retry')),
          );
        } else if (snapshot.data == null) {
          body = _message('${widget.board.label} has no tag named $_tag.');
        } else {
          body = _details(snapshot.data!);
        }
        return ListView(
          key: const ValueKey('tag_wiki_sheet'),
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            Row(
              children: [
                if (_history.length > 1)
                  IconButton(
                    tooltip: 'Back',
                    onPressed: _back,
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                Expanded(
                  child: Text(
                    'About tag',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: () {
                    final tag = snapshot.data?.name ?? _tag;
                    Navigator.pop(context);
                    widget.onSearch(tag);
                  },
                  icon: const Icon(Icons.search_rounded, size: 18),
                  label: const Text('Search'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            body,
          ],
        );
      },
    ),
  );

  Widget _message(String text, {Widget? action}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Column(
      children: [
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: ink(.70)),
        ),
        ?action,
      ],
    ),
  );

  Widget _details(TagWiki wiki) {
    final color = tagColor(wiki.category);
    final title = wiki.displayName.isEmpty ? wiki.name : wiki.displayName;
    final facts = [
      wiki.category.label,
      '${wiki.postCount} post${wiki.postCount == 1 ? '' : 's'}',
      if (wiki.poolCount > 0)
        '${wiki.poolCount} pool${wiki.poolCount == 1 ? '' : 's'}',
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          title,
          style: TextStyle(
            color: color,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (wiki.japaneseName.isNotEmpty && wiki.japaneseName != title)
          SelectableText(wiki.japaneseName, style: TextStyle(color: ink(.70))),
        const SizedBox(height: 4),
        Text(
          wiki.name == title ? facts : '${wiki.name} · $facts',
          style: TextStyle(color: ink(.54), fontSize: 12),
        ),
        if (wiki.alias != null) ...[
          const SizedBox(height: 8),
          Text(
            '${wiki.alias} is an alias of this tag.',
            style: TextStyle(color: ink(.70), fontStyle: FontStyle.italic),
          ),
        ],
        if (wiki.aliasOf != null) ...[
          const SizedBox(height: 8),
          InkWell(
            onTap: () => _show(wiki.aliasOf!),
            child: Text(
              'Alias of ${wiki.aliasOf}',
              style: const TextStyle(
                color: accent,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ],
        const SectionLabel('Description'),
        if (wiki.body.trim().isEmpty)
          Text(
            'This tag has no description yet.',
            style: TextStyle(color: ink(.54)),
          )
        else
          ..._article(wiki),
        if (wiki.updatedAt != null) ...[
          const SizedBox(height: 16),
          Text(
            'Updated ${_date(wiki.updatedAt!)}',
            style: TextStyle(color: ink(.38), fontSize: 11),
          ),
        ],
      ],
    );
  }

  List<Widget> _article(TagWiki wiki) {
    if (!identical(_parsed, wiki)) {
      _parsed = wiki;
      _blocks = parseDText(wiki.body);
    }
    // Each build makes new link recognizers; the last build's are unused.
    _disposeRecognizers();
    final base = Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    return [
      for (final block in _blocks!)
        Padding(
          padding: EdgeInsets.only(
            left: block.indent * 16.0,
            top: block.heading ? 12 : 2,
            bottom: 2,
          ),
          child: Text.rich(
            TextSpan(
              style: block.heading
                  ? base.copyWith(fontWeight: FontWeight.w700, fontSize: 15)
                  : base,
              children: [
                if (block.indent > 0) const TextSpan(text: '•  '),
                for (final span in block.spans) _span(span),
              ],
            ),
          ),
        ),
    ];
  }

  InlineSpan _span(WikiSpan span) {
    final bold = span.bold ? FontWeight.w700 : null;
    final target = span.tag ?? span.url;
    if (target == null) {
      return TextSpan(
        text: span.text,
        style: TextStyle(fontWeight: bold),
      );
    }
    final recognizer = TapGestureRecognizer()
      ..onTap = span.tag != null
          ? () => _show(span.tag!)
          : () => _openUrl(span.url!);
    _recognizers.add(recognizer);
    return TextSpan(
      text: span.text,
      recognizer: recognizer,
      style: TextStyle(
        color: accent,
        fontWeight: bold,
        decoration: span.url != null ? TextDecoration.underline : null,
      ),
    );
  }

  static String _date(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }
}

/// A line of a wiki article: a heading, a paragraph, or a list item
/// ([indent] > 0).
class WikiBlock {
  const WikiBlock(this.spans, {this.heading = false, this.indent = 0});
  final List<WikiSpan> spans;
  final bool heading;
  final int indent;

  String get text => spans.map((span) => span.text).join();
}

/// Article text; a link to another tag's article ([tag]) or a web page
/// ([url]).
class WikiSpan {
  const WikiSpan(this.text, {this.tag, this.url, this.bold = false});
  final String text;
  final String? tag, url;
  final bool bold;
}

final _heading = RegExp(r'^h[1-6]\.\s*');
final _bullet = RegExp(r'^(\*+)\s+');
final _inline = RegExp(
  r'\[\[([^\]|]+)(?:\|([^\]]*))?\]\]'
  r'|\[(/?)(b|i|u|s|tn|spoiler|quote|code|expand|nodtext)(?:=[^\]]*)?\]'
  r'|"([^"\n]+)":\[?(https?://[^\s\]]+)\]?'
  r'|(https?://[^\s<>\[\]]+)',
  caseSensitive: false,
);
final _qualifier = RegExp(r'\s*\([^)]*\)$');

/// Reads the subset of DText Sankaku articles use: `h1.`-`h6.` headings,
/// `*` lists, `[[tag|label]]` links, `"label":url` and bare links, and
/// `[b]` emphasis. Other markup tags are dropped and their text kept.
List<WikiBlock> parseDText(String body) {
  final blocks = <WikiBlock>[];
  for (final raw in body.replaceAll('\r\n', '\n').split('\n')) {
    var line = raw.trim();
    if (line.isEmpty) continue;
    var heading = false;
    var indent = 0;
    final headingMatch = _heading.firstMatch(line);
    if (headingMatch != null) {
      heading = true;
      line = line.substring(headingMatch.end);
    } else {
      final bulletMatch = _bullet.firstMatch(line);
      if (bulletMatch != null) {
        indent = bulletMatch.group(1)!.length;
        line = line.substring(bulletMatch.end);
      }
    }
    final spans = _inlineSpans(line);
    if (spans.isNotEmpty) {
      blocks.add(WikiBlock(spans, heading: heading, indent: indent));
    }
  }
  return blocks;
}

List<WikiSpan> _inlineSpans(String line) {
  final spans = <WikiSpan>[];
  var bold = false;
  var start = 0;
  void text(String value) {
    if (value.isNotEmpty) spans.add(WikiSpan(value, bold: bold));
  }

  for (final match in _inline.allMatches(line)) {
    text(line.substring(start, match.start));
    start = match.end;
    if (match.group(1) != null) {
      final target = match.group(1)!.trim();
      final label = match.group(2);
      // An empty label (`[[name (series)|]]`) drops the qualifier.
      final shown = label == null
          ? target
          : label.trim().isEmpty
          ? target.replaceFirst(_qualifier, '')
          : label.trim();
      spans.add(
        WikiSpan(
          shown,
          tag: target.toLowerCase().replaceAll(RegExp(r'\s+'), '_'),
          bold: bold,
        ),
      );
    } else if (match.group(4) != null) {
      if (match.group(4)!.toLowerCase() == 'b') bold = match.group(3)!.isEmpty;
    } else if (match.group(5) != null) {
      spans.add(WikiSpan(match.group(5)!, url: match.group(6), bold: bold));
    } else {
      final url = match.group(7)!;
      spans.add(WikiSpan(url, url: url, bold: bold));
    }
  }
  text(line.substring(start));
  return spans;
}
