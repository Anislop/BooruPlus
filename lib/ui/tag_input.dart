import 'package:flutter/material.dart';

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
  });
  final List<String> tags;
  final ValueChanged<List<String>> onChanged;
  final VoidCallback? onSubmit;
  final String hint;
  final bool enabled;
  @override
  TagInputState createState() => TagInputState();
}

class TagInputState extends State<TagInput> {
  final _controller = TextEditingController();
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
    ],
  );
}
