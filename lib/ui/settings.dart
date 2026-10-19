import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../core/services.dart';
import '../core/updates.dart';
import 'blocked_tags.dart';
import 'onboarding.dart';
import 'saved_posts.dart';
import 'shorts_library.dart';
import 'site_catalog.dart';
import 'tag_input.dart';
import 'theme.dart';
import 'update_dialog.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.state, this.updates});
  final AppState state;
  final UpdateService? updates;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _videoQualities = [0, 1080, 720, 480];
  late AppSettings _settings;
  final _downloads = DownloadService();
  final _device = DeviceService();
  late final _updates = widget.updates ?? UpdateService();
  InstalledVersion? _installed;
  bool _checkingUpdate = false;
  bool _busy = false;
  bool _picking = false;
  bool _backingUp = false;
  bool _verifying = false;
  String? _error;
  late final _filenameTemplate = TextEditingController(
    text: widget.state.settings.filenameTemplate,
  );
  // App cache plus in-memory images, in bytes; null while measuring.
  int? _cacheBytes;
  bool _clearingCache = false;

  bool get _hasUnsavedChanges => _settings != widget.state.settings;

  void _setShortsSite(Board board, bool on) => setState(
    () => _settings = _settings.copyWith(
      shortsOff: on
          ? _settings.shortsOff.where((other) => other != board).toList()
          : [..._settings.shortsOff, board],
    ),
  );

  Future<void> _editBlockedTags() async {
    final result = await Navigator.push<BlockedTags>(
      context,
      MaterialPageRoute(
        builder: (_) => BlockedTagsScreen(
          initial: BlockedTags(
            all: _settings.blacklist,
            byBoard: _settings.boardBlacklists,
          ),
          boards: _settings.boardOrder,
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(
      () => _settings = _settings.copyWith(
        blacklist: result.all,
        boardBlacklists: result.byBoard,
      ),
    );
  }

  String get _blockedSummary {
    final sites = _settings.boardBlacklists.length;
    final all = _settings.blacklist.length;
    if (all == 0 && sites == 0) return 'No blocked tags yet.';
    final everywhere = all == 0 ? null : '$all blocked on all websites';
    final perSite = sites == 0
        ? null
        : 'tags for $sites website${sites == 1 ? '' : 's'}';
    return [?everywhere, ?perSite].join(' · ');
  }

  @override
  void initState() {
    super.initState();
    _settings = widget.state.settings;
    _measureCache();
    _updates.installedVersion().then((version) {
      if (mounted) setState(() => _installed = version);
    });
  }

  Future<void> _checkForUpdate() async {
    setState(() => _checkingUpdate = true);
    try {
      final release = await _updates.check();
      if (!mounted) return;
      if (release == null) {
        _notify('BooruPlus is up to date.');
      } else {
        await showUpdateDialog(
          context,
          updates: _updates,
          release: release,
        );
      }
    } catch (_) {
      _notify('Could not check for updates. Please try again.');
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  @override
  void dispose() {
    _filenameTemplate.dispose();
    super.dispose();
  }

  Future<void> _measureCache() async {
    final disk = await _device.cacheSize();
    if (!mounted) return;
    setState(
      () => _cacheBytes =
          disk +
          MediaService.recentBytes +
          PaintingBinding.instance.imageCache.currentSizeBytes,
    );
  }

  Future<void> _clearCache() async {
    setState(() => _clearingCache = true);
    try {
      await _device.clearCache();
      MediaService.clearRecent();
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      _notify('Cache cleared.');
    } catch (_) {
      _notify('Could not clear the cache. Please try again.');
    } finally {
      if (mounted) setState(() => _clearingCache = false);
    }
    await _measureCache();
  }

  String get _uploadersSummary {
    final total = _settings.boardHiddenUploaders.values.fold(
      0,
      (sum, names) => sum + names.length,
    );
    if (total == 0) {
      return "Hide an uploader from a post's details or its hold menu.";
    }
    final sites = _settings.boardHiddenUploaders.length;
    return '$total hidden on $sites website${sites == 1 ? '' : 's'}';
  }

  /// Lists hidden uploaders by website; removing one edits the draft.
  Future<void> _editHiddenUploaders() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final byBoard = _settings.boardHiddenUploaders;
          void remove(Board board, String name) {
            final names = [...?byBoard[board]]..remove(name);
            setState(
              () => _settings = _settings.copyWith(
                boardHiddenUploaders: {
                  for (final entry in byBoard.entries)
                    if (entry.key != board) entry.key: entry.value,
                  if (names.isNotEmpty) board: names,
                },
              ),
            );
            setSheetState(() {});
          }

          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .7,
              ),
              child: ListView(
                shrinkWrap: true,
                children: [
                  const ListTile(
                    leading: Icon(Icons.person_off_outlined),
                    title: Text('Hidden uploaders'),
                    subtitle: Text('Changes apply when you save settings.'),
                  ),
                  if (byBoard.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                      child: Text(
                        'No hidden uploaders.',
                        style: TextStyle(color: ink(.54)),
                      ),
                    ),
                  for (final board in _settings.boardOrder)
                    if (byBoard[board] case final names?) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text(
                          board.label,
                          style: const TextStyle(
                            color: accent,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      for (final name in names)
                        ListTile(
                          dense: true,
                          title: Text(name),
                          trailing: IconButton(
                            tooltip: 'Show posts by $name again',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => remove(board, name),
                          ),
                        ),
                    ],
                ],
              ),
            ),
          );
        },
      ),
    );
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
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.state.updateSettings(_settings);
      // Stay on this screen: popping here raced a back gesture made while
      // saving, which popped twice and left a black screen.
      if (!mounted) return;
      setState(() => _settings = widget.state.settings);
      if (_filenameTemplate.text != _settings.filenameTemplate) {
        _filenameTemplate.text = _settings.filenameTemplate;
      }
      _notify('Settings saved.');
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not save settings. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Turning the app lock on first checks that this device can verify the
  /// user, so it cannot lock anyone out.
  Future<void> _setAppLock(bool enabled) async {
    if (!enabled) {
      setState(() => _settings = _settings.copyWith(appLock: false));
      return;
    }
    setState(() => _verifying = true);
    try {
      final verified = await _device.authenticate(title: 'Turn on app lock');
      if (verified && mounted) {
        setState(() => _settings = _settings.copyWith(appLock: true));
      }
    } on DeviceLockUnavailableException {
      _notify('Set up a screen lock in Android settings to use the app lock.');
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  Future<void> _exportBackup() async {
    setState(() => _backingUp = true);
    try {
      final now = DateTime.now();
      String two(int value) => value.toString().padLeft(2, '0');
      final saved = await _device.exportFile(
        name:
            'booruplus-backup-${now.year}-${two(now.month)}-${two(now.day)}.json',
        content: widget.state.exportBackup(),
      );
      if (saved) _notify('Backup saved.');
    } catch (_) {
      _notify('Could not save the backup. Please try again.');
    } finally {
      if (mounted) setState(() => _backingUp = false);
    }
  }

  /// Exempt websites the app still offers; retired ones stay saved but
  /// are not shown.
  List<Board> get _listedAiExemptions =>
      _settings.aiExemptBoards.where((board) => !board.isRetired).toList();

  /// Picks the websites where the no-AI setting does not apply.
  Future<void> _chooseAiExemptions() async {
    final chosen = {..._settings.aiExemptBoards};
    final result = await showDialog<Set<Board>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Show AI posts on'),
          contentPadding: const EdgeInsets.only(top: 12),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final board in _settings.boardOrder)
                  CheckboxListTile(
                    value: chosen.contains(board),
                    secondary: SiteLogo(board, size: 28),
                    title: Text(appearanceFor(board).name),
                    subtitle: board.isAiBoard
                        ? const Text('Only hosts AI-generated posts')
                        : null,
                    onChanged: (value) => setDialogState(() {
                      if (value == true) {
                        chosen.add(board);
                      } else {
                        chosen.remove(board);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, chosen),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(
      () => _settings = _settings.copyWith(aiExemptBoards: result.toList()),
    );
  }

  Future<void> _importBackup() async {
    setState(() => _backingUp = true);
    try {
      final content = await _device.importFile();
      if (content == null || !mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Restore this backup?'),
          content: const Text(
            'Its settings, saved searches, and blocked tags replace the current ones. Its favorites and hidden posts are added to yours. Your download folder, app lock, and website connections stay as they are.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Restore'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      final summary = await widget.state.importBackup(content);
      if (!mounted) return;
      setState(() => _settings = widget.state.settings);
      _notify(
        'Backup restored: ${summary.favorites} new favorite${summary.favorites == 1 ? '' : 's'}, ${summary.hidden} new hidden post${summary.hidden == 1 ? '' : 's'}.',
      );
    } on FormatException catch (error) {
      _notify(error.message);
    } catch (_) {
      _notify('Could not restore the backup. Please try again.');
    } finally {
      if (mounted) setState(() => _backingUp = false);
    }
  }

  Widget _switchCard({
    required bool value,
    required ValueChanged<bool>? onChanged,
    required IconData icon,
    required String title,
    required String subtitle,
  }) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Material(
      color: panel,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: SwitchListTile.adaptive(
        value: value,
        onChanged: _busy ? null : onChanged,
        secondary: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      ),
    ),
  );

  /// A setting with a few choices, as a button group.
  Widget _choiceCard<T>({
    required IconData icon,
    required String title,
    required String subtitle,
    required List<T> values,
    required String Function(T) label,
    required T selected,
    required ValueChanged<T> onChanged,
  }) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<T>(
              showSelectedIcon: false,
              segments: [
                for (final value in values)
                  ButtonSegment<T>(value: value, label: Text(label(value))),
              ],
              selected: {selected},
              onSelectionChanged: _busy
                  ? null
                  : (choice) => onChanged(choice.single),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(color: ink(.54), fontSize: 12, height: 1.5),
          ),
        ],
      ),
    ),
  );

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
        style: TextStyle(color: ink(.54), fontSize: 12, height: 1.5),
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

  Widget _blurSwitch(String title, String subtitle, bool explicit) {
    final value = explicit
        ? _settings.blurExplicit
        : _settings.blurQuestionable;
    return SwitchListTile.adaptive(
      value: value,
      onChanged: _busy
          ? null
          : (next) => setState(() {
              _settings = _settings.copyWith(
                blurExplicit: explicit ? next : _settings.blurExplicit,
                blurQuestionable: explicit ? _settings.blurQuestionable : next,
              );
            }),
      secondary: const Icon(Icons.blur_on_outlined),
      title: Text(title),
      subtitle: Text(subtitle),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasUnsaved = _hasUnsavedChanges;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        // A thin progress bar while settings are being saved.
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: _busy
              ? const LinearProgressIndicator(
                  key: ValueKey('settings_saving_bar'),
                  minHeight: 2,
                )
              : const SizedBox(height: 2),
        ),
      ),
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
                        'Check your settings and preferences!',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                          letterSpacing: -.7,
                        ),
                      ),
                      const SectionLabel('Appearance'),
                      _choiceCard<ThemeChoice>(
                        icon: Icons.palette_outlined,
                        title: 'Theme',
                        subtitle: switch (_settings.theme) {
                          ThemeChoice.standard =>
                            'Dark mode.',
                          ThemeChoice.white => 'Light mode.',
                          ThemeChoice.amoled => 'Super Dark mode!',
                        },
                        values: ThemeChoice.values,
                        label: (choice) => choice.label,
                        selected: _settings.theme,
                        onChanged: (choice) => setState(
                          () => _settings = _settings.copyWith(theme: choice),
                        ),
                      ),
                      const SectionLabel('Media grid'),
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Material(
                          color: panel,
                          borderRadius: BorderRadius.circular(16),
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            children: [
                              _blurSwitch(
                                'Blur explicit media',
                                'Obscure explicit previews, viewer media, and booruShorts videos until revealed.',
                                true,
                              ),
                              _blurSwitch(
                                'Blur questionable media',
                                'Obscure questionable previews, viewer media, and booruShorts videos until revealed.',
                                false,
                              ),
                              ListTile(
                                leading: const Icon(
                                  Icons.visibility_off_outlined,
                                ),
                                title: const Text('Hidden posts'),
                                subtitle: const Text(
                                  'Review and unhide locally saved posts.',
                                ),
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) => SavedPostsScreen(
                                      state: widget.state,
                                      hidden: true,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
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
                        'Rows per screen. Small screens have a minimum tile height.',
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
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Material(
                          color: panel,
                          borderRadius: BorderRadius.circular(16),
                          clipBehavior: Clip.antiAlias,
                          child: SwitchListTile.adaptive(
                            value: _settings.hierarchicalGrid,
                            onChanged: _busy
                                ? null
                                : (value) => setState(
                                    () => _settings = _settings.copyWith(
                                      hierarchicalGrid: value,
                                    ),
                                  ),
                            secondary: const Icon(Icons.view_quilt_outlined),
                            title: const Text('Hierarchical grid'),
                            subtitle: const Text(
                              'Use a proportional gallery layout on home and search results.',
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
                            value: _settings.hidePostTags,
                            onChanged: _busy
                                ? null
                                : (value) => setState(
                                    () => _settings = _settings.copyWith(
                                      hidePostTags: value,
                                    ),
                                  ),
                            secondary: const Icon(Icons.label_off_outlined),
                            title: const Text('Hide post tags'),
                            subtitle: const Text(
                              'Hide post tags on home and search results for a cleaner gallery.',
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                            ),
                          ),
                        ),
                      ),
                      const SectionLabel('Discovery'),
                      _slider(
                        'Posts per batch',
                        'Request 50–200 posts, in steps of 10. Rate limits and website limits may apply.',
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
                              'No AI-slop content. Unless you want them, you can turn it on. (applies to all websites)',
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                            ),
                          ),
                        ),
                      ),
                      if (_settings.excludeAi)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Material(
                            color: panel,
                            borderRadius: BorderRadius.circular(16),
                            clipBehavior: Clip.antiAlias,
                            child: ListTile(
                              key: const ValueKey('ai_exempt_boards'),
                              enabled: !_busy,
                              leading: const Icon(Icons.rule_rounded),
                              title: const Text('Websites that show AI posts'),
                              subtitle: Text(
                                _listedAiExemptions.isEmpty
                                    ? 'No websites yet.'
                                    : _listedAiExemptions
                                          .map(
                                            (board) =>
                                                appearanceFor(board).name,
                                          )
                                          .join(', '),
                              ),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: _chooseAiExemptions,
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
                      _switchCard(
                        value: _settings.classicDrawer,
                        onChanged: (value) => setState(
                          () => _settings = _settings.copyWith(
                            classicDrawer: value,
                          ),
                        ),
                        icon: Icons.view_sidebar_outlined,
                        title: 'Classic side menu',
                        subtitle: 'Use the original side menu layout with every entry listed above the websites.',
                      ),
                      _switchCard(
                        value: _settings.oneHanded,
                        onChanged: (value) => setState(
                          () =>
                              _settings = _settings.copyWith(oneHanded: value),
                        ),
                        icon: Icons.back_hand_outlined,
                        title: 'One-handed mode',
                        subtitle: 'Ease of use, and better way to do what you need to do.',
                      ),
                      if (_settings.oneHanded)
                        _choiceCard<Handedness>(
                          icon: Icons.pan_tool_alt_outlined,
                          title: 'Preferred hand',
                          subtitle: 'The jump-to-top button and the most-used actions sit on this side.',
                          // Left first, matching the sides they stand for.
                          values: const [Handedness.left, Handedness.right],
                          label: (hand) => hand.label,
                          selected: _settings.handedness,
                          onChanged: (hand) => setState(
                            () => _settings = _settings.copyWith(
                              handedness: hand,
                            ),
                          ),
                        ),
                      if (_settings.oneHanded)
                        _switchCard(
                          value: _settings.hidePanelOnScroll,
                          onChanged: (value) => setState(
                            () => _settings = _settings.copyWith(
                              hidePanelOnScroll: value,
                            ),
                          ),
                          icon: Icons.unfold_less_rounded,
                          title: 'Hide panel while scrolling',
                          subtitle: 'Slide the bottom panel away while scrolling down and bring it back when scrolling up.',
                        ),
                      // Each frosted surface has its own opacity; the blur
                      // is shared.
                      if (_settings.oneHanded)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: _slider(
                            'One-handed panel opacity',
                            'How solid the bottom panel is over the feed.',
                            _settings.panelOpacity,
                            20,
                            100,
                            16,
                            (v) => setState(
                              () => _settings = _settings.copyWith(
                                panelOpacity: v,
                              ),
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: _slider(
                          'Post details opacity',
                          'How solid the viewer\'s tags and details are over the image.',
                          _settings.detailsOpacity,
                          20,
                          100,
                          16,
                          (v) => setState(
                            () => _settings = _settings.copyWith(
                              detailsOpacity: v,
                            ),
                          ),
                        ),
                      ),
                      _slider(
                        'Side menu opacity',
                        'How solid the side menu\'s website list is over the feed.',
                        _settings.surfaceOpacity,
                        20,
                        100,
                        16,
                        (v) => setState(
                          () =>
                              _settings = _settings.copyWith(surfaceOpacity: v),
                        ),
                      ),
                      _slider(
                        'Surface blur',
                        _settings.reduceMotion
                            ? 'Off while Reduce motion is on.'
                            : 'How much the content behind those surfaces is blurred.',
                        _settings.surfaceBlur,
                        0,
                        30,
                        30,
                        (v) => setState(
                          () => _settings = _settings.copyWith(surfaceBlur: v),
                        ),
                      ),
                      _switchCard(
                        value: _settings.reduceMotion,
                        onChanged: (value) => setState(
                          () => _settings = _settings.copyWith(
                            reduceMotion: value,
                          ),
                        ),
                        icon: Icons.motion_photos_off_outlined,
                        title: 'Reduce motion',
                        subtitle: 'Reduce motion and remove animations. Good for slower phones.',
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Material(
                          color: panel,
                          borderRadius: BorderRadius.circular(16),
                          clipBehavior: Clip.antiAlias,
                          child: ListTile(
                            leading: const Icon(Icons.high_quality_outlined),
                            title: const Text('Video quality'),
                            subtitle: const Text(
                              'Stream a lower resolution when the website offers one (e621 and e926). Some websites don\'t have this feature.',
                            ),
                            trailing: DropdownButton<int>(
                              value:
                                  _videoQualities.contains(
                                    _settings.videoQuality,
                                  )
                                  ? _settings.videoQuality
                                  : 0,
                              underline: const SizedBox.shrink(),
                              onChanged: _busy
                                  ? null
                                  : (value) => setState(
                                      () => _settings = _settings.copyWith(
                                        videoQuality: value ?? 0,
                                      ),
                                    ),
                              items: [
                                for (final quality in _videoQualities)
                                  DropdownMenuItem(
                                    value: quality,
                                    child: Text(
                                      quality == 0 ? 'Original' : '${quality}p',
                                    ),
                                  ),
                              ],
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
                            value: _settings.globalSavedQueries,
                            onChanged: _busy
                                ? null
                                : (value) => setState(
                                    () => _settings = _settings.copyWith(
                                      globalSavedQueries: value,
                                    ),
                                  ),
                            secondary: const Icon(Icons.bookmarks_outlined),
                            title: const Text('Share saved searches'),
                            subtitle: const Text(
                              'Show the same saved searches on every website. When off, each website keeps its own.',
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                            ),
                          ),
                        ),
                      ),
                      const SectionLabel('Viewer'),
                      _choiceCard<DataSaverMode>(
                        icon: Icons.data_saver_on_outlined,
                        title: 'Data saver',
                        subtitle: "Show the website's smaller sample image when it has one. Tap \"Load Original\" for full size.",
                        values: DataSaverMode.values,
                        label: (mode) => switch (mode) {
                          DataSaverMode.off => 'Off',
                          DataSaverMode.mobileData => 'Mobile Data',
                          DataSaverMode.always => 'Always',
                        },
                        selected: _settings.dataSaver,
                        onChanged: (mode) => setState(
                          () => _settings = _settings.copyWith(dataSaver: mode),
                        ),
                      ),
                      const SizedBox(height: 16),
                      _slider(
                        'Slideshow interval',
                        'Seconds each image shows during a slideshow. Videos will play until the end though.',
                        _settings.slideshowSeconds,
                        2,
                        60,
                        58,
                        (v) => setState(
                          () => _settings = _settings.copyWith(
                            slideshowSeconds: v,
                          ),
                        ),
                      ),
                      _switchCard(
                        value: _settings.doubleTapFavorite,
                        onChanged: (value) => setState(
                          () => _settings = _settings.copyWith(
                            doubleTapFavorite: value,
                          ),
                        ),
                        icon: Icons.favorite_border_rounded,
                        title: 'Double-tap to favorite',
                        subtitle: 'Double-tapping an image favorites it instead of zooming. Pinch to zoom.',
                      ),
                      _switchCard(
                        value: _settings.volumeKeyPaging,
                        onChanged: (value) => setState(
                          () => _settings = _settings.copyWith(
                            volumeKeyPaging: value,
                          ),
                        ),
                        icon: Icons.volume_up_outlined,
                        title: 'Volume keys turn pages',
                        subtitle: 'True one-hand experience. Volume down = next post, Volume down = previous post.',
                      ),
                      const SectionLabel('booruShorts'),
                      Material(
                        key: const ValueKey('settings_shorts_tags'),
                        color: panel,
                        borderRadius: BorderRadius.circular(16),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Tags'),
                              const SizedBox(height: 2),
                              Text(
                                'Show videos with any of these tags. Leave it empty for every video.',
                                style: TextStyle(color: ink(.54), fontSize: 13),
                              ),
                              const SizedBox(height: 10),
                              TagInput(
                                tags: _settings.shortsTags,
                                onChanged: (tags) => setState(
                                  () => _settings = _settings.copyWith(
                                    shortsTags: tags,
                                  ),
                                ),
                                autocomplete: widget.state.autocomplete,
                                searchStyle: false,
                                enabled: !_busy,
                                hint: 'Add a tag, then press space',
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Material(
                        key: const ValueKey('settings_shorts_sites'),
                        color: panel,
                        borderRadius: BorderRadius.circular(16),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Websites'),
                              const SizedBox(height: 2),
                              Text(
                                'Websites that feed booruShorts. Websites that need an API key join once you connect them.',
                                style: TextStyle(color: ink(.54), fontSize: 13),
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  for (final board in _settings.boardOrder)
                                    if (board.hasShorts)
                                      FilterChip(
                                        avatar: SiteLogo(board, size: 18),
                                        label: Text(board.label),
                                        selected: !_settings.shortsOff.contains(
                                          board,
                                        ),
                                        onSelected: _busy
                                            ? null
                                            : (on) => _setShortsSite(board, on),
                                      ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      _choiceCard<ShortsContent>(
                        icon: Icons.shield_outlined,
                        title: 'Content',
                        subtitle: switch (_settings.shortsContent) {
                          ShortsContent.all => 'booruShorts shows every rating your feed filter allows.',
                          ShortsContent.noExplicit => 'Leaves explicit videos out of booruShorts, and websites without ratings.',
                          ShortsContent.safeOnly => 'Leaves explicit and suggestive (questionable) videos out of booruShorts, and websites without ratings.',
                        },
                        values: ShortsContent.values,
                        label: (value) => value.label,
                        selected: _settings.shortsContent,
                        onChanged: (value) => setState(
                          () => _settings = _settings.copyWith(
                            shortsContent: value,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      _switchCard(
                        value: _settings.shortsMuted,
                        onChanged: (value) => setState(
                          () => _settings = _settings.copyWith(
                            shortsMuted: value,
                          ),
                        ),
                        icon: Icons.volume_off_outlined,
                        title: 'Start muted',
                        subtitle: 'Play booruShorts without sound. The mute button in booruShorts changes this too.',
                      ),
                      _switchCard(
                        value: _settings.shortsAutoAdvance,
                        onChanged: (value) => setState(
                          () => _settings = _settings.copyWith(
                            shortsAutoAdvance: value,
                          ),
                        ),
                        icon: Icons.skip_next_outlined,
                        title: 'Auto-advance',
                        subtitle: 'Move to the next video when one ends instead of replaying it.',
                      ),
                      const SizedBox(height: 8),
                      Material(
                        key: const ValueKey('settings_shorts_following'),
                        color: panel,
                        borderRadius: BorderRadius.circular(16),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Following'),
                              const SizedBox(height: 2),
                              Text(
                                'The Following tab shows the newest videos with any of these tags. Hold a tag in booruShorts to follow it.',
                                style: TextStyle(color: ink(.54), fontSize: 13),
                              ),
                              const SizedBox(height: 10),
                              TagInput(
                                tags: _settings.shortsFollowing,
                                onChanged: (tags) => setState(
                                  () => _settings = _settings.copyWith(
                                    shortsFollowing: tags,
                                  ),
                                ),
                                autocomplete: widget.state.autocomplete,
                                searchStyle: false,
                                enabled: !_busy,
                                hint: 'Add a tag, then press space',
                              ),
                            ],
                          ),
                        ),
                      ),
                      _switchCard(
                        value: _settings.shortsPersonalized,
                        onChanged: (value) => setState(
                          () => _settings = _settings.copyWith(
                            shortsPersonalized: value,
                          ),
                        ),
                        icon: Icons.auto_awesome_outlined,
                        title: 'Personalize For You',
                        subtitle: 'Learn from likes, dislikes, and how long you watch, on this device only. Turning this off just shows random videos.',
                      ),
                      if (_settings.shortsPersonalized)
                        _choiceCard<ShortsExploration>(
                          icon: Icons.explore_outlined,
                          title: 'Discovery',
                          subtitle: 'How often For You shows something outside your interests.',
                          values: ShortsExploration.values,
                          label: (value) => switch (value) {
                            ShortsExploration.low => 'Less',
                            ShortsExploration.normal => 'Normal',
                            ShortsExploration.high => 'More',
                          },
                          selected: _settings.shortsExploration,
                          onChanged: (value) => setState(
                            () => _settings = _settings.copyWith(
                              shortsExploration: value,
                            ),
                          ),
                        ),
                      _choiceCard<int>(
                        icon: Icons.slow_motion_video_outlined,
                        title: 'Auto-scroll length',
                        subtitle: 'During auto-scroll (booruShorts › ⋮), how long each video plays before the next one.',
                        values: AppSettings.shortsAutoScrollChoices,
                        label: (value) => value == 0 ? 'Full' : '${value}s',
                        selected: _settings.shortsAutoScrollSeconds,
                        onChanged: (value) => setState(
                          () => _settings = _settings.copyWith(
                            shortsAutoScrollSeconds: value,
                          ),
                        ),
                      ),
                      _switchCard(
                        value: _settings.shortsPictureInPicture,
                        onChanged: (value) => setState(
                          () => _settings = _settings.copyWith(
                            shortsPictureInPicture: value,
                          ),
                        ),
                        icon: Icons.picture_in_picture_alt_outlined,
                        title: 'Picture-in-picture',
                        subtitle: 'Keep the video playing in a small window when you leave the app. Off while the app lock or Hide in recent apps is on.',
                      ),
                      const SizedBox(height: 8),
                      Material(
                        color: panel,
                        borderRadius: BorderRadius.circular(16),
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          children: [
                            ListTile(
                              key: const ValueKey('settings_shorts_interests'),
                              leading: const Icon(Icons.insights_outlined),
                              title: const Text('Your interests'),
                              subtitle: const Text(
                                'What booruShorts learned, muted tags, and reset',
                              ),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              enabled: !_busy,
                              onTap: () =>
                                  openShortsInterests(context, widget.state),
                            ),
                            ListTile(
                              key: const ValueKey('settings_shorts_history'),
                              leading: const Icon(Icons.history_rounded),
                              title: const Text('Watch history'),
                              subtitle: const Text(
                                'Videos you watched in booruShorts',
                              ),
                              trailing: const Icon(Icons.chevron_right_rounded),
                              enabled: !_busy,
                              onTap: () =>
                                  openShortsHistory(context, widget.state),
                            ),
                          ],
                        ),
                      ),
                      const SectionLabel('Blocked tags'),
                      Material(
                        color: panel,
                        borderRadius: BorderRadius.circular(16),
                        clipBehavior: Clip.antiAlias,
                        child: ListTile(
                          leading: const Icon(Icons.block_rounded),
                          title: const Text('Blocked tags'),
                          subtitle: Text(_blockedSummary),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          enabled: !_busy,
                          onTap: _editBlockedTags,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Material(
                        color: panel,
                        borderRadius: BorderRadius.circular(16),
                        clipBehavior: Clip.antiAlias,
                        child: ListTile(
                          leading: const Icon(Icons.person_off_outlined),
                          title: const Text('Hidden uploaders'),
                          subtitle: Text(_uploadersSummary),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          enabled: !_busy,
                          onTap: _editHiddenUploaders,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                          ),
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
                              style: TextStyle(
                                color: ink(.54),
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
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: panel,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TextField(
                              controller: _filenameTemplate,
                              enabled: !_busy,
                              autocorrect: false,
                              enableSuggestions: false,
                              maxLength: 120,
                              decoration: InputDecoration(
                                labelText: 'File name',
                                hintText: defaultFilenameTemplate,
                                suffixIcon: IconButton(
                                  tooltip: 'Reset file name',
                                  icon: const Icon(Icons.restart_alt_rounded),
                                  onPressed: _busy
                                      ? null
                                      : () {
                                          _filenameTemplate.text =
                                              defaultFilenameTemplate;
                                          setState(
                                            () =>
                                                _settings = _settings.copyWith(
                                                  filenameTemplate:
                                                      defaultFilenameTemplate,
                                                ),
                                          );
                                        },
                                ),
                              ),
                              onChanged: (value) => setState(
                                () => _settings = _settings.copyWith(
                                  filenameTemplate: value,
                                ),
                              ),
                            ),
                            Text(
                              'Use {site} {id} {md5} {artist} {character} {copyright} {rating} {width} {height}. The extension is added for you.',
                              style: TextStyle(
                                color: ink(.54),
                                fontSize: 12,
                                height: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      _switchCard(
                        value: _settings.autoFavoriteOnDownload,
                        onChanged: (value) => setState(
                          () => _settings = _settings.copyWith(
                            autoFavoriteOnDownload: value,
                          ),
                        ),
                        icon: Icons.favorite_outline_rounded,
                        title: 'Favorite when downloading',
                        subtitle:
                            'Add downloaded posts to your favorites as well.',
                      ),
                      const SectionLabel('Storage'),
                      Material(
                        color: panel,
                        borderRadius: BorderRadius.circular(16),
                        clipBehavior: Clip.antiAlias,
                        child: ListTile(
                          leading: const Icon(Icons.cleaning_services_outlined),
                          title: const Text('Cache'),
                          subtitle: Text(
                            _cacheBytes == null
                                ? 'Measuring…'
                                : '${formatBytes(_cacheBytes!)} of previews and media. Downloads and favorites are not affected.',
                          ),
                          trailing: TextButton(
                            onPressed: _clearingCache || _busy
                                ? null
                                : _clearCache,
                            child: Text(_clearingCache ? 'Clearing…' : 'Clear'),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                          ),
                        ),
                      ),
                      const SectionLabel('Privacy'),
                      _switchCard(
                        value: _settings.appLock,
                        onChanged: _verifying ? null : _setAppLock,
                        icon: Icons.lock_outline_rounded,
                        title: 'App lock',
                        subtitle: 'Ask for your fingerprint, face, or screen lock when opening BooruPlus or returning after 30 seconds away.',
                      ),
                      _switchCard(
                        value: _settings.secureScreen,
                        onChanged: (value) => setState(
                          () => _settings = _settings.copyWith(
                            secureScreen: value,
                          ),
                        ),
                        icon: Icons.screenshot_monitor_outlined,
                        title: 'Hide in recent apps',
                        subtitle: 'Blank the app preview in the recent-apps screen and block screenshots.',
                      ),
                      _switchCard(
                        value: _settings.incognito,
                        onChanged: (value) => setState(
                          () =>
                              _settings = _settings.copyWith(incognito: value),
                        ),
                        icon: Icons.visibility_off_outlined,
                        title: 'Incognito',
                        subtitle: "Don't record recent searches or searched and browsed tags. Also in the menu.",
                      ),
                      _switchCard(
                        value: _settings.noShare,
                        onChanged: (value) => setState(
                          () => _settings = _settings.copyWith(noShare: value),
                        ),
                        icon: Icons.share_outlined,
                        title: 'No share',
                        subtitle: 'Hide all share buttons to not accidentally share something to your boss.',
                      ),
                      const SectionLabel('Backup'),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: panel,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Save your settings, saved searches, blocked tags, favorites, and hidden posts to a file, or restore them from one. Website credentials are never included.',
                              style: TextStyle(
                                color: ink(.54),
                                fontSize: 12,
                                height: 1.6,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: _backingUp || _busy
                                      ? null
                                      : _exportBackup,
                                  icon: const Icon(
                                    Icons.upload_file_outlined,
                                    size: 17,
                                  ),
                                  label: const Text('Export backup'),
                                ),
                                OutlinedButton.icon(
                                  onPressed: _backingUp || _busy
                                      ? null
                                      : _importBackup,
                                  icon: const Icon(
                                    Icons.restore_rounded,
                                    size: 17,
                                  ),
                                  label: const Text('Restore backup'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SectionLabel('Updates'),
                      Material(
                        color: panel,
                        borderRadius: BorderRadius.circular(16),
                        clipBehavior: Clip.antiAlias,
                        child: ListTile(
                          leading: const Icon(Icons.info_outline_rounded),
                          title: Text(
                            _installed == null
                                ? 'BooruPlus'
                                : 'BooruPlus ${_installed!.label}',
                          ),
                          subtitle: const Text(
                            'Updates are the uncensored edition from GitHub releases.',
                          ),
                          trailing: TextButton(
                            onPressed: _checkingUpdate || _busy
                                ? null
                                : _checkForUpdate,
                            child: Text(
                              _checkingUpdate ? 'Checking…' : 'Check now',
                            ),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                          ),
                        ),
                      ),
                      _switchCard(
                        value: _settings.checkUpdates,
                        onChanged: (value) => setState(
                          () => _settings = _settings.copyWith(
                            checkUpdates: value,
                          ),
                        ),
                        icon: Icons.system_update_outlined,
                        title: 'Check for updates at launch',
                        subtitle: 'Look for a newer release when BooruPlus starts and offer to install it.',
                      ),
                      const SectionLabel('Website connections'),
                      Text(
                        'Manage credentials stored on this device.',
                        style: TextStyle(color: ink(.54), fontSize: 13),
                      ),
                      for (final board in Board.values.where(
                        (b) => b.supportsAuth,
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
                              board.supportsSignIn
                                  ? snapshot.data == null
                                        ? 'Not signed in (optional)'
                                        : 'Signed in as ${snapshot.data!.userId}'
                                  : snapshot.data == null
                                  ? 'Not connected'
                                  : 'Credentials saved securely',
                            ),
                            trailing: Wrap(
                              children: [
                                IconButton(
                                  tooltip: board.supportsSignIn
                                      ? 'Sign in to ${board.label}'
                                      : 'Connect ${board.label}',
                                  icon: Icon(
                                    board.supportsSignIn
                                        ? Icons.login
                                        : Icons.edit_outlined,
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
                                    tooltip: board.supportsSignIn
                                        ? 'Sign out of ${board.label}'
                                        : 'Forget ${board.label} credentials',
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
