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
  Widget build(BuildContext context) => MaterialApp(
    title: 'BooruPlus',
    debugShowCheckedModeBanner: false,
    theme: appTheme,
    home: ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        if (!widget.state.initialized) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return widget.state.board == null
            ? OnboardingScreen(state: widget.state)
            : HomeScreen(state: widget.state);
      },
    ),
  );
}
