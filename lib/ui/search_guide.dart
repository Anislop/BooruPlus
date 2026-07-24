import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import 'site_catalog.dart';
import 'theme.dart';

class SearchGuideScreen extends StatefulWidget {
  const SearchGuideScreen({super.key, required this.board});

  final Board board;

  @override
  State<SearchGuideScreen> createState() => _SearchGuideScreenState();
}

class _SearchGuideScreenState extends State<SearchGuideScreen> {
  String? _guideText;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadGuide();
  }

  Future<void> _loadGuide() async {
    try {
      final jsonString = await rootBundle.loadString(
        'assets/search_guides.json',
      );
      final decoded = jsonDecode(jsonString);
      if (decoded is Map && mounted) {
        final content = decoded[widget.board.name];
        setState(() {
          _guideText = content is String
              ? content
              : _fallbackGuide(widget.board);
          _loading = false;
        });
        return;
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        _guideText = _fallbackGuide(widget.board);
        _loading = false;
      });
    }
  }

  String _fallbackGuide(Board board) =>
      '# ${board.label} Search Guide\n\n'
      '## Basic Search\n'
      '- Separate tags with spaces for an **AND** search: `tag1 tag2`\n'
      '- Exclude tags with a hyphen (`-`): `-tag`\n'
      '- Multi-word tags use underscores: `example_tag`\n\n'
      '## Metatags\n'
      '- **rating:safe** (or `rating:s`) — Restrict to safe content.\n'
      '- **score:>10** — Minimum score filter.\n'
      '- **order:score** — Order by score or popularity.';

  @override
  Widget build(BuildContext context) {
    final site = appearanceFor(widget.board);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: appBarSurface(widget.board),
        title: Row(
          children: [
            SiteLogo(widget.board, size: 28, colored: true),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                site.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
                    children: _buildMarkdownBlocks(
                      context,
                      _guideText ?? '',
                      site.accent,
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  List<Widget> _buildMarkdownBlocks(
    BuildContext context,
    String markdown,
    Color accentColor,
  ) {
    final widgets = <Widget>[];
    final lines = markdown.split('\n');

    for (var i = 0; i < lines.length; i++) {
      final rawLine = lines[i];
      final line = rawLine.trimRight();

      if (line.isEmpty) {
        continue;
      }

      if (line.startsWith('# ')) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 12),
            child: Text(
              line.substring(2).trim(),
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
                color: ink(1),
              ),
            ),
          ),
        );
      } else if (line.startsWith('## ')) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(top: 22, bottom: 10),
            child: Text(
              line.substring(3).trim(),
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: accentColor,
              ),
            ),
          ),
        );
      } else if (line.startsWith('### ')) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 8),
            child: Text(
              line.substring(4).trim(),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: ink(1),
              ),
            ),
          ),
        );
      } else if (line.startsWith('- ') || line.startsWith('* ')) {
        final content = line.substring(2).trim();
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 3, right: 10, left: 4),
                  child: Text(
                    '•',
                    style: TextStyle(
                      color: accentColor,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: _parseInlineSpans(
                        content,
                        TextStyle(
                          fontSize: 14.5,
                          height: 1.45,
                          color: ink(.70),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      } else {
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text.rich(
              TextSpan(
                children: _parseInlineSpans(
                  line,
                  TextStyle(fontSize: 14.5, height: 1.5, color: ink(.70)),
                ),
              ),
            ),
          ),
        );
      }
    }

    return widgets;
  }

  static List<InlineSpan> _parseInlineSpans(String text, TextStyle baseStyle) {
    final spans = <InlineSpan>[];
    final pattern = RegExp(
      r'(\*\*\*(.+?)\*\*\*|___(.+?)___|\*\*(.+?)\*\*|__(.+?)__|(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)|`([^`]+)`)',
    );
    var currentIndex = 0;

    for (final match in pattern.allMatches(text)) {
      if (match.start > currentIndex) {
        spans.add(
          TextSpan(
            text: text.substring(currentIndex, match.start),
            style: baseStyle,
          ),
        );
      }

      if (match.group(2) != null || match.group(3) != null) {
        // Bold Italic
        final content = match.group(2) ?? match.group(3)!;
        spans.add(
          TextSpan(
            text: content,
            style: baseStyle.copyWith(
              fontWeight: FontWeight.bold,
              fontStyle: FontStyle.italic,
              color: ink(1),
            ),
          ),
        );
      } else if (match.group(4) != null || match.group(5) != null) {
        // Bold
        final content = match.group(4) ?? match.group(5)!;
        spans.add(
          TextSpan(
            text: content,
            style: baseStyle.copyWith(
              fontWeight: FontWeight.bold,
              color: ink(1),
            ),
          ),
        );
      } else if (match.group(6) != null) {
        // Italic
        final content = match.group(6)!;
        spans.add(
          TextSpan(
            text: content,
            style: baseStyle.copyWith(fontStyle: FontStyle.italic),
          ),
        );
      } else if (match.group(7) != null) {
        // Inline code
        final content = match.group(7)!;
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: ink(.08),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: ink(.15), width: 0.8),
              ),
              child: Text(
                content,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                  color: Color(0xFF81D4FA),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        );
      }
      currentIndex = match.end;
    }

    if (currentIndex < text.length) {
      spans.add(TextSpan(text: text.substring(currentIndex), style: baseStyle));
    }

    return spans;
  }
}
