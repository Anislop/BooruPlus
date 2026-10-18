import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'core/app_state.dart';
import 'core/models.dart';
import 'core/services.dart';
import 'core/updates.dart';
import 'ui/home.dart';
import 'ui/onboarding.dart';
import 'ui/theme.dart';
import 'ui/site_catalog.dart';
import 'ui/update_dialog.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(BooruPlusApp(state: AppState()));
}

class BooruPlusApp extends StatefulWidget {
  const BooruPlusApp({
    super.key,
    required this.state,
    this.device,
    this.updates,
  });
  final AppState state;
  final DeviceService? device;

  /// Checks for a newer release at launch. Without one, release builds use
  /// [UpdateService] and other builds do not check.
  final UpdateService? updates;
  @override
  State<BooruPlusApp> createState() => _BooruPlusAppState();
}

class _BooruPlusAppState extends State<BooruPlusApp>
    with WidgetsBindingObserver {
  /// Time in the background after which the app lock asks again, so a quick
  /// trip to a file picker or the share sheet does not lock the app.
  static const _lockGrace = Duration(seconds: 30);

  late final DeviceService _device = widget.device ?? DeviceService();
  late final UpdateService? _updates =
      widget.updates ?? (kReleaseMode ? UpdateService() : null);
  // Dialogs shown from here (the update offer) need the app's navigator.
  final _navigator = GlobalKey<NavigatorState>();
  // A newer release found at launch, until it is offered.
  AppRelease? _update;
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

  /// Looks for a newer release once settings load, unless turned off in
  /// Settings. Failures (offline, rate limited) wait for the next launch.
  Future<void> _checkForUpdate() async {
    final updates = _updates;
    if (updates == null || !widget.state.settings.checkUpdates) return;
    try {
      final release = await updates.check();
      if (release != null && mounted) setState(() => _update = release);
    } catch (_) {}
  }

  Future<void> _offerUpdate(AppRelease release) async {
    final updates = _updates;
    if (updates == null) return;
    final installed = await updates.installedVersion();
    final navigator = _navigator.currentContext;
    // The setting may have been turned off while the check ran.
    if (navigator == null ||
        !navigator.mounted ||
        !widget.state.settings.checkUpdates) {
      return;
    }
    await showUpdateDialog(
      navigator,
      updates: updates,
      release: release,
      installed: installed,
    );
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
      _checkForUpdate();
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
      final reduceMotion = settings.reduceMotion;
      setSurfaceGlass(
        opacity: settings.surfaceOpacity,
        panelOpacity: settings.panelOpacity,
        detailsOpacity: settings.detailsOpacity,
        blur: reduceMotion ? 0 : settings.surfaceBlur,
      );
      // Reduce motion skips the splash animation once settings are loaded.
      // Remembered, so turning it off later does not bring the splash back.
      final splashComplete = _splashComplete =
          _splashComplete || (widget.state.initialized && reduceMotion);
      final theme = buildAppTheme(board: widget.state.board);
      final locked = _locked && splashComplete;
      final hidden = locked || (_covered && splashComplete);
      if (locked && !_prompted) {
        _prompted = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
      }
      // Offered once the first screen shows and the app is unlocked.
      final update = _update;
      if (update != null && splashComplete && !hidden) {
        _update = null;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _offerUpdate(update),
        );
      }
      return MaterialApp(
        title: 'BooruPlus',
        navigatorKey: _navigator,
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
        // As the splash logo moves up, the first screen is revealed from
        // the bottom edge, following it up.
        home: AnimatedSwitcher(
          duration: reduceMotion ? Duration.zero : SplashScreen.exitDuration,
          switchInCurve: SplashScreen.exitCurve,
          switchOutCurve: SplashScreen.exitCurve,
          transitionBuilder: _revealFromBottom,
          child: !splashComplete || !widget.state.initialized
              ? SplashScreen(
                  ready: widget.state.initialized,
                  onFinished: _finishSplash,
                )
              : widget.state.board == null
              ? OnboardingScreen(state: widget.state)
              : HomeScreen(state: widget.state),
        ),
      );
    },
  );
}

/// Reveals an incoming screen from the bottom edge up, rising slightly as
/// it goes. The screen leaving stays as it is underneath (the splash runs
/// its own exit). Once revealed, nothing is clipped.
Widget _revealFromBottom(Widget child, Animation<double> animation) =>
    AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) {
        final revealing = animation.status == AnimationStatus.forward;
        final value = revealing ? animation.value : 1.0;
        return ClipRect(
          clipper: _BottomReveal(value),
          clipBehavior: revealing ? Clip.hardEdge : Clip.none,
          child: Transform.translate(
            offset: Offset(0, 32 * (1 - value)),
            child: child,
          ),
        );
      },
    );

class _BottomReveal extends CustomClipper<Rect> {
  const _BottomReveal(this.fraction);

  /// The share of the height shown, measured from the bottom.
  final double fraction;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(
    0,
    size.height * (1 - fraction.clamp(0.0, 1.0)),
    size.width,
    size.height,
  );

  @override
  bool shouldReclip(_BottomReveal oldClipper) =>
      oldClipper.fraction != fraction;
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

/// The logo fades in and waits until the app is [ready], then moves up off
/// the screen. [onFinished] is called as it starts moving, so the first
/// screen can be revealed behind it over [exitDuration].
class SplashScreen extends StatefulWidget {
  const SplashScreen({
    super.key,
    required this.ready,
    required this.onFinished,
  });
  final bool ready;
  final VoidCallback onFinished;

  static const exitDuration = Duration(milliseconds: 660);
  static const exitCurve = Curves.easeInOutCubic;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  /// Where the controller holds, between fading in and moving up.
  static const _hold = .4;
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: SplashScreen.exitDuration * (1 / (1 - _hold)),
  );
  bool _exiting = false;

  @override
  void initState() {
    super.initState();
    _controller.animateTo(_hold).whenCompleteOrCancel(_exit);
  }

  @override
  void didUpdateWidget(SplashScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Not during build: finishing rebuilds the app.
    if (widget.ready && !oldWidget.ready) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _exit());
    }
  }

  void _exit() {
    if (!mounted || _exiting || !widget.ready || _controller.value < _hold) {
      return;
    }
    _exiting = true;
    widget.onFinished();
    _controller.forward();
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
        final enter = Curves.easeOut.transform((t / _hold).clamp(0.0, 1.0));
        final exit = SplashScreen.exitCurve.transform(
          ((t - _hold) / (1 - _hold)).clamp(0.0, 1.0),
        );
        // From the middle to just past the top edge, always above the edge
        // of the screen being revealed underneath.
        final height = MediaQuery.sizeOf(context).height;
        return Opacity(
          opacity: enter,
          child: Transform.translate(
            offset: Offset(0, -height * .65 * exit),
            child: child,
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
