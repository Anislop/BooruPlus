import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../core/services.dart';
import 'onboarding.dart';
import 'tag_input.dart';
import 'theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.state});
  final AppState state;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings _settings;
  final _downloads = DownloadService();
  final _blacklistKey = GlobalKey<TagInputState>();
  bool _busy = false;
  bool _picking = false;
  String? _error;
  bool _hasDraftTag = false;

  bool get _hasUnsavedChanges =>
      _settings != widget.state.settings || _hasDraftTag;

  @override
  void initState() {
    super.initState();
    _settings = widget.state.settings;
  }

  Future<void> _pickFolder() async {
    setState(() => _picking = true);
    try {
      final directory = await _downloads.chooseDirectory();
      if (directory != null && mounted) {
        setState(
          () => _settings = _settings.copyWith(downloadDirectory: directory),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Unable to choose a folder. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _save() async {
    _blacklistKey.currentState?.commit();
    setState(() {
      _busy = true;
      _error = null;
      _hasDraftTag = false;
    });
    try {
      await widget.state.updateSettings(_settings);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not save settings. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _slider(
    String title,
    String subtitle,
    int value,
    int min,
    int max,
    int divisions,
    ValueChanged<int> change,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          Text(
            '$value',
            style: const TextStyle(
              color: accent,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
      const SizedBox(height: 4),
      Text(
        subtitle,
        style: const TextStyle(
          color: Colors.white54,
          fontSize: 12,
          height: 1.5,
        ),
      ),
      Slider(
        value: value.toDouble(),
        min: min.toDouble(),
        max: max.toDouble(),
        divisions: divisions,
        label: '$value',
        onChanged: _busy ? null : (v) => change(v.round()),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final hasUnsaved = _hasUnsavedChanges;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              children: [
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  child: hasUnsaved
                      ? Container(
                          key: const ValueKey('unsaved_settings_flair'),
                          width: double.infinity,
                          margin: const EdgeInsets.fromLTRB(24, 12, 24, 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFF382312), Color(0xFF2A1B12)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: const Color(0xFFFFB74D)
                                  .withValues(alpha: 0.45),
                              width: 1.2,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.25),
                                blurRadius: 10,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFB74D)
                                      .withValues(alpha: 0.18),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.warning_amber_rounded,
                                  color: Color(0xFFFFB74D),
                                  size: 18,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 5,
                                            vertical: 1.5,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFFFB74D)
                                                .withValues(alpha: 0.25),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: const Text(
                                            'UNSAVED',
                                            style: TextStyle(
                                              color: Color(0xFFFFB74D),
                                              fontSize: 9.5,
                                              fontWeight: FontWeight.w800,
                                              letterSpacing: 0.6,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        const Flexible(
                                          child: Text(
                                            'Unsaved preferences',
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 13,
                                              color: Color(0xFFFFE0B2),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 2),
                                    const Text(
                                      'You have unsaved changes. Remember to save before leaving.',
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        color: Color(0xFFD4B89B),
                                        height: 1.2,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                onPressed: _busy || _picking ? null : _save,
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(0xFFFFB74D),
                                  foregroundColor: const Color(0xFF231407),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  minimumSize: Size.zero,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  textStyle: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12.5,
                                  ),
                                ),
                                child: Text(_busy ? 'Saving…' : 'Save'),
                              ),
                            ],
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                    children: [
                      const SectionLabel('BooruPlus Preferences'),
                      const Text(
                        'See media grids, discovery posts and more.',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                          letterSpacing: -.7,
                        ),
                      ),
                      const SectionLabel('Media grid'),
                      _slider(
                        'Columns',
                        'Number of tiles across the screen.',
                        _settings.columns,
                        1,
                        6,
                        5,
                        (v) => setState(
                          () => _settings = _settings.copyWith(columns: v),
                        ),
                      ),
                      _slider(
                        'Rows',
                        'Rows per screen. Smaller screens retain a readable minimum tile height.',
                        _settings.rows,
                        2,
                        8,
                        6,
                        (v) => setState(
                          () => _settings = _settings.copyWith(rows: v),
                        ),
                      ),
                      Container(
                        height: 110,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: panel,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          children: [
                            for (var row = 0; row < _settings.rows; row++)
                              Expanded(
                                child: Row(
                                  children: [
                                    for (
                                      var col = 0;
                                      col < _settings.columns;
                                      col++
                                    )
                                      Expanded(
                                        child: Container(
                                          margin: const EdgeInsets.all(2),
                                          decoration: BoxDecoration(
                                            color: accent.withValues(
                                              alpha: .18,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              3,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SectionLabel('Discovery'),
                      _slider(
                        'Posts per batch',
                        'Request 50–200 posts, in steps of 10. Website limits and filtering can return fewer.',
                        _settings.batchSize,
                        50,
                        200,
                        15,
                        (v) => setState(
                          () => _settings = _settings.copyWith(batchSize: v),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Material(
                          color: panel,
                          borderRadius: BorderRadius.circular(16),
                          clipBehavior: Clip.antiAlias,
                          child: SwitchListTile.adaptive(
                            value: _settings.excludeAi,
                            onChanged: _busy
                                ? null
                                : (value) => setState(
                                    () => _settings = _settings.copyWith(
                                      excludeAi: value,
                                    ),
                                  ),
                            secondary: const Icon(Icons.auto_awesome_outlined),
                            title: const Text('No AI-generated posts'),
                            subtitle: const Text(
                              'Automatically exclude posts tagged ai_generated from search and discovery feeds.',
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Material(
                          color: panel,
                          borderRadius: BorderRadius.circular(16),
                          clipBehavior: Clip.antiAlias,
                          child: SwitchListTile.adaptive(
                            value: _settings.gesturesEnabled,
                            onChanged: _busy
                                ? null
                                : (value) => setState(
                                    () => _settings = _settings.copyWith(
                                      gesturesEnabled: value,
                                    ),
                                  ),
                            secondary: const Icon(Icons.swipe_rounded),
                            title: const Text('Gestures'),
                            subtitle: const Text(
                              'Enable edge drawer opening and swipe navigation in the media viewer.',
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                            ),
                          ),
                        ),
                      ),
                      const SectionLabel('Blacklisted tags'),
                      const Text(
                        'Blocked tags are added to every query and filtered from returned posts. Enter a tag, then press space.',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 13,
                          height: 1.6,
                        ),
                      ),
                      const SizedBox(height: 14),
                      TagInput(
                        key: _blacklistKey,
                        enabled: !_busy,
                        tags: _settings.blacklist,
                        hint: 'Add a blocked tag',
                        onDraftChanged: (text) {
                          final hasDraft = text.trim().isNotEmpty;
                          if (hasDraft != _hasDraftTag) {
                            setState(() => _hasDraftTag = hasDraft);
                          }
                        },
                        onChanged: (tags) => setState(
                          () => _settings = _settings.copyWith(blacklist: tags),
                        ),
                      ),
                      const SectionLabel('Downloads'),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: panel,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.folder_outlined, color: accent),
                                SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    'Download folder',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _settings.downloadDirectory == null
                                  ? 'Downloads / BooruPlus\nOn Android 9 or earlier, choose a folder below.'
                                  : Uri.decodeFull(_settings.downloadDirectory!)
                                        .split('/tree/')
                                        .last,
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                                height: 1.6,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: _picking || _busy
                                      ? null
                                      : _pickFolder,
                                  icon: const Icon(Icons.folder_open, size: 17),
                                  label: Text(
                                    _picking ? 'Choosing…' : 'Choose folder',
                                  ),
                                ),
                                if (_settings.downloadDirectory != null)
                                  TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => setState(
                                            () =>
                                                _settings = _settings.copyWith(
                                                  downloadDirectory: null,
                                                ),
                                          ),
                                    child: const Text('Use Downloads'),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SectionLabel('Website connections'),
                      const Text(
                        'Manage credentials stored on this device.',
                        style: TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                      for (final board in Board.values.where(
                        (b) => b.requiresAuth,
                      ))
                        FutureBuilder<Credentials?>(
                          future: widget.state.credentialsFor(board),
                          builder: (context, snapshot) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              snapshot.data == null
                                  ? Icons.key_outlined
                                  : Icons.verified_user_outlined,
                              color: accent,
                            ),
                            title: Text(board.label),
                            subtitle: Text(
                              snapshot.data == null
                                  ? 'Not connected'
                                  : 'Credentials saved securely',
                            ),
                            trailing: Wrap(
                              children: [
                                IconButton(
                                  tooltip: 'Connect ${board.label}',
                                  icon: const Icon(
                                    Icons.edit_outlined,
                                    size: 20,
                                  ),
                                  onPressed: () async {
                                    await showAuthentication(
                                      context,
                                      widget.state,
                                      board,
                                    );
                                    if (mounted) setState(() {});
                                  },
                                ),
                                if (snapshot.data != null)
                                  IconButton(
                                    tooltip:
                                        'Forget ${board.label} credentials',
                                    icon: const Icon(Icons.link_off, size: 20),
                                    onPressed: () async {
                                      try {
                                        await widget.state.forgetCredentials(
                                          board,
                                        );
                                        if (mounted) setState(() {});
                                      } catch (_) {
                                        if (mounted) {
                                          setState(
                                            () => _error = 'Could not remove the saved connection.',
                                          );
                                        }
                                      }
                                    },
                                  ),
                              ],
                            ),
                          ),
                        ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            _error!,
                            style: const TextStyle(color: Colors.orangeAccent),
                          ),
                        ),
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: _busy || _picking ? null : _save,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.all(18),
                        ),
                        child: Text(_busy ? 'Saving…' : 'Save preferences'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
