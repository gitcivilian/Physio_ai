import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'src/core/theme/app_theme.dart';
import 'src/features/dashboard/presentation/dashboard_screen.dart';
import 'src/features/onboarding/presentation/onboarding_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock orientation to portrait
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  runApp(const PhysioAiApp());
}

class PhysioAiApp extends StatelessWidget {
  const PhysioAiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PhysioAi',
      theme: AppTheme.lightTheme,
      // Go straight to the dashboard — no login needed.
      home: const DashboardScreen(),
      routes: {
        '/dashboard': (context) => const DashboardScreen(),
        '/onboarding': (context) => const OnboardingScreen(),
      },
      debugShowCheckedModeBanner: false,
    );
  }
}
