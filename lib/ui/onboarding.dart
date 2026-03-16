import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import 'theme.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.state});
  final AppState state;
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  Board _selected = Board.safebooru;
  bool _busy = false;
  String? _error;
  Future<void> _continue() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_selected.requiresAuth &&
          await widget.state.credentialsFor(_selected) == null) {
        if (!mounted) return;
        final ok = await showAuthentication(context, widget.state, _selected);
        if (!ok) return;
      }
      await widget.state.chooseBoard(_selected);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not open this website. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Row(
                children: [
                  BrandMark(),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'BooruPlus',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 38),
              const Text(
                'A world of images.\nYour way to explore.',
                style: TextStyle(
                  fontSize: 36,
                  height: 1.13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1.1,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Choose your imageboard to get started.\nYou can switch websites anytime.',
                style: TextStyle(
                  fontSize: 15,
                  height: 1.6,
                  color: Colors.white60,
                ),
              ),
              const SectionLabel('Choose a website'),
              for (final board in Board.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: _selected == board ? const Color(0xFF26372E) : panel,
                    borderRadius: BorderRadius.circular(18),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: _busy
                          ? null
                          : () => setState(() => _selected = board),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 15,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 42,
                              height: 42,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: .06),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                board.label.substring(0, 1).toUpperCase(),
                                style: const TextStyle(
                                  fontSize: 23,
                                  fontWeight: FontWeight.w700,
                                  color: accent,
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    board.label,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    board.requiresAuth
                                        ? 'API key required'
                                        : board.host,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.white54,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (board.requiresAuth)
                              const Padding(
                                padding: EdgeInsets.only(right: 12),
                                child: Icon(
                                  Icons.key_rounded,
                                  size: 18,
                                  color: Colors.white38,
                                ),
                              ),
                            Icon(
                              _selected == board
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_off,
                              color: _selected == board
                                  ? accent
                                  : Colors.white30,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              const Text(
                'Content and availability depend on the selected website. Follow its terms and age requirements.',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
              if (_error != null || widget.state.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.orangeAccent),
                  ),
                ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _busy ? null : _continue,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.all(18),
                ),
                label: Text(
                  _busy ? 'Opening website…' : 'Explore ${_selected.label}',
                ),
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_forward),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<bool> showAuthentication(
  BuildContext context,
  AppState state,
  Board board,
) async =>
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => AuthenticationSheet(state: state, board: board),
    ) ??
    false;

class AuthenticationSheet extends StatefulWidget {
  const AuthenticationSheet({
    super.key,
    required this.state,
    required this.board,
  });
  final AppState state;
  final Board board;
  @override
  State<AuthenticationSheet> createState() => _AuthenticationSheetState();
}

class _AuthenticationSheetState extends State<AuthenticationSheet> {
  final _user = TextEditingController();
  final _key = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;
  @override
  void dispose() {
    _user.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_user.text.trim().isEmpty || _key.text.trim().isEmpty) {
      setState(() => _error = 'Enter both your user ID and API key.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.state.authenticate(
        widget.board,
        Credentials(userId: _user.text.trim(), apiKey: _key.text.trim()),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not verify these credentials. Check your API key, user ID, and connection.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        24,
        24,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Connect to ${widget.board.label}',
              style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            const Text(
              'Use the API credentials from your website account. They are encrypted on this device so you only need to connect once.',
              style: TextStyle(color: Colors.white60, height: 1.5),
            ),
            TextButton.icon(
              onPressed: () async {
                final uri = Uri.tryParse(widget.board.authUrl);
                if (uri != null) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Open account / API key settings'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _user,
              enabled: !_busy,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'User ID'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _key,
              enabled: !_busy,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'API key',
                suffixIcon: IconButton(
                  tooltip: 'Show or hide API key',
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text(
                  _error ?? widget.state.error!,
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : _save,
                child: Text(_busy ? 'Verifying…' : 'Verify & save connection'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
