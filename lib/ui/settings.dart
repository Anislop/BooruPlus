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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
            children: [
              const SectionLabel('Make room for your perspective'),
              const Text(
                'Your browsing,\nyour preferences.',
                style: TextStyle(
                  fontSize: 30,
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
                (v) =>
                    setState(() => _settings = _settings.copyWith(columns: v)),
              ),
              _slider(
                'Rows',
                'Rows per screen. Smaller screens retain a readable minimum tile height.',
                _settings.rows,
                2,
                8,
                6,
                (v) => setState(() => _settings = _settings.copyWith(rows: v)),
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
                            for (var col = 0; col < _settings.columns; col++)
                              Expanded(
                                child: Container(
                                  margin: const EdgeInsets.all(2),
                                  decoration: BoxDecoration(
                                    color: accent.withValues(alpha: .18),
                                    borderRadius: BorderRadius.circular(3),
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
                            style: TextStyle(fontWeight: FontWeight.w600),
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
                          onPressed: _picking || _busy ? null : _pickFolder,
                          icon: const Icon(Icons.folder_open, size: 17),
                          label: Text(_picking ? 'Choosing…' : 'Choose folder'),
                        ),
                        if (_settings.downloadDirectory != null)
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => setState(
                                    () => _settings = _settings.copyWith(
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
              for (final board in Board.values.where((b) => b.requiresAuth))
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
                          icon: const Icon(Icons.edit_outlined, size: 20),
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
                            tooltip: 'Forget ${board.label} credentials',
                            icon: const Icon(Icons.link_off, size: 20),
                            onPressed: () async {
                              try {
                                await widget.state.forgetCredentials(board);
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
      ),
    ),
  );
}
