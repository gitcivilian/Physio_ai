import 'package:flutter/material.dart';
import 'package:physio_ai/src/core/services/local_storage_service.dart';
import 'package:physio_ai/src/core/theme/app_colors.dart';

class DailyCheckInScreen extends StatefulWidget {
  const DailyCheckInScreen({super.key});

  @override
  State<DailyCheckInScreen> createState() => _DailyCheckInScreenState();
}

class _DailyCheckInScreenState extends State<DailyCheckInScreen> {
  int _currentStep = 0;

  // Palsy-specific questions
  final List<String> _questions = [
    "How is your facial movement today compared to yesterday?",
    "Rate your facial symmetry (1-10)?",
    "Any pain or discomfort behind the ear or in the face?",
    "Did you do your facial massages today?",
  ];

  // 0: Better/Same/Worse, 1: Slider, 2: Yes/No + Text, 3: Yes/No
  final List<int> _questionTypes = [0, 1, 2, 3];

  final List<dynamic> _answers = [null, 5.0, "", false];

  void _nextStep() {
    if (_currentStep < _questions.length - 1) {
      setState(() {
        _currentStep++;
      });
    } else {
      _saveAndFinish();
    }
  }

  void _previousStep() {
    if (_currentStep > 0) {
      setState(() {
        _currentStep--;
      });
    }
  }

  Future<void> _saveAndFinish() async {
    final data = {
      'movement_feeling': _answers[0] ?? "Same",
      'symmetry_rating': _answers[1] ?? 5,
      'pain_discomfort': _answers[2] ?? "None",
      'completed_massage': _answers[3] ?? false,
      'timestamp': DateTime.now().toIso8601String(),
    };

    try {
      await LocalStorageService().saveDailyCheckIn(data);
    } catch (e) {
      debugPrint("Error storing data: $e");
    }

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Check-in Complete"),
        content: const Text(
          "Thank you! consistent tracking helps your recovery process.",
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).pop();
            },
            child: const Text("Done"),
          ),
        ],
      ),
    );
  }

  Widget _buildInput(int index) {
    int type = _questionTypes[index];

    switch (type) {
      case 0: // Choice
        return Column(
          children: ["Better", "Same", "Worse"].map((option) {
            bool selected = _answers[index] == option;
            return RadioListTile<String>(
              title: Text(option),
              value: option,
              groupValue: _answers[index],
              onChanged: (val) => setState(() => _answers[index] = val),
              activeColor: AppColors.primary,
            );
          }).toList(),
        );
      case 1: // Slider
        return Column(
          children: [
            Text(
              "Rating: ${(_answers[index] as double).round()}",
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: AppColors.primary,
              ),
            ),
            Slider(
              value: (_answers[index] as double),
              min: 1,
              max: 10,
              divisions: 9,
              activeColor: AppColors.primary,
              onChanged: (val) => setState(() => _answers[index] = val),
            ),
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [Text("Poor"), Text("Excellent")],
            ),
          ],
        );
      case 2: // Text
        return TextField(
          onChanged: (val) => _answers[index] = val,
          maxLines: 3,
          decoration: InputDecoration(
            hintText: "Describe any pain or discomfort...",
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            filled: true,
            fillColor: Colors.grey[100],
          ),
        );
      case 3: // Yes/No
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: () => setState(() => _answers[index] = true),
              style: ElevatedButton.styleFrom(
                backgroundColor: _answers[index] == true
                    ? Colors.green
                    : Colors.grey[300],
                foregroundColor: _answers[index] == true
                    ? Colors.white
                    : Colors.black,
              ),
              child: const Text("Yes"),
            ),
            const SizedBox(width: 20),
            ElevatedButton(
              onPressed: () => setState(() => _answers[index] = false),
              style: ElevatedButton.styleFrom(
                backgroundColor: _answers[index] == false
                    ? Colors.redAccent
                    : Colors.grey[300],
                foregroundColor: _answers[index] == false
                    ? Colors.white
                    : Colors.black,
              ),
              child: const Text("No"),
            ),
          ],
        );
      default:
        return const SizedBox();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text("Daily Progress Check"),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.black,
      ),
      body: SafeArea(
        child: Column(
          children: [
            LinearProgressIndicator(
              value: (_currentStep + 1) / _questions.length,
              backgroundColor: Colors.grey[200],
              valueColor: const AlwaysStoppedAnimation<Color>(
                AppColors.primary,
              ),
              minHeight: 6,
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _questions[_currentStep],
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 40),
                    _buildInput(_currentStep),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (_currentStep > 0)
                    TextButton(
                      onPressed: _previousStep,
                      child: const Text(
                        "Back",
                        style: TextStyle(fontSize: 16, color: Colors.grey),
                      ),
                    )
                  else
                    const SizedBox(),
                  ElevatedButton(
                    onPressed: _nextStep,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                    ),
                    child: Text(
                      _currentStep == _questions.length - 1 ? "Save" : "Next",
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
