import 'package:flutter/material.dart';

import 'core/app_state.dart';
import 'core/models.dart';
import 'core/services.dart';
import 'ui/home.dart';
import 'ui/onboarding.dart';
import 'ui/theme.dart';
import 'ui/site_catalog.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(BooruPlusApp(state: AppState()));
}

class BooruPlusApp extends StatefulWidget {
  const BooruPlusApp({super.key, required this.state, this.device});
  final AppState state;
  final DeviceService? device;
  @override
  State<BooruPlusApp> createState() => _BooruPlusAppState();
}

class _BooruPlusAppState extends State<BooruPlusApp>
    with WidgetsBindingObserver {
  /// Time in the background after which the app lock asks again, so a quick
  /// trip to a file picker or the share sheet does not lock the app.
  static const _lockGrace = Duration(seconds: 30);

  late final DeviceService _device = widget.device ?? DeviceService();
  bool _splashComplete = false;
  // Lock state lives here, outside MaterialApp, so a theme change that
  // rebuilds the app does not lock it again.
  bool _settingsSeen = false;
  bool _unlocked = false;
  bool _prompted = false;
  // Covers the content while the app is in the background, so returning
  // within the grace period or the recent-apps preview shows nothing.
  bool _covered = false;
  DateTime? _backgroundSince;
  bool _secureScreen = false;
  ThemeChoice _theme = ThemeChoice.standard;
  // The launcher shortcuts last sent, so unrelated changes do not resend.
  String? _shortcutsKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.state.addListener(_applySettings);
    _initialize();
  }

  @override
  void dispose() {
    widget.state.removeListener(_applySettings);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _initialize() async {
    await Future.wait([widget.state.initialize(), loadSiteCatalog()]);
    if (!mounted) return;
    setState(() {});
  }

  void _applySettings() {
    final state = widget.state;
    if (!state.initialized) return;
    final settings = state.settings;
    if (!_settingsSeen) {
      _settingsSeen = true;
      // Unlocked from the start only when the lock is off at launch;
      // turning it on later does not lock the running session.
      _unlocked = !settings.appLock;
    }
    if (settings.secureScreen != _secureScreen) {
      _secureScreen = settings.secureScreen;
      _device.setSecureScreen(_secureScreen);
    }
    _updateShortcuts();
    if (settings.theme != _theme) {
      _theme = settings.theme;
      setPalette(_theme);
      // Screens read the palette directly rather than through the theme.
      // Rebuild every element instead of re-keying MaterialApp, which would
      // discard the navigation stack and every screen's state.
      void rebuild(Element element) {
        element.markNeedsBuild();
        element.visitChildren(rebuild);
      }

      if (mounted) (context as Element).visitChildren(rebuild);
    }
  }

  /// Launcher shortcuts: favorites, then the current website's first saved
  /// searches.
  void _updateShortcuts() {
    final board = widget.state.board;
    final searches = board == null
        ? const <List<String>>[]
        : widget.state.savedQueries.take(3).toList();
    final key =
        '${board?.name}|${searches.map((q) => q.join(' ')).join('\u0000')}';
    if (key == _shortcutsKey) return;
    _shortcutsKey = key;
    _device.setShortcuts([
      const AppShortcut.favorites(),
      if (board != null)
        for (final (index, query) in searches.indexed)
          AppShortcut.search(
            id: 'search_$index',
            label: query.join(' '),
            board: board,
            tags: query,
          ),
    ]);
  }

  bool get _locked =>
      widget.state.initialized && widget.state.settings.appLock && !_unlocked;

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    // A verification prompt (here or in Settings) sends the app to the
    // background itself.
    if (DeviceService.authenticating) return;
    final appLock = widget.state.settings.appLock;
    if (lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.hidden) {
      _backgroundSince ??= DateTime.now();
      if (appLock && !_covered) setState(() => _covered = true);
    } else if (lifecycle == AppLifecycleState.resumed) {
      final since = _backgroundSince;
      _backgroundSince = null;
      final relock =
          since != null &&
          appLock &&
          DateTime.now().difference(since) >= _lockGrace;
      if (relock || _covered) {
        setState(() {
          _covered = false;
          if (relock) {
            _unlocked = false;
            _prompted = false;
          }
        });
      }
    }
  }

  Future<void> _unlock() async {
    if (DeviceService.authenticating) return;
    try {
      final verified = await _device.authenticate();
      if (verified && mounted) setState(() => _unlocked = true);
    } on DeviceLockUnavailableException {
      // The device's screen lock was removed after the app lock was turned
      // on, so nothing can verify the user any more. Turn the setting off
      // so Settings shows the app as unprotected.
      if (mounted) setState(() => _unlocked = true);
      await widget.state.disableAppLock();
    } catch (_) {
      // Leave the lock screen up; its button retries.
    } finally {
      _backgroundSince = null;
    }
  }

  void _finishSplash() {
    if (mounted) setState(() => _splashComplete = true);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.state,
    builder: (context, _) {
      final settings = widget.state.settings;
      setPalette(settings.theme);
      setSurfaceGlass(
        opacity: settings.surfaceOpacity,
        blur: settings.surfaceBlur,
      );
      final theme = buildAppTheme(board: widget.state.board);
      final locked = _locked && _splashComplete;
      final hidden = locked || (_covered && _splashComplete);
      if (locked && !_prompted) {
        _prompted = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
      }
      return MaterialApp(
        title: 'BooruPlus',
        debugShowCheckedModeBanner: false,
        theme: theme,
        builder: (context, child) => Stack(
          fit: StackFit.expand,
          children: [
            Visibility(
              visible: !hidden,
              maintainState: true,
              child: child ?? const SizedBox.shrink(),
            ),
            if (hidden) _LockScreen(onUnlock: locked ? _unlock : null),
          ],
        ),
        // The first screen grows into place as the splash logo lifts away.
        home: AnimatedSwitcher(
          duration: const Duration(milliseconds: 520),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween(begin: .9, end: 1.0).animate(animation),
              child: child,
            ),
          ),
          child: !_splashComplete || !widget.state.initialized
              ? SplashScreen(onFinished: _finishSplash)
              : widget.state.board == null
              ? OnboardingScreen(state: widget.state)
              : HomeScreen(state: widget.state),
        ),
      );
    },
  );
}

