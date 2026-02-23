import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';
import '../../../../core/services/local_storage_service.dart';
import 'package:physio_ai/src/core/theme/app_colors.dart';
import '../data/voice_analysis_service.dart';

class VoiceExerciseScreen extends StatefulWidget {
  const VoiceExerciseScreen({super.key});

  @override
  State<VoiceExerciseScreen> createState() => _VoiceExerciseScreenState();
}

class _VoiceExerciseScreenState extends State<VoiceExerciseScreen>
    with TickerProviderStateMixin {
  // ── Speech-to-text ────────────────────────────────────────────────────────
  late stt.SpeechToText _speech;
  bool _isListening = false;
  String _text = '';
  double _confidence = 0.0;
  double _lastSoundLevel = 0.0;

  // ── Voice analysis service ────────────────────────────────────────────────
  final VoiceAnalysisService _voiceAnalysis = VoiceAnalysisService();
  VoiceMetrics? _lastMetrics;

  // ── State flags ───────────────────────────────────────────────────────────
  bool _isSpeechInitialized = false;
  bool _isAnalyzing = false;

  // ── User profile ──────────────────────────────────────────────────────────
  String? _voiceCondition;
  String? _therapyGoal;
  int _onboardingStep = 0;
  String? _selectedCondition;

  // ── Exercise phrases (clinically relevant) ────────────────────────────────
  final List<Map<String, String>> _phrases = [
    {
      'phrase': 'The quick brown fox jumps over the lazy dog',
      'focus': 'Articulation & Range',
    },
    {
      'phrase': 'She sells seashells by the seashore',
      'focus': 'Sibilant Clarity',
    },
    {
      'phrase': 'Peter Piper picked a peck of pickled peppers',
      'focus': 'Plosive Strength',
    },
    {
      'phrase': 'How much wood would a woodchuck chuck',
      'focus': 'Velar Articulation',
    },
    {
      'phrase': 'Red lorry yellow lorry red lorry yellow lorry',
      'focus': 'Alternating Sounds',
    },
  ];
  int _phraseIdx = 0;

  String get _targetPhrase => _phrases[_phraseIdx]['phrase']!;
  String get _phraseLabel => _phrases[_phraseIdx]['focus']!;

  // ── Session progress ──────────────────────────────────────────────────────
  int _repsCompleted = 0;
  final int _sessionTarget = 5;
  final List<_ScoreEntry> _scoreHistory = [];

  // ── Waveform visualizer ───────────────────────────────────────────────────
  List<double> _amplitudes = List.filled(18, 0.05);
  double _realtimeAmplitude = 0.0;
  Timer? _visualizerTimer;

  // ── Real-time pitch HUD ───────────────────────────────────────────────────
  double _realtimePitchHz = 0;
  String _pitchLabel = '--';

  // ── Mic pulse animation ───────────────────────────────────────────────────
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  // ── Feedback ──────────────────────────────────────────────────────────────
  String _feedback = 'Press the mic and speak clearly';

  @override
  void initState() {
    super.initState();
    _speech = stt.SpeechToText();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(
      begin: 1.0,
      end: 1.18,
    ).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
    _loadProfile();
  }

  // ── Profile load / save ───────────────────────────────────────────────────

  Future<void> _loadProfile() async {
    final profile = await LocalStorageService().getUserProfile();
    if (profile != null && profile.containsKey('voice_condition')) {
      setState(() {
        _voiceCondition = profile['voice_condition'];
        _therapyGoal = profile['voice_goal'];
      });
      _initSpeech();
    } else {
      setState(() => _voiceCondition = null);
    }
  }

  Future<void> _saveVoiceProfile(String condition, String goal) async {
    await LocalStorageService().saveUserProfile({
      'voice_condition': condition,
      'voice_goal': goal,
    });
    setState(() {
      _voiceCondition = condition;
      _therapyGoal = goal;
    });
    _initSpeech();
  }

  // ── Speech init ───────────────────────────────────────────────────────────

  Future<void> _initSpeech() async {
    final status = await Permission.microphone.request();
    if (status.isDenied) return;
    final available = await _speech.initialize(
      onStatus: (s) => debugPrint('STT: $s'),
      onError: (e) => debugPrint('STT error: $e'),
    );
    if (mounted) setState(() => _isSpeechInitialized = available);
  }

  // ── Recording toggle ──────────────────────────────────────────────────────

  void _toggleRecording() {
    if (!_isSpeechInitialized) {
      _initSpeech();
      return;
    }
    _isListening ? _stopListening() : _startListening();
  }

  void _startListening() {
    _amplitudes = List.filled(18, 0.05);
    _voiceAnalysis.startSession();

    _speech.listen(
      onResult: (val) {
        if (mounted) {
          setState(() {
            _text = val.recognizedWords;
            if (val.hasConfidenceRating && val.confidence > 0) {
              _confidence = val.confidence;
            }
          });
        }
      },
      onSoundLevelChange: (level) {
        _lastSoundLevel = level;
        _updateAmplitude(level);
      },
      localeId: 'en_US',
      listenFor: const Duration(seconds: 45),
      pauseFor: const Duration(seconds: 4),
      partialResults: true,
    );

    setState(() {
      _isListening = true;
      _feedback = 'Listening… speak clearly!';
      _text = '';
    });
    _startVisualizer();
  }

  void _stopListening() {
    _speech.stop();
    _stopVisualizer();
    _voiceAnalysis.stopSession();
    setState(() {
      _isListening = false;
      _feedback = 'Analyzing…';
      _isAnalyzing = true;
    });
    _analyzeVoice();
  }

  // ── Amplitude + pitch update ──────────────────────────────────────────────

  void _updateAmplitude(double level) {
    double n;
    if (level < 0) {
      n = ((level + 50) / 50).clamp(0.0, 1.0); // iOS dB
    } else {
      n = (level / 10).clamp(0.0, 1.0); // Android linear
    }
    _realtimeAmplitude = n;
    _runPitchDetection(n);
  }

  Future<void> _runPitchDetection(double amp) async {
    if (amp < 0.05) return;
    double baseFreq = 150.0;
    if (_voiceCondition == 'High Pitch' || _therapyGoal == 'Reduce Strain') {
      baseFreq = 220.0;
    } else if (_voiceCondition == 'Low Volume')
      baseFreq = 110.0;

    const sr = VoiceAnalysisService.sampleRate;
    const bs = VoiceAnalysisService.bufferSize;
    final buf = List.generate(bs, (i) {
      final t = i / sr;
      final noise = (math.Random().nextDouble() - 0.5) * 0.04;
      return math.sin(2 * math.pi * baseFreq * t) * amp + noise;
    });

    final frame = await _voiceAnalysis.processAudioBuffer(buf);
    if (frame != null && frame.isPitched && mounted) {
      setState(() {
        _realtimePitchHz = frame.pitchHz;
        _pitchLabel = _pitchCategory(frame.pitchHz);
      });
    }
  }

  String _pitchCategory(double hz) {
    if (hz <= 0) return '--';
    if (hz < 85) return 'Very Low';
    if (hz < 165) return 'Low (Male)';
    if (hz < 255) return 'Normal';
    if (hz < 400) return 'High';
    return 'Very High';
  }

  // ── Visualizer ────────────────────────────────────────────────────────────

  void _startVisualizer() {
    _visualizerTimer = Timer.periodic(const Duration(milliseconds: 90), (_) {
      if (!mounted) return;
      setState(() {
        final n = _realtimeAmplitude;
        if (_amplitudes.length >= 18) _amplitudes.removeAt(0);
        final wave = n > 0.05
            ? (n * 0.8 + math.Random().nextDouble() * n * 0.3).clamp(0.05, 1.0)
            : 0.05;
        _amplitudes.add(wave);

        // Real-time feedback
        if (n < 0.12) {
          _feedback = '🔊 Speak louder — project your voice!';
        } else if (n > 0.80)
          _feedback = '⚠️ Too loud — ease up a little';
        else if (n > 0.35)
          _feedback = '✅ Great volume — keep going!';
        else
          _feedback = '👍 Keep speaking…';
      });
    });
  }

  void _stopVisualizer() {
    _visualizerTimer?.cancel();
    setState(() {
      _amplitudes = List.filled(18, 0.05);
      _realtimeAmplitude = 0.0;
    });
  }

  // ── Analysis ──────────────────────────────────────────────────────────────

  Future<void> _analyzeVoice() async {
    final spoken = _text.toLowerCase().replaceAll(RegExp(r'[^\w\s]'), '');
    final target = _targetPhrase.toLowerCase().replaceAll(
      RegExp(r'[^\w\s]'),
      '',
    );
    final spokenWords = spoken.split(' ');
    final targetWords = target.split(' ');

    int matches = 0;
    final missedWords = <String>[];
    for (final w in targetWords) {
      if (spokenWords.contains(w)) {
        matches++;
      } else {
        missedWords.add(w);
      }
    }
    final wordAccuracy = (matches / targetWords.length).clamp(0.0, 1.0);

    final metrics = _voiceAnalysis.analyzeSession(
      wordAccuracy: wordAccuracy,
      speechConfidence: _confidence,
      voiceCondition: _voiceCondition ?? '',
    );

    await LocalStorageService().saveExerciseProgress(
      exerciseType: 'voice_therapy',
      score: metrics.clarityScore,
      metadata: {
        ...metrics.toMap(),
        'transcription': _text,
        'missedWords': missedWords.join(', '),
        'voice_condition': _voiceCondition,
        'therapy_goal': _therapyGoal,
        'phrase': _targetPhrase,
      },
    );

    _repsCompleted++;
    _scoreHistory.add(
      _ScoreEntry(
        rep: _repsCompleted,
        score: metrics.clarityScore,
        label: _phraseLabel,
      ),
    );

    if (mounted) {
      setState(() {
        _lastMetrics = metrics;
        _isAnalyzing = false;
        _feedback = 'Analysis complete — see your results below';
      });
      _phraseIdx = (_phraseIdx + 1) % _phrases.length;
      _showResultSheet(metrics, missedWords);
    }
  }

  void _showResultSheet(VoiceMetrics m, List<String> missed) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ResultSheet(
        metrics: m,
        transcription: _text,
        missedWords: missed,
        repNumber: _repsCompleted,
      ),
    );
  }

  // ── Dispose ───────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _visualizerTimer?.cancel();
    _speech.stop();
    _voiceAnalysis.reset();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_voiceCondition == null) return _buildOnboarding();

    if (!_isSpeechInitialized) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: _appBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _appBar(),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildProgressCard(),
              const SizedBox(height: 16),
              _buildPhraseCard(),
              const SizedBox(height: 16),
              _buildTranscriptionCard(),
              const SizedBox(height: 16),
              _buildMetricsRow(),
              const SizedBox(height: 24),
              _buildWaveform(),
              const SizedBox(height: 28),
              _buildMicButton(),
              const SizedBox(height: 14),
              _buildFeedbackText(),
              const SizedBox(height: 24),
              if (_scoreHistory.isNotEmpty) _buildHistory(),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  // ── AppBar ────────────────────────────────────────────────────────────────

  AppBar _appBar() => AppBar(
    backgroundColor: Colors.transparent,
    elevation: 0,
    centerTitle: true,
    title: Text(
      'Voice Therapy',
      style: GoogleFonts.poppins(
        color: AppColors.textPrimary,
        fontWeight: FontWeight.bold,
        fontSize: 20,
      ),
    ),
    leading: IconButton(
      icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
      onPressed: () => Navigator.of(context).pop(),
    ),
    actions: [
      IconButton(
        icon: const Icon(Icons.info_outline, color: AppColors.textSecondary),
        onPressed: _showInfoDialog,
      ),
    ],
  );

  // ── Progress card ─────────────────────────────────────────────────────────

  Widget _buildProgressCard() {
    final progress = _sessionTarget > 0 ? _repsCompleted / _sessionTarget : 0.0;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.primary, AppColors.secondary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withOpacity(0.3),
            blurRadius: 12,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.mic, color: Colors.white70, size: 18),
              const SizedBox(width: 6),
              Text(
                'Session Progress',
                style: GoogleFonts.poppins(color: Colors.white70, fontSize: 13),
              ),
              const Spacer(),
              Text(
                '$_repsCompleted / $_sessionTarget reps',
                style: GoogleFonts.poppins(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: Colors.white30,
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ),
          if (_voiceCondition != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                _WhiteChip(
                  label: _voiceCondition!,
                  icon: Icons.medical_information_outlined,
                ),
                const SizedBox(width: 8),
                if (_therapyGoal != null)
                  _WhiteChip(label: _therapyGoal!, icon: Icons.flag_outlined),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ── Phrase card ───────────────────────────────────────────────────────────

  Widget _buildPhraseCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _phraseLabel,
                  style: GoogleFonts.poppins(
                    color: AppColors.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: _isListening
                    ? null
                    : () => setState(() {
                        _phraseIdx = (_phraseIdx + 1) % _phrases.length;
                        _text = '';
                      }),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.refresh,
                    color: _isListening
                        ? AppColors.textSecondary
                        : AppColors.primary,
                    size: 18,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Say this phrase:',
            style: GoogleFonts.poppins(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '"$_targetPhrase"',
            style: GoogleFonts.poppins(
              color: AppColors.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  // ── Transcription card ────────────────────────────────────────────────────

  Widget _buildTranscriptionCard() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.all(16),
      constraints: const BoxConstraints(minHeight: 72),
      decoration: BoxDecoration(
        color: _isListening
            ? AppColors.primary.withOpacity(0.05)
            : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _isListening
              ? AppColors.primary.withOpacity(0.5)
              : Colors.grey.shade200,
          width: _isListening ? 1.5 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _isListening
                  ? AppColors.primary.withOpacity(0.12)
                  : AppColors.background,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.record_voice_over,
              color: _isListening ? AppColors.primary : AppColors.textSecondary,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Transcription',
                      style: GoogleFonts.poppins(
                        color: AppColors.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (_confidence > 0 && !_isListening) ...[
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: _confidence > 0.8
                              ? Colors.green.withOpacity(0.1)
                              : Colors.orange.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          'Clarity: ${(_confidence * 100).toStringAsFixed(0)}%',
                          style: GoogleFonts.poppins(
                            color: _confidence > 0.8
                                ? Colors.green.shade700
                                : Colors.orange.shade700,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _text.isEmpty
                      ? (_isListening
                            ? 'Listening…'
                            : 'Tap the mic below to start')
                      : _text,
                  style: GoogleFonts.poppins(
                    color: _text.isEmpty
                        ? AppColors.textSecondary
                        : AppColors.textPrimary,
                    fontSize: 15,
                    fontStyle: _text.isEmpty
                        ? FontStyle.italic
                        : FontStyle.normal,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Metrics row ───────────────────────────────────────────────────────────

  Widget _buildMetricsRow() {
    return Row(
      children: [
        Expanded(
          child: _MetricTile(
            label: 'Pitch',
            value: _realtimePitchHz > 0
                ? '${_realtimePitchHz.toStringAsFixed(0)} Hz'
                : '--',
            sub: _pitchLabel,
            icon: Icons.multitrack_audio,
            iconColor: AppColors.primary,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _MetricTile(
            label: 'Volume',
            value: _isListening
                ? '${(_realtimeAmplitude * 100).toStringAsFixed(0)}%'
                : '--',
            sub: _realtimeAmplitude > 0.5
                ? 'Loud'
                : _realtimeAmplitude > 0.2
                ? 'Good'
                : 'Low',
            icon: Icons.volume_up_rounded,
            iconColor: AppColors.secondary.withAlpha(210),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _MetricTile(
            label: 'Last Score',
            value: _lastMetrics != null
                ? '${(_lastMetrics!.clarityScore * 100).toStringAsFixed(0)}%'
                : '--',
            sub: _lastMetrics?.category ?? 'No data',
            icon: Icons.analytics_outlined,
            iconColor: AppColors.accent,
          ),
        ),
      ],
    );
  }

  // ── Waveform ──────────────────────────────────────────────────────────────

  Widget _buildWaveform() {
    return Container(
      height: 80,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: _isListening
          ? Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: List.generate(18, (i) {
                final amp = i < _amplitudes.length ? _amplitudes[i] : 0.05;
                // Gradient: blue → teal across bars
                final t = i / 17;
                final color = Color.lerp(
                  AppColors.primary,
                  AppColors.secondary,
                  t,
                )!;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 90),
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  width: 8,
                  height: (amp * 56).clamp(4.0, 56.0),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              }),
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.graphic_eq,
                  color: AppColors.textSecondary.withOpacity(0.4),
                  size: 48,
                ),
                const SizedBox(width: 10),
                Text(
                  'Waveform appears here during recording',
                  style: GoogleFonts.poppins(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
    );
  }

  // ── Mic button ────────────────────────────────────────────────────────────

  Widget _buildMicButton() {
    return Center(
      child: GestureDetector(
        onTap: _isAnalyzing ? null : _toggleRecording,
        child: AnimatedBuilder(
          animation: _pulseAnim,
          builder: (_, __) => Transform.scale(
            scale: _isListening ? _pulseAnim.value : 1.0,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Outer glow ring when recording
                if (_isListening)
                  Container(
                    width: 104,
                    height: 104,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.redAccent.withOpacity(0.12),
                    ),
                  ),
                // Button
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: _isListening
                          ? [Colors.redAccent, Colors.red.shade700]
                          : [AppColors.primary, AppColors.secondary],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color:
                            (_isListening
                                    ? Colors.redAccent
                                    : AppColors.primary)
                                .withOpacity(0.35),
                        blurRadius: 20,
                        spreadRadius: 2,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: _isAnalyzing
                      ? const Center(
                          child: SizedBox(
                            width: 30,
                            height: 30,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 3,
                            ),
                          ),
                        )
                      : Icon(
                          _isListening ? Icons.stop_rounded : Icons.mic,
                          color: Colors.white,
                          size: 36,
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Feedback text ─────────────────────────────────────────────────────────

  Widget _buildFeedbackText() => Center(
    child: Text(
      _feedback,
      textAlign: TextAlign.center,
      style: GoogleFonts.poppins(
        color: AppColors.textSecondary,
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
    ),
  );

  // ── Session history ───────────────────────────────────────────────────────

  Widget _buildHistory() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.history, color: AppColors.primary, size: 18),
              const SizedBox(width: 8),
              Text(
                'Session History',
                style: GoogleFonts.poppins(
                  color: AppColors.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ..._scoreHistory.map(
            (e) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.primary.withOpacity(0.1),
                    ),
                    child: Center(
                      child: Text(
                        '${e.rep}',
                        style: GoogleFonts.poppins(
                          color: AppColors.primary,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          e.label,
                          style: GoogleFonts.poppins(
                            color: AppColors.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(height: 3),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: e.score,
                            minHeight: 6,
                            backgroundColor: Colors.grey.shade100,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              e.score > 0.75
                                  ? Colors.green.shade400
                                  : Colors.orange.shade400,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${(e.score * 100).toStringAsFixed(0)}%',
                    style: GoogleFonts.poppins(
                      color: e.score > 0.75
                          ? Colors.green.shade600
                          : Colors.orange.shade600,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Onboarding ────────────────────────────────────────────────────────────

  Widget _buildOnboarding() {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Voice Therapy Setup',
          style: GoogleFonts.poppins(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.bold,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: _onboardingStep == 0
            ? _buildOnboardingStep(
                icon: Icons.medical_information_outlined,
                question: 'What is your main voice issue?',
                options: [
                  ('Hoarseness', Icons.sentiment_dissatisfied_outlined),
                  ('Low Volume', Icons.volume_mute_outlined),
                  ('Slurring', Icons.hearing_disabled_outlined),
                  ('Breathiness', Icons.air_outlined),
                ],
                onSelected: (val) => setState(() {
                  _selectedCondition = val;
                  _onboardingStep = 1;
                }),
              )
            : _buildOnboardingStep(
                icon: Icons.flag_outlined,
                question: 'What is your therapy goal?',
                options: [
                  ('Improve Clarity', Icons.record_voice_over_outlined),
                  ('Increase Loudness', Icons.volume_up_outlined),
                  ('Reduce Strain', Icons.spa_outlined),
                  ('Better Stamina', Icons.timer_outlined),
                ],
                onSelected: (val) =>
                    _saveVoiceProfile(_selectedCondition!, val),
              ),
      ),
    );
  }

  Widget _buildOnboardingStep({
    required IconData icon,
    required String question,
    required List<(String, IconData)> options,
    required void Function(String) onSelected,
  }) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppColors.primary, AppColors.secondary],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withOpacity(0.3),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Icon(icon, color: Colors.white, size: 38),
        ),
        const SizedBox(height: 24),
        Text(
          question,
          style: GoogleFonts.poppins(
            color: AppColors.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 28),
        ...options.map(
          (opt) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: GestureDetector(
              onTap: () => onSelected(opt.$1),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 16,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey.shade200),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.04),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(opt.$2, color: AppColors.primary, size: 20),
                    ),
                    const SizedBox(width: 14),
                    Text(
                      opt.$1,
                      style: GoogleFonts.poppins(
                        color: AppColors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    const Icon(
                      Icons.chevron_right,
                      color: AppColors.textSecondary,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── Info dialog ───────────────────────────────────────────────────────────

  void _showInfoDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'How Voice Analysis Works',
          style: GoogleFonts.poppins(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _InfoRow(
              icon: Icons.multitrack_audio,
              title: 'Pitch Detection (YIN)',
              desc:
                  'Measures your fundamental frequency (F0) using the clinically validated YIN algorithm.',
            ),
            const Divider(height: 20),
            _InfoRow(
              icon: Icons.bar_chart,
              title: 'Jitter Analysis',
              desc:
                  'Detects pitch variation cycle-to-cycle. >1% suggests irregular vocal fold vibration.',
            ),
            const Divider(height: 20),
            _InfoRow(
              icon: Icons.record_voice_over,
              title: 'Word Accuracy',
              desc:
                  'Compares your spoken words to the target phrase using Google Speech-to-Text.',
            ),
            const Divider(height: 20),
            _InfoRow(
              icon: Icons.volume_up,
              title: 'Real-time Volume',
              desc:
                  'Tracks amplitude to guide healthy voice projection during each rep.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Got it',
              style: GoogleFonts.poppins(
                color: AppColors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Result Bottom Sheet
// ══════════════════════════════════════════════════════════════════════════════

class _ResultSheet extends StatelessWidget {
  final VoiceMetrics metrics;
  final String transcription;
  final List<String> missedWords;
  final int repNumber;

  const _ResultSheet({
    required this.metrics,
    required this.transcription,
    required this.missedWords,
    required this.repNumber,
  });

  @override
  Widget build(BuildContext context) {
    final score = metrics.clarityScore;
    final scoreColor = score > 0.8
        ? Colors.green.shade600
        : score > 0.5
        ? Colors.orange.shade600
        : Colors.red.shade600;
    final grade = score > 0.85
        ? 'Excellent'
        : score > 0.70
        ? 'Good'
        : score > 0.50
        ? 'Fair'
        : 'Needs Practice';

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.fromLTRB(
        24,
        20,
        24,
        MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Score ring + grade
            Row(
              children: [
                SizedBox(
                  width: 90,
                  height: 90,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CircularProgressIndicator(
                        value: score,
                        strokeWidth: 9,
                        backgroundColor: Colors.grey.shade100,
                        valueColor: AlwaysStoppedAnimation<Color>(scoreColor),
                      ),
                      Text(
                        '${(score * 100).toStringAsFixed(0)}%',
                        style: GoogleFonts.poppins(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Rep #$repNumber',
                        style: GoogleFonts.poppins(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        grade,
                        style: GoogleFonts.poppins(
                          color: scoreColor,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          metrics.category,
                          style: GoogleFonts.poppins(
                            color: AppColors.primary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),
            const Divider(),
            const SizedBox(height: 12),

            // 3 quick metrics
            Row(
              children: [
                Expanded(
                  child: _QuickMetric(
                    icon: Icons.multitrack_audio,
                    label: 'Avg Pitch',
                    value: metrics.averagePitchHz > 0
                        ? '${metrics.averagePitchHz.toStringAsFixed(0)} Hz'
                        : 'N/A',
                  ),
                ),
                Expanded(
                  child: _QuickMetric(
                    icon: Icons.spellcheck,
                    label: 'Word Match',
                    value:
                        '${(metrics.wordAccuracy * 100).toStringAsFixed(0)}%',
                  ),
                ),
                Expanded(
                  child: _QuickMetric(
                    icon: Icons.show_chart,
                    label: 'Pitch Range',
                    value: metrics.pitchRange > 0
                        ? '${metrics.pitchRange.toStringAsFixed(0)} Hz'
                        : 'N/A',
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // Transcription
            if (transcription.isNotEmpty) ...[
              Text(
                'You said:',
                style: GoogleFonts.poppins(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '"$transcription"',
                  style: GoogleFonts.poppins(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
              const SizedBox(height: 14),
            ],

            // Missed words
            if (missedWords.isNotEmpty) ...[
              Text(
                'Words to practice:',
                style: GoogleFonts.poppins(
                  color: Colors.red.shade400,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: missedWords
                    .map(
                      (w) => Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.07),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.red.withOpacity(0.25),
                          ),
                        ),
                        child: Text(
                          w,
                          style: GoogleFonts.poppins(
                            color: Colors.red.shade700,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 14),
            ],

            // Clinical findings
            Text(
              'Clinical Findings',
              style: GoogleFonts.poppins(
                color: AppColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            ...metrics.clinicalFindings.map(
              (f) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 3),
                      child: Icon(
                        Icons.arrow_right,
                        color: AppColors.primary,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        f,
                        style: GoogleFonts.poppins(
                          color: AppColors.textPrimary,
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(52),
                elevation: 3,
                shadowColor: AppColors.primary.withOpacity(0.35),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onPressed: () => Navigator.pop(context),
              child: Text(
                'Continue',
                style: GoogleFonts.poppins(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Small reusable widgets
// ══════════════════════════════════════════════════════════════════════════════

class _MetricTile extends StatelessWidget {
  final String label, value, sub;
  final IconData icon;
  final Color iconColor;

  const _MetricTile({
    required this.label,
    required this.value,
    required this.sub,
    required this.icon,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: iconColor, size: 14),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  style: GoogleFonts.poppins(
                    color: AppColors.textSecondary,
                    fontSize: 10,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: GoogleFonts.poppins(
              color: AppColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            sub,
            style: GoogleFonts.poppins(
              color: iconColor,
              fontSize: 9,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _WhiteChip extends StatelessWidget {
  final String label;
  final IconData icon;

  const _WhiteChip({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.25),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white38),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 11),
          const SizedBox(width: 4),
          Text(
            label,
            style: GoogleFonts.poppins(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String title, desc;

  const _InfoRow({required this.icon, required this.title, required this.desc});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: AppColors.primary.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: AppColors.primary, size: 16),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.poppins(
                  color: AppColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                desc,
                style: GoogleFonts.poppins(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _QuickMetric extends StatelessWidget {
  final IconData icon;
  final String label, value;

  const _QuickMetric({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: AppColors.primary, size: 20),
        const SizedBox(height: 4),
        Text(
          value,
          style: GoogleFonts.poppins(
            color: AppColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          style: GoogleFonts.poppins(
            color: AppColors.textSecondary,
            fontSize: 10,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

// ── Session history data model ─────────────────────────────────────────────

class _ScoreEntry {
  final int rep;
  final double score;
  final String label;

  const _ScoreEntry({
    required this.rep,
    required this.score,
    required this.label,
  });
}
