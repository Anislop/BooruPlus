import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
    this.postCount,
    this.searchStyle = true,
    this.suggestionsAbove = false,
  });
  final List<String> tags;
  final ValueChanged<List<String>> onChanged;
  final VoidCallback? onSubmit;
  final ValueChanged<String>? onDraftChanged;
  final Future<List<TagSuggestion>> Function(String query)? autocomplete;

  /// The post count last reported for a tag, shown on its chip.
  final int? Function(String tag)? postCount;
  final String hint;
  final bool enabled;

  /// Shows the search icon and the submit arrow; off for tag lists that
  /// are not searches, such as blocked tags.
  final bool searchStyle;

  /// Lists autocomplete suggestions above the field, for a field at the
  /// bottom of the screen.
  final bool suggestionsAbove;
  @override
  TagInputState createState() => TagInputState();
}

class TagInputState extends State<TagInput> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  List<TagSuggestion> _suggestions = const [];

  bool get hasDraft => _controller.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    _focus.addListener(_onFocusChanged);
    _focus.onKeyEvent = _onKey;
  }

  // Backspace with nothing typed deletes the last chip, as if it were text.
  // Keyboards send it as a key event only when there is no text to delete.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent ||
        event.logicalKey != LogicalKeyboardKey.backspace ||
        !widget.enabled ||
        widget.tags.isEmpty) {
      return KeyEventResult.ignored;
    }
    final selection = _controller.selection;
    if (_controller.text.isNotEmpty &&
        !(selection.isCollapsed && selection.baseOffset == 0)) {
      return KeyEventResult.ignored;
    }
    widget.onChanged(widget.tags.sublist(0, widget.tags.length - 1));
    return KeyEventResult.handled;
  }

  // Redraws the field's focused outline.
  void _onFocusChanged() {
    if (mounted) setState(() {});
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
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    super.dispose();
  }

  /// Counts are shown for plain included tags only.
  int? _chipCount(String tag) {
    if (tag.startsWith('-') || tag.contains(':')) return null;
    return widget.postCount?.call(tag);
  }

  void _submit() {
    _commit(all: true);
    widget.onSubmit?.call();
  }

  // Committed tags sit inside the field as chips, ahead of the text being
  // typed; the text field wraps onto a new line when the row is full.
  Widget _field(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onTap: widget.enabled ? _focus.requestFocus : null,
    child: InputDecorator(
      isFocused: _focus.hasFocus,
      isEmpty: false,
      decoration: InputDecoration(
        enabled: widget.enabled,
        prefixIcon: widget.searchStyle
            ? const Icon(Icons.search_rounded, size: 22)
            : null,
        suffixIcon: widget.searchStyle
            ? IconButton(
                tooltip: 'Search',
                icon: const Icon(Icons.arrow_forward_rounded),
                onPressed: widget.enabled ? _submit : null,
              )
            : null,
        contentPadding: EdgeInsets.symmetric(
          horizontal: widget.searchStyle ? 0 : 16,
          vertical: 8,
        ),
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final tag in widget.tags)
            InputChip(
              label: Text.rich(
                TextSpan(
                  text: tag,
                  children: [
                    if (_chipCount(tag) case final count?)
                      TextSpan(
                        text: '  ${compactCount(count)}',
                        style: TextStyle(color: ink(.54), fontSize: 11),
                      ),
                  ],
                ),
              ),
              deleteIcon: const Icon(Icons.close, size: 16),
              onDeleted: widget.enabled
                  ? () => widget.onChanged(
                      widget.tags.where((t) => t != tag).toList(),
                    )
                  : null,
              backgroundColor: panel,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 96),
            child: IntrinsicWidth(
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                enabled: widget.enabled,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration.collapsed(
                  hintText: widget.tags.isEmpty ? widget.hint : 'Add tag',
                ),
                onChanged: (_) => _commit(),
                onSubmitted: (_) => _submit(),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!widget.suggestionsAbove) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _field(context),
          if (_suggestions.isNotEmpty) _suggestionList(),
        ],
      );
    }
    // Above the field (one-handed mode), the suggestions take the room the
    // field leaves, best match nearest the field, so none is cut off at the
    // top. The field scrolls by itself, its typing line kept in view.
    return LayoutBuilder(
      builder: (context, constraints) {
        final suggesting = _suggestions.isNotEmpty;
        final field = SingleChildScrollView(
          reverse: true,
          child: _field(context),
        );
        if (!constraints.hasBoundedHeight) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [if (suggesting) _suggestionList(), field],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (suggesting) Flexible(child: _suggestionList()),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: suggesting ? 112 : constraints.maxHeight,
              ),
              child: field,
            ),
          ],
        );
      },
    );
  }

  Widget _suggestionList() => Container(
    constraints: const BoxConstraints(maxHeight: 190),
    margin: widget.suggestionsAbove
        ? const EdgeInsets.only(bottom: 4)
        : const EdgeInsets.only(top: 4),
    decoration: BoxDecoration(
      color: panel,
      borderRadius: BorderRadius.circular(10),
    ),
    child: ListView.builder(
      shrinkWrap: true,
      reverse: widget.suggestionsAbove,
      padding: EdgeInsets.zero,
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
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
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
                    style: TextStyle(color: ink(.54), fontSize: 11),
                  ),
          ),
        );
      },
    ),
  );
}

String _categoryLabel(TagCategory category) => category.label;

/// 1234 → 1.2k, 2500000 → 2.5M.
String compactCount(int count) {
  String scaled(double value, String unit) =>
      '${value >= 10 ? value.round() : (value * 10).round() / 10}$unit'
          .replaceFirst('.0$unit', unit);
  if (count >= 1000000) return scaled(count / 1000000, 'M');
  if (count >= 1000) return scaled(count / 1000, 'k');
  return '$count';
}

Color _categoryColor(TagCategory category) => switch (category) {
  TagCategory.artist => tagTone(const Color(0xFFE8A0FF)),
  TagCategory.character => tagTone(const Color(0xFF8BC8FF)),
  TagCategory.copyright => tagTone(const Color(0xFFFFA56B)),
  TagCategory.species => tagTone(const Color(0xFF91D99B)),
  TagCategory.meta => tagTone(const Color(0xFFFFD166)),
  TagCategory.lore => tagTone(const Color(0xFFC1A7FF)),
  _ => ink(.70),
};
