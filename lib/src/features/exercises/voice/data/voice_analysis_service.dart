import 'dart:math' as math;
import 'package:pitch_detector_dart/pitch_detector.dart';
import 'package:pitch_detector_dart/pitch_detector_result.dart';

/// Clinical voice metrics collected during a session
class VoiceMetrics {
  final double averagePitchHz;
  final double pitchStdDev; // Jitter approximation
  final double averageAmplitude;
  final double lowestPitchHz;
  final double highestPitchHz;
  final double pitchRange;
  final double wordAccuracy; // 0.0 – 1.0
  final double clarityScore; // Combined score 0.0 – 1.0
  final String category;
  final List<String> clinicalFindings;

  const VoiceMetrics({
    required this.averagePitchHz,
    required this.pitchStdDev,
    required this.averageAmplitude,
    required this.lowestPitchHz,
    required this.highestPitchHz,
    required this.pitchRange,
    required this.wordAccuracy,
    required this.clarityScore,
    required this.category,
    required this.clinicalFindings,
  });

  Map<String, dynamic> toMap() => {
    'averagePitchHz': averagePitchHz,
    'pitchStdDev': pitchStdDev,
    'lowestPitchHz': lowestPitchHz,
    'highestPitchHz': highestPitchHz,
    'pitchRange': pitchRange,
    'wordAccuracy': wordAccuracy,
    'clarityScore': clarityScore,
    'category': category,
    'clinicalFindings': clinicalFindings.join('; '),
  };
}

/// Real-time pitch frame data
class PitchFrame {
  final double pitchHz;
  final double normalizedAmplitude; // 0.0 – 1.0
  final bool isPitched;
  final DateTime timestamp;

  const PitchFrame({
    required this.pitchHz,
    required this.normalizedAmplitude,
    required this.isPitched,
    required this.timestamp,
  });
}

/// Service that wraps pitch_detector_dart (YIN algorithm) and provides
/// clinical voice analysis metrics for physiotherapy applications.
///
/// The YIN algorithm is the industry-standard fundamental frequency estimator
/// widely used in phoniatrics and speech-language pathology research.
///
/// Usage:
///   1. Call [startSession] before a recording begins.
///   2. Feed raw float PCM buffers via [processAudioBuffer] (async).
///   3. Call [analyzeSession] when recording stops to get [VoiceMetrics].
///   4. Call [reset] to clear state between sessions.
class VoiceAnalysisService {
  // ── YIN Pitch Detector (44100 Hz, 2048-sample buffer) ──────────────────────
  static const int sampleRate = 44100;
  static const int bufferSize = 2048;

  final PitchDetector _pitchDetector = PitchDetector(
    audioSampleRate: sampleRate.toDouble(),
    bufferSize: bufferSize,
  );

  // ── Session state ──────────────────────────────────────────────────────────
  final List<PitchFrame> _frames = [];
  final List<double> _amplitudes = [];
  bool _isActive = false;

  // ── Clinical jitter threshold ───────────────────────────────────────────────
  // >1% pitch jitter is clinically abnormal (GRBAS scale reference)
  static const double _jitterThresholdPercent = 1.0;

  bool get isActive => _isActive;
  List<PitchFrame> get frames => List.unmodifiable(_frames);

  void startSession() {
    _frames.clear();
    _amplitudes.clear();
    _isActive = true;
  }

  void stopSession() {
    _isActive = false;
  }

  /// Process a normalized float PCM buffer [-1.0 .. 1.0].
  /// The list must contain at least [bufferSize] elements.
  /// Returns a [PitchFrame] with the analysis result, or null on error.
  Future<PitchFrame?> processAudioBuffer(List<double> samples) async {
    if (!_isActive || samples.length < bufferSize) return null;

    try {
      final PitchDetectorResult result = await _pitchDetector
          .getPitchFromFloatBuffer(samples);

      // Compute RMS amplitude (samples are in [-1, 1] or scaled range)
      final double rms = _computeRms(samples);
      // Normalize: assume peak amplitude ~32767 if samples were int16
      // or 1.0 if already float — clamp accordingly
      final double maxAmp = samples.map((s) => s.abs()).reduce(math.max);
      final double normalizedAmp = maxAmp > 1.0
          ? (rms / 32767.0).clamp(0.0, 1.0)
          : rms.clamp(0.0, 1.0);

      _amplitudes.add(normalizedAmp);

      final frame = PitchFrame(
        pitchHz: result.pitched ? result.pitch : 0,
        normalizedAmplitude: normalizedAmp,
        isPitched: result.pitched,
        timestamp: DateTime.now(),
      );

      if (result.pitched) _frames.add(frame);
      return frame;
    } catch (_) {
      return null;
    }
  }