/// The app lock screen; without [onUnlock] it is only a privacy cover.
class _LockScreen extends StatelessWidget {
  const _LockScreen({required this.onUnlock});
  final VoidCallback? onUnlock;

  @override
  Widget build(BuildContext context) => Material(
    color: canvas,
    child: SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const BrandMark(size: 72),
              const SizedBox(height: 24),
              const Icon(Icons.lock_outline_rounded, color: accent, size: 28),
              const SizedBox(height: 12),
              const Text(
                'BooruPlus is locked',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                'Unlock with your fingerprint, face, or screen lock.',
                textAlign: TextAlign.center,
                style: TextStyle(color: ink(.54)),
              ),
              const SizedBox(height: 24),
              if (onUnlock != null)
                FilledButton.icon(
                  onPressed: onUnlock,
                  icon: const Icon(Icons.fingerprint_rounded),
                  label: const Text('Unlock'),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.onFinished});
  final VoidCallback onFinished;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 1300),
          )
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed) widget.onFinished();
          })
          ..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        // Grows in, holds, then expands upward while fading out as the
        // feed grows in behind it.
        final enter = Curves.easeOutBack.transform((t / .35).clamp(0.0, 1.0));
        final exit = Curves.easeInCubic.transform(
          ((t - .6) / .4).clamp(0.0, 1.0),
        );
        final height = MediaQuery.sizeOf(context).height;
        return Opacity(
          opacity: (((t / .25).clamp(0.0, 1.0)) * (1 - exit)).clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, -height * .12 * exit),
            child: Transform.scale(
              scale: .82 + .18 * enter + .4 * exit,
              child: child,
            ),
          ),
        );
      },
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Image(image: AssetImage(logoAsset), fit: BoxFit.contain),
          ),
        ),
      ),
    ),
  );
}
