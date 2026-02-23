// Register screen is no longer used — the app uses no sign-up flow.
// Kept as a stub so imports elsewhere don't break.
import 'package:flutter/material.dart';

class RegisterScreen extends StatelessWidget {
  const RegisterScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