  /// Analyze all collected frames and produce clinical [VoiceMetrics].
  VoiceMetrics analyzeSession({
    required double wordAccuracy,
    required double speechConfidence,
    String voiceCondition = '',
  }) {
    final pitched = _frames.where((f) => f.isPitched).toList();

    if (pitched.isEmpty) {
      return VoiceMetrics(
        averagePitchHz: 0,
        pitchStdDev: 0,
        averageAmplitude: 0,
        lowestPitchHz: 0,
        highestPitchHz: 0,
        pitchRange: 0,
        wordAccuracy: wordAccuracy,
        clarityScore: wordAccuracy * 0.5,
        category: 'No Voice Detected',
        clinicalFindings: ['No sustained phonation detected during session.'],
      );
    }

    final pitches = pitched.map((f) => f.pitchHz).toList()..sort();

    // ── Statistics ────────────────────────────────────────────────────────────
    final double avgPitch = _mean(pitches);
    final double stdDev = _stdDev(pitches, avgPitch);
    final double lowestHz = pitches.first;
    final double highestHz = pitches.last;
    final double pitchRange = highestHz - lowestHz;
    final double avgAmp = _amplitudes.isNotEmpty ? _mean(_amplitudes) : 0;

    // ── Jitter % (pitch cycle-to-cycle variation) ──────────────────────────
    final double jitterPercent = avgPitch > 0 ? (stdDev / avgPitch) * 100 : 0;

    // ── Shimmer proxy (volume cycle-to-cycle variation) ────────────────────
    final double ampStdDev = _amplitudes.length > 1
        ? _stdDev(_amplitudes, avgAmp)
        : 0;
    final double shimmerProxy = avgAmp > 0 ? (ampStdDev / avgAmp) * 100 : 0;

    // ── Clinical category and findings ─────────────────────────────────────
    final List<String> findings = [];
    String category = 'Normal';

    // Pitch category (ANSI/ASA normal speaking ranges)
    if (avgPitch <= 0) {
      category = 'No Pitch Detected';
    } else if (avgPitch < 85) {
      category = 'Very Low Pitch';
      findings.add(
        'Average pitch (${avgPitch.toStringAsFixed(0)} Hz) is below normal speaking range. Consider vocal cord or resonance evaluation.',
      );
    } else if (avgPitch < 165) {
      category = 'Male Range';
      findings.add(
        'Pitch within typical male speaking range (${avgPitch.toStringAsFixed(0)} Hz).',
      );
    } else if (avgPitch < 255) {
      category = 'Female Range';
      findings.add(
        'Pitch within typical female speaking range (${avgPitch.toStringAsFixed(0)} Hz).',
      );
    } else if (avgPitch < 400) {
      category = 'Child Range / Elevated';
      findings.add(
        'Pitch at ${avgPitch.toStringAsFixed(0)} Hz — elevated. Common in hyperfunctional dysphonia or falsetto use.',
      );
    } else {
      category = 'Very High Pitch';
      findings.add(
        'Pitch (${avgPitch.toStringAsFixed(0)} Hz) significantly elevated — may indicate vocal strain or falsetto.',
      );
    }

    // Jitter
    if (jitterPercent > _jitterThresholdPercent) {
      if (category == 'Normal' ||
          category.startsWith('Male') ||
          category.startsWith('Female')) {
        category = 'Irregular Phonation';
      }
      findings.add(
        'Pitch jitter ${jitterPercent.toStringAsFixed(2)}% — suggests irregular vocal fold vibration. Normal target is <1%.',
      );
    } else if (avgPitch > 0) {
      findings.add(
        'Pitch stability is good (jitter ${jitterPercent.toStringAsFixed(2)}% < 1% threshold). ✓',
      );
    }

    // Shimmer / amplitude stability
    if (shimmerProxy > 15) {
      findings.add(
        'High amplitude variation (shimmer ~${shimmerProxy.toStringAsFixed(0)}%) — may indicate breathiness or weakness.',
      );
    } else if (avgPitch > 0) {
      findings.add(
        'Amplitude consistency acceptable (shimmer ~${shimmerProxy.toStringAsFixed(0)}%). ✓',
      );
    }

    // Pitch range (expressiveness / monotone detection)
    if (pitched.length > 5) {
      if (pitchRange < 30) {
        findings.add(
          'Limited pitch range (${pitchRange.toStringAsFixed(0)} Hz) — monotone speech pattern. Work on intonation variety.',
        );
      } else if (pitchRange > 80) {
        findings.add(
          'Good pitch variation (${pitchRange.toStringAsFixed(0)} Hz range) — natural prosody detected. ✓',
        );
      }
    }

    // Volume feedback
    if (avgAmp < 0.15) {
      findings.add(
        'Voice intensity is very low. Practice diaphragmatic breathing and straw phonation exercises to increase projection.',
      );
    } else if (avgAmp > 0.85) {
      findings.add(
        'Voice intensity is very high — monitor for vocal hyperfunction and strain.',
      );
    }

    // Condition-specific clinical guidance
    _addConditionGuidance(
      findings,
      voiceCondition,
      avgPitch,
      jitterPercent,
      avgAmp,
    );

    // ── Composite Clarity Score ────────────────────────────────────────────
    // Weighted formula:
    //   40% word accuracy  (transcription match)
    //   30% speech engine confidence
    //   20% pitch stability (inverse jitter)
    //   10% volume score
    final double pitchStabilityScore = jitterPercent <= 0.5
        ? 1.0
        : jitterPercent <= 1.0
        ? 0.8
        : jitterPercent <= 2.0
        ? 0.5
        : 0.2;
    final double volumeScore = avgAmp > 0
        ? avgAmp.clamp(0.15, 0.75) / 0.75
        : 0.5;
    final double clarityScore =
        ((wordAccuracy * 0.4) +
                (speechConfidence * 0.3) +
                (pitchStabilityScore * 0.2) +
                (volumeScore * 0.1))
            .clamp(0.0, 1.0);

    return VoiceMetrics(
      averagePitchHz: avgPitch,
      pitchStdDev: stdDev,
      averageAmplitude: avgAmp,
      lowestPitchHz: lowestHz,
      highestPitchHz: highestHz,
      pitchRange: pitchRange,
      wordAccuracy: wordAccuracy,
      clarityScore: clarityScore,
      category: category,
      clinicalFindings: findings,
    );
  }

