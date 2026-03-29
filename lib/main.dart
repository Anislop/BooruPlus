import 'package:flutter/material.dart';

import 'core/app_state.dart';
import 'ui/home.dart';
import 'ui/onboarding.dart';
import 'ui/theme.dart';

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
  @override
  void initState() {
    super.initState();
    widget.state.initialize();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.state,
    builder: (context, _) => MaterialApp(
      title: 'BooruPlus',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(board: widget.state.board),
      home: !widget.state.initialized
          ? const SplashScreen()
          : widget.state.board == null
          ? OnboardingScreen(state: widget.state)
          : HomeScreen(state: widget.state),
    ),
  );
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF2A2227), Color(0xFF171216)],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const BrandMark(size: 128),
            const SizedBox(height: 24),
            Text(
              'BooruPlus',
              style: Theme.of(context).textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: .4),
            ),
            const SizedBox(height: 28),
            const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ),
      ),
    ),
  );
}
