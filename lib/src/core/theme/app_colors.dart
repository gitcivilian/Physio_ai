import 'package:flutter/material.dart';

class AppColors {
  static const Color primary = Color(0xFF4A90E2);
  static const Color secondary = Color(0xFF50E3C2);
  static const Color background = Color(0xFFF5F7FA);
  static const Color surface = Colors.white;
  static const Color error = Color(0xFFE57373);
  static const Color textPrimary = Color(0xFF2C3E50);
  static const Color textSecondary = Color(0xFF95A5A6);
  static const Color accent = Color(0xFF8E44AD);

  static const LinearGradient primaryGradient = LinearGradient(
    colors: [Color(0xFF4A90E2), Color(0xFF50E3C2)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}
