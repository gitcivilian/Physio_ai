// Login screen is no longer used — the app goes straight to DashboardScreen.
// Kept as a stub so imports elsewhere don't break.
import 'package:flutter/material.dart';

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
