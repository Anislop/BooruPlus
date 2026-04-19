import 'package:flutter/material.dart';

import 'core/app_state.dart';
import 'ui/home.dart';
import 'ui/onboarding.dart';
import 'ui/theme.dart';
import 'ui/site_catalog.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(BooruPlusApp(state: AppState()));
}

class BooruPlusApp extends StatefulWidget {
  const BooruPlusApp({super.key, required this.state});
  final AppState state;
  @override
  State<BooruPlusApp> createState() => _BooruPlusAppState();
}

class _BooruPlusAppState extends State<BooruPlusApp> {
  bool _splashComplete = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await Future.wait([widget.state.initialize(), loadSiteCatalog()]);
    if (!mounted) return;
    setState(() {});
  }

  void _finishSplash() {
    if (mounted) setState(() => _splashComplete = true);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.state,
    builder: (context, _) => MaterialApp(
      title: 'BooruPlus',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(board: widget.state.board),
      home: !_splashComplete || !widget.state.initialized
          ? SplashScreen(onFinished: _finishSplash)
          : widget.state.board == null
          ? OnboardingScreen(state: widget.state)
          : HomeScreen(state: widget.state),
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
        AnimationController(vsync: this, duration: const Duration(seconds: 1))
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
        final fadeProgress = ((_controller.value - .65) / .35).clamp(0.0, 1.0);
        return Opacity(opacity: 1 - fadeProgress, child: child);
      },
      child: Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 420),
            child: Image(
              image: AssetImage('assets/LogoFullColorWhite.png'),
              fit: BoxFit.contain,
            ),
          ),
        ),
      ),
    ),
  );
}
