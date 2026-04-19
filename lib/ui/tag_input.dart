import 'dart:async';

import 'package:flutter/material.dart';

import '../core/models.dart';
import 'theme.dart';

/// Whitespace commits tokens; underscores remain part of a booru tag.
class TagInput extends StatefulWidget {
  const TagInput({
    super.key,
    required this.tags,
    required this.onChanged,
    this.hint = 'Search tags, then press space',
    this.enabled = true,
    this.onSubmit,
    this.onDraftChanged,
    this.autocomplete,
  });
  final List<String> tags;
  final ValueChanged<List<String>> onChanged;
  final VoidCallback? onSubmit;
  final ValueChanged<String>? onDraftChanged;
  final Future<List<TagSuggestion>> Function(String query)? autocomplete;
  final String hint;
  final bool enabled;
  @override
  TagInputState createState() => TagInputState();
}

class TagInputState extends State<TagInput> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<TagSuggestion> _suggestions = const [];

  bool get hasDraft => _controller.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    widget.onDraftChanged?.call(_controller.text);
    _debounce?.cancel();
    final query = _currentDraft;
    if (widget.autocomplete == null || query.length < 2) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 260), () async {
      final result = await widget.autocomplete!(query);
      if (mounted && _currentDraft == query) {
        setState(() => _suggestions = result);
      }
    });
  }

  String get _currentDraft {
    final text = _controller.text;
    if (text.trim().isEmpty || RegExp(r'\s$').hasMatch(text)) return '';
    return text.trim().split(RegExp(r'\s+')).last;
  }

  void _selectSuggestion(TagSuggestion suggestion) {
    if (!widget.enabled) return;
    final text = _controller.text;
    final draft = RegExp(r'\S*$').firstMatch(text);
    final start = draft?.start ?? text.length;
    final replacement = '${text.substring(0, start)}${suggestion.name} ';
    _controller.value = TextEditingValue(
      text: replacement,
      selection: TextSelection.collapsed(offset: replacement.length),
    );
    setState(() => _suggestions = const []);
    _commit();
  }

  void commit() => _commit(all: true);
  void _commit({bool all = false}) {
    if (!widget.enabled) return;
    final value = _controller.text;
    if (value.isEmpty || (!all && !RegExp(r'\s').hasMatch(value))) return;
    final parts = value.split(RegExp(r'\s+'));
    final remainder = all ? '' : parts.removeLast();
    final tokens = {
      ...widget.tags,
      ...parts.where((t) => t.isNotEmpty),
    }.toList();
    _controller.value = TextEditingValue(
      text: remainder,
      selection: TextSelection.collapsed(offset: remainder.length),
    );
    widget.onChanged(tokens);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (widget.tags.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final tag in widget.tags)
                InputChip(
                  label: Text(tag),
                  deleteIcon: const Icon(Icons.close, size: 16),
                  onDeleted: widget.enabled
                      ? () => widget.onChanged(
                          widget.tags.where((t) => t != tag).toList(),
                        )
                      : null,
                  backgroundColor: panel,
                ),
            ],
          ),
        ),
      TextField(
        controller: _controller,
        enabled: widget.enabled,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: widget.hint,
          prefixIcon: const Icon(Icons.search_rounded, size: 22),
          suffixIcon: IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.arrow_forward_rounded),
            onPressed: widget.enabled
                ? () {
                    _commit(all: true);
                    widget.onSubmit?.call();
                  }
                : null,
          ),
        ),
        onChanged: (_) => _commit(),
        onSubmitted: (_) {
          _commit(all: true);
          widget.onSubmit?.call();
        },
      ),
      if (_suggestions.isNotEmpty)
        Container(
          constraints: const BoxConstraints(maxHeight: 190),
          margin: const EdgeInsets.only(top: 4),
          decoration: BoxDecoration(
            color: panel,
            borderRadius: BorderRadius.circular(10),
          ),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _suggestions.length,
            itemBuilder: (context, index) {
              final suggestion = _suggestions[index];
              final color = _categoryColor(suggestion.category);
              return Material(
                color: Colors.transparent,
                child: ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  onTap: () => _selectSuggestion(suggestion),
                  leading: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  title: Text(suggestion.name, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    _categoryLabel(suggestion.category),
                    style: TextStyle(color: color, fontSize: 11),
                  ),
                  trailing: suggestion.postCount == null
                      ? null
                      : Text(
                          '${suggestion.postCount}',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                ),
              );
            },
          ),
        ),
    ],
  );
}

String _categoryLabel(TagCategory category) => category.label;

Color _categoryColor(TagCategory category) => switch (category) {
  TagCategory.artist => const Color(0xFFE8A0FF),
  TagCategory.character => const Color(0xFF8BC8FF),
  TagCategory.copyright => const Color(0xFFFFA56B),
  TagCategory.species => const Color(0xFF91D99B),
  TagCategory.meta => const Color(0xFFFFD166),
  TagCategory.lore => const Color(0xFFC1A7FF),
  _ => Colors.white70,
};
