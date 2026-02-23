import 'package:flutter/material.dart';
import 'package:physio_ai/src/core/services/local_storage_service.dart';
import 'package:physio_ai/src/core/theme/app_colors.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _currentStep = 0;
  String _name = "";
  String _affectedSide = "Left";
  String _severity = "Moderate";
  final List<String> _goals = [];

  void _nextStep() {
    if (_currentStep < 3) {
      setState(() => _currentStep++);
    } else {
      _saveProfile();
    }
  }

  Future<void> _saveProfile() async {
    final profileData = {
      'fullName': _name,
      'affected_side': _affectedSide,
      'severity': _severity,
      'goals': _goals,
      'created_at': DateTime.now().toIso8601String(),
    };

    await LocalStorageService().saveUserProfile(profileData);

    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed('/dashboard');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  children: [
                    const SizedBox(height: 40),
                    Text(
                      "Welcome to PhysioAI",
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(
                            color: AppColors.primary,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      "Let's personalize your therapy plan.",
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 40),

                    if (_currentStep == 0) ...[
                      const Text("What should we call you?"),
                      const SizedBox(height: 20),
                      TextField(
                        onChanged: (val) => setState(() => _name = val),
                        decoration: InputDecoration(
                          labelText: "Your Name",
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ] else if (_currentStep == 1) ...[
                      const Text("Which side of your face is affected?"),
                      const SizedBox(height: 20),
                      _buildOption(
                        "Left Side",
                        _affectedSide,
                        (val) => setState(() => _affectedSide = val),
                      ),
                      _buildOption(
                        "Right Side",
                        _affectedSide,
                        (val) => setState(() => _affectedSide = val),
                      ),
                      _buildOption(
                        "Both",
                        _affectedSide,
                        (val) => setState(() => _affectedSide = val),
                      ),
                    ] else if (_currentStep == 2) ...[
                      const Text("How would you describe the severity?"),
                      const SizedBox(height: 20),
                      _buildOption(
                        "Mild (Some movement possible)",
                        _severity,
                        (val) => setState(() => _severity = val),
                      ),
                      _buildOption(
                        "Moderate (Weak movement)",
                        _severity,
                        (val) => setState(() => _severity = val),
                      ),
                      _buildOption(
                        "Severe (No movement)",
                        _severity,
                        (val) => setState(() => _severity = val),
                      ),
                    ] else if (_currentStep == 3) ...[
                      const Text("Select your therapy goals"),
                      const SizedBox(height: 20),
                      CheckboxListTile(
                        title: const Text("Improve Smile Symmetry"),
                        value: _goals.contains("Smile"),
                        onChanged: (val) => setState(
                          () => val!
                              ? _goals.add("Smile")
                              : _goals.remove("Smile"),
                        ),
                      ),
                      CheckboxListTile(
                        title: const Text("Close Eye Completely"),
                        value: _goals.contains("Eye Closure"),
                        onChanged: (val) => setState(
                          () => val!
                              ? _goals.add("Eye Closure")
                              : _goals.remove("Eye Closure"),
                        ),
                      ),
                      CheckboxListTile(
                        title: const Text("Reduce Pain/Tensor"),
                        value: _goals.contains("Pain Reduction"),
                        onChanged: (val) => setState(
                          () => val!
                              ? _goals.add("Pain Reduction")
                              : _goals.remove("Pain Reduction"),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: ElevatedButton(
                onPressed: _name.isNotEmpty || _currentStep > 0
                    ? _nextStep
                    : null,
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 50),
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                ),
                child: Text(_currentStep == 3 ? "Start Therapy" : "Continue"),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOption(
    String label,
    String groupValue,
    Function(String) onChanged,
  ) {
    // Determine the value to pass based on label content or map it
    // Simplified: use label matches or specialized values
    String value = label.split(
      " ",
    )[0]; // "Left", "Right", "Both", "Mild", "Moderate", "Severe"

    return RadioListTile<String>(
      title: Text(label),
      value: value,
      groupValue: groupValue,
      onChanged: (val) => onChanged(val!),
      activeColor: AppColors.primary,
    );
  }
}