  void _addConditionGuidance(
    List<String> findings,
    String condition,
    double avgPitch,
    double jitter,
    double avgAmp,
  ) {
    switch (condition.toLowerCase()) {
      case 'hoarseness':
        if (jitter > 1.0) {
          findings.add(
            '💡 Hoarseness tip: High jitter confirms rough voice quality. Try resonant voice and easy onset exercises to smooth vocal fold vibration.',
          );
        } else {
          findings.add(
            '💡 Hoarseness tip: Maintain vocal hygiene — stay hydrated and avoid throat clearing.',
          );
        }
        break;
      case 'low volume':
        if (avgAmp < 0.35) {
          findings.add(
            '💡 Volume tip: Engage your diaphragm. Practice "straw phonation" and pushing exercises to increase breath support and projection.',
          );
        }
        break;
      case 'slurring':
        findings.add(
          '💡 Slurring tip: Focus on exaggerated articulation. Over-pronounce consonants, especially word-final sounds.',
        );
        break;
      case 'breathiness':
        if (jitter > 0.8 || avgAmp < 0.3) {
          findings.add(
            '💡 Breathiness tip: Practice hard glottal attack exercises and vocal function exercises to improve vocal fold closure.',
          );
        }
        break;
    }
  }

  void reset() {
    _frames.clear();
    _amplitudes.clear();
    _isActive = false;
  }

  // ── Math helpers ──────────────────────────────────────────────────────────

  double _computeRms(List<double> samples) {
    if (samples.isEmpty) return 0;
    double sum = 0;
    for (final s in samples) {
      sum += s * s;
    }
    return math.sqrt(sum / samples.length);
  }

  double _mean(List<double> values) {
    if (values.isEmpty) return 0;
    return values.reduce((a, b) => a + b) / values.length;
  }

  double _stdDev(List<double> values, double mean) {
    if (values.length < 2) return 0;
    final double variance =
        values
            .map((v) => math.pow(v - mean, 2).toDouble())
            .reduce((a, b) => a + b) /
        values.length;
    return math.sqrt(variance);
  }
}
