import 'package:camera/camera.dart';
import 'dart:io';
import 'dart:math';
// Added for Uint8List
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:physio_ai/src/core/services/local_storage_service.dart';
import 'package:physio_ai/src/core/theme/app_colors.dart';
import 'face_mesh_painter.dart';

class FaceExerciseScreen extends StatefulWidget {
  const FaceExerciseScreen({super.key});

  @override
  State<FaceExerciseScreen> createState() => _FaceExerciseScreenState();
}

class _FaceExerciseScreenState extends State<FaceExerciseScreen> {
  CameraController? _controller;
  bool _isCameraInitialized = false;

  // Exercise State Management
  bool _isExerciseActive = false;
  int _currentStageIndex = 0;
  double _currentHoldDuration = 0.0;
  final double _targetHoldDuration = 2.0; // Hold pose for 2 seconds
  bool _isPoseDetected = false;
  String? _affectedSide; // "Left", "Right", or "Both"

  // Exercise Definitions will be dynamic based on profile
  List<Map<String, dynamic>> _exercises = [];

  // Face Mesh Detector
  final FaceMeshDetector _meshDetector = FaceMeshDetector(
    option: FaceMeshDetectorOptions.faceMesh, // accurate mode
  );

  bool _isProcessingImage = false;
  List<FaceMesh> _faces = [];
  Size? _imageSize;
  InputImageRotation _rotation = InputImageRotation.rotation0deg;
  CameraLensDirection _cameraLensDirection = CameraLensDirection.front;

  @override
  void initState() {
    super.initState();
    _loadProfileAndExercises();
  }

  Future<void> _loadProfileAndExercises() async {
    final profile = await LocalStorageService().getUserProfile();
    if (profile != null && profile.containsKey('affected_side')) {
      setState(() {
        _affectedSide = profile['affected_side'];
        _exercises = _getPersonlizedExercises(_affectedSide!);
      });
      _initializeCamera();
    } else {
      // No profile or side set, stay in "Setup" mode (exercises empty, side null)
      setState(() {
        _affectedSide = null;
      });
    }
  }

  Future<void> _saveAffectedSide(String side) async {
    await LocalStorageService().saveUserProfile({'affected_side': side});
    setState(() {
      _affectedSide = side;
      _exercises = _getPersonlizedExercises(side);
    });
    _initializeCamera();
  }

  List<Map<String, dynamic>> _getPersonlizedExercises(String affectedSide) {
    return [
      {
        "title": "Massage Affected Side",
        "instruction": "Gently massage your $affectedSide cheek",
        "type": "manual_massage",
        "duration": 10,
      },
      {
        "title": "Try to Smile",
        "instruction": "Lift the corners of your mouth towards your ears",
        "type": "smile_assist",
        "is_active": true,
      },
      {
        "title": "Raise Eyebrows",
        "instruction": "Lift both eyebrows as high as you can",
        "type": "eyebrows",
      },
      {
        "title": "Show Teeth",
        "instruction": "Open your mouth wide and show your teeth",
        "type": "mouth_open",
      },
      {
        "title": "Tight Eye Closure",
        "instruction": "Squeeze your eyes shut tightly",
        "type": "eye_close",
      },
    ];
  }

  Future<void> _initializeCamera() async {
    var status = await Permission.camera.request();
    if (status.isDenied) return;

    try {
      final cameras = await availableCameras();
      if (cameras.isNotEmpty) {
        final frontCamera = cameras.firstWhere(
          (camera) => camera.lensDirection == CameraLensDirection.front,
          orElse: () => cameras.first,
        );

        _cameraLensDirection = frontCamera.lensDirection;

        _controller = CameraController(
          frontCamera,
          ResolutionPreset.medium,
          enableAudio: false,
          imageFormatGroup: Platform.isAndroid
              ? ImageFormatGroup.nv21
              : ImageFormatGroup.bgra8888,
        );

        await _controller!.initialize();
        if (mounted) {
          setState(() {
            _isCameraInitialized = true;
          });
        }
      }
    } catch (e) {
      debugPrint("Camera initialization failed: $e");
    }
  }

  void _startExercise() {
    if (_controller == null || !_isCameraInitialized) return;
    if (_exercises.isEmpty) return; // Wait for profile load

    setState(() {
      // Don't start if no faces?
      // User might be setting up.
      _isExerciseActive = true;
      _currentStageIndex = 0;
      _currentHoldDuration = 0.0;
      _isPoseDetected = false;
    });

    _controller!.startImageStream(_processCameraImage);
    _startTimerForManualExercises();
  }

  void _skipExercise() {
    setState(() {
      _nextStage();
    });
  }

  void _startTimerForManualExercises() {
    if (!_isExerciseActive) return;
    if (_currentStageIndex >= _exercises.length) return;

    final currentExercise = _exercises[_currentStageIndex];

    if (currentExercise['type'] == 'manual_massage' ||
        currentExercise['type'] == 'manual_assist') {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (!mounted ||
            !_isExerciseActive ||
            _exercises[_currentStageIndex] != currentExercise) {
          return;
        }

        // WAITING FOR FACE CHECK
        if (_faces.isEmpty) {
          // Loop without progress if face is lost
          updateState(
            () => _aiFeedback = "Please position your face in the camera",
          );
          _startTimerForManualExercises();
          return;
        }

        setState(() {
          _isPoseDetected = true; // Always "detected" for manual
          _currentHoldDuration += 0.1;
          double target = (currentExercise['duration'] as int? ?? 10)
              .toDouble();

          if (_currentHoldDuration >= target) {
            _nextStage();
          } else {
            _startTimerForManualExercises();
          }
        });
      });
    }
  }

  void _nextStage() {
    _currentHoldDuration = 0.0;
    _isPoseDetected = false;
    _aiFeedback = "";

    if (_currentStageIndex < _exercises.length - 1) {
      setState(() {
        _currentStageIndex++;
      });
      // Trigger timer if next is manual
      _startTimerForManualExercises();
    } else {
      _finishExercise();
    }
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_isProcessingImage || !_isExerciseActive || !mounted) return;
    _isProcessingImage = true;

    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage == null) {
        _isProcessingImage = false;
        return;
      }

      // Update image size
      if (_imageSize == null || _imageSize != inputImage.metadata?.size) {
        _imageSize = inputImage.metadata?.size;
        _rotation = inputImage.metadata!.rotation;
      }

      final faces = await _meshDetector.processImage(inputImage);

      if (mounted) {
        setState(() {
          _faces = faces;
        });

        if (faces.isNotEmpty) {
          final face = faces.first;
          _checkMeshPose(face);
        } else {
          if (_isPoseDetected) updateState(() => _isPoseDetected = false);
          if (_aiFeedback.isEmpty) {
            updateState(() => _aiFeedback = "Position your face");
          }
        }
      }
    } catch (e) {
      debugPrint("Error processing face: $e");
    } finally {
      _isProcessingImage = false;
    }
  }

  // AI Feedback State
  String _aiFeedback = "";

  void _checkMeshPose(FaceMesh face) {
    if (_currentStageIndex >= _exercises.length) return;

    final currentExercise = _exercises[_currentStageIndex];
    if (currentExercise['type'] == 'manual_massage' ||
        currentExercise['type'] == 'manual_assist') {
      return;
    }

    // Helper: Get center point of a contour
    FaceMeshPoint? getContourCenter(FaceMeshContourType type) {
      final points = face.contours[type];
      if (points == null || points.isEmpty) return null;
      double x = 0, y = 0, z = 0;
      for (var p in points) {
        x += p.x;
        y += p.y;
        z += p.z;
      }
      return FaceMeshPoint(
        index: -1,
        x: x / points.length,
        y: y / points.length,
        z: z / points.length,
      );
    }

    // Key Check Logic
    bool poseMet = false;
    String feedback = "";

    // Calculate Face Width (Outer Eyes) for normalization
    // 33 (Left Eye Inner), 133 (Left Eye Outer) -> 263 (Right Eye Outer) - approx
    // Using contour centers is safer
    final leftEye = getContourCenter(FaceMeshContourType.leftEye);
    final rightEye = getContourCenter(FaceMeshContourType.rightEye);

    if (leftEye == null || rightEye == null) return;

    double faceWidth = _distance(leftEye.x, leftEye.y, rightEye.x, rightEye.y);
    if (faceWidth == 0) faceWidth = 100; // Safeguard

    switch (currentExercise['type']) {
      case 'smile_assist':
        // Refined Smile Logic with Lip Contours
        final upperLipTop = face.contours[FaceMeshContourType.upperLipTop];
        final lowerLipBottom =
            face.contours[FaceMeshContourType.lowerLipBottom];

        if (upperLipTop != null && lowerLipBottom != null) {
          // Measure width (first and last points of lip contour are usually corners)
          // Or find min/max X in lip contour
          double minX = upperLipTop.map((p) => p.x).reduce(min);
          double maxX = upperLipTop.map((p) => p.x).reduce(max);
          double mouthWidth = maxX - minX;

          // Ratio
          double ratio = mouthWidth / faceWidth;

          // "Try to Smile" - Relaxed criteria.
          // Normal Width Ratio is ~0.4? Smile is > 0.45?
          // INCREASED THRESHOLD to prevent false positives on resting face
          if (ratio > 0.55) {
            // Was 0.45
            poseMet = true;
            feedback = "Great smile! Hold it.";
          } else {
            feedback = "Widen your smile more!";
          }
        }
        break;

      case 'eyebrows':
        // Brow Raise
        // Distance: Brow Top to Eye Top
        final leftBrow = getContourCenter(FaceMeshContourType.leftEyebrowTop);
        final rightBrow = getContourCenter(FaceMeshContourType.rightEyebrowTop);
        // Eyes already have centers

        if (leftBrow != null && rightBrow != null) {
          double leftLift = _distance(
            leftBrow.x,
            leftBrow.y,
            leftEye.x,
            leftEye.y,
          );
          double rightLift = _distance(
            rightBrow.x,
            rightBrow.y,
            rightEye.x,
            rightEye.y,
          );

          double avgLift = (leftLift + rightLift) / 2;
          double ratio = avgLift / faceWidth;

          // Normal resting is approx 0.15-0.2? Raised is > 0.25 (depends on face geometry)
          // Sensitivity tuning
          if (ratio > 0.24) {
            // Was 0.18
            poseMet = true;
            feedback = "Good lift!";
          } else {
            feedback = "Raise eyebrows higher!";
          }
        }
        break;

      case 'mouth_open':
      case 'show_teeth':
        final upperLipBottom = getContourCenter(
          FaceMeshContourType.upperLipBottom,
        );
        final lowerLipTop = getContourCenter(FaceMeshContourType.lowerLipTop);

        if (upperLipBottom != null && lowerLipTop != null) {
          double openDist = _distance(
            upperLipBottom.x,
            upperLipBottom.y,
            lowerLipTop.x,
            lowerLipTop.y,
          );
          double ratio = openDist / faceWidth;

          if (ratio > 0.15) {
            // Was 0.1
            poseMet = true;
            feedback = "Excellent!";
          } else {
            feedback = "Open wider!";
          }
        }
        break;

      case 'eye_close':
        // Eye Aspect Ratio or simple top/bottom distance
        final lEyePts = face.contours[FaceMeshContourType.leftEye]!;
        final rEyePts = face.contours[FaceMeshContourType.rightEye]!;

        double lH = _getMaxY(lEyePts) - _getMinY(lEyePts);
        double rH = _getMaxY(rEyePts) - _getMinY(rEyePts);

        double avgH = (lH + rH) / 2;
        double ratio = avgH / faceWidth;

        if (ratio < 0.025) {
          // Was 0.03
          poseMet = true;
          feedback = "Eyes closed tight.";
        } else {
          feedback = "Squeeze eyes shut!";
        }
        break;
    }

    // State Logic
    if (poseMet) {
      if (!_isPoseDetected) updateState(() => _isPoseDetected = true);

      updateState(() {
        _aiFeedback = feedback.isNotEmpty ? feedback : "Hold it!";
        _currentHoldDuration += 0.05;
        if (_currentHoldDuration >= _targetHoldDuration) {
          _nextStage();
        }
      });
    } else {
      if (_isPoseDetected) {
        updateState(() {
          _isPoseDetected = false;
          _currentHoldDuration = 0.0;
        });
      }
      if (feedback.isNotEmpty && mounted && _aiFeedback != feedback) {
        updateState(() => _aiFeedback = feedback);
      }
    }
  }

  double _getMaxY(List<FaceMeshPoint> pts) => pts.map((e) => e.y).reduce(max);
  double _getMinY(List<FaceMeshPoint> pts) => pts.map((e) => e.y).reduce(min);

  // Safe State Update Helper
  void updateState(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  double _distance(num x1, num y1, num x2, num y2) {
    return sqrt(pow(x1 - x2, 2) + pow(y1 - y2, 2));
  }

  void _finishExercise() {
    _isExerciseActive = false;
    _controller?.stopImageStream();
    _showCompletionDialog();
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    if (_controller == null) return null;

    final camera = _controller!.description;
    final sensorOrientation = camera.sensorOrientation;

    final InputImageRotation rotation =
        InputImageRotationValue.fromRawValue(sensorOrientation) ??
        InputImageRotation.rotation0deg;
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    final plane = image.planes.first;

    return InputImage.fromBytes(
      bytes: _concatenatePlanes(image.planes),
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  Uint8List _concatenatePlanes(List<Plane> planes) {
    final WriteBuffer allBytes = WriteBuffer();
    for (var plane in planes) {
      allBytes.putUint8List(plane.bytes);
    }
    return allBytes.done().buffer.asUint8List();
  }

  Future<void> _showCompletionDialog() async {
    await LocalStorageService().saveExerciseProgress(
      exerciseType: "face_therapy_palsy_mesh",
      score: 1.0,
      metadata: {'stages_completed': _exercises.length},
    );

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text("Therapy Session Complete!"),
        content: const Text(
          "Great job completing your facial exercises using AI Mesh Analysis.",
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).pop();
            },
            child: const Text("Finish"),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _meshDetector.close(); // Close mesh detector
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_affectedSide == null) {
      return Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(title: const Text("Face Therapy Setup")),
        body: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                "Customize Your Therapy",
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: AppColors.primary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              const Text(
                "Which side of your face is affected?",
                style: TextStyle(fontSize: 18),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              _buildSideOption("Left Side"),
              _buildSideOption("Right Side"),
              _buildSideOption("Both"),
            ],
          ),
        ),
      );
    }

    if (!_isCameraInitialized) {
      return Scaffold(
        appBar: AppBar(title: const Text("Face Therapy")),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final currentExercise = _currentStageIndex < _exercises.length
        ? _exercises[_currentStageIndex]
        : _exercises.last;
    final double progress = (_currentHoldDuration / _targetHoldDuration).clamp(
      0.0,
      1.0,
    );
    // Correct Scaling for Camera Preview to match FaceMeshPainter's BoxFit.cover logic
    // Camera Preview usually renders the texture with correct aspect ratio
    // We need to ensure it COVERS the screen
    final mediaSize = MediaQuery.of(context).size;
    final scale = 1 / (_controller!.value.aspectRatio * mediaSize.aspectRatio);

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: [
          // Use FittedBox to ensure the CameraPreview COVERS the screen
          // We must provide the correctly rotated dimensions to the container
          if (_controller?.value.previewSize != null)
            SizedBox.expand(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _controller!
                      .value
                      .previewSize!
                      .height, // Swap for Portrait
                  height: _controller!.value.previewSize!.width,
                  child: CameraPreview(_controller!),
                ),
              ),
            )
          else
            const Center(child: CircularProgressIndicator()),

          if (_imageSize != null && _faces.isNotEmpty && _isExerciseActive)
            CustomPaint(
              size: Size.infinite,
              painter: FaceMeshPainter(
                _faces,
                _imageSize!,
                _rotation,
                _cameraLensDirection,
                exerciseType: currentExercise['type'],
                isPoseMet: _isPoseDetected,
              ),
            ),

          // Instruction Overlay
          Positioned(
            top: 50,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        "Step ${_currentStageIndex + 1}/${_exercises.length}",
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),
                      if (_isExerciseActive)
                        GestureDetector(
                          onTap: _skipExercise,
                          child: const Text(
                            "Skip",
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    currentExercise['title'],
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    currentExercise['instruction'],
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ],
              ),
            ),
          ),

          // Feedback Status
          if (_isExerciseActive)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isPoseDetected)
                    const Icon(
                      Icons.check_circle,
                      color: Colors.greenAccent,
                      size: 80,
                    ),
                  if (_isPoseDetected)
                    Text(
                      "Hold it!",
                      style: TextStyle(
                        color: Colors.greenAccent,
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        shadows: [Shadow(blurRadius: 10, color: Colors.black)],
                      ),
                    ),
                  const SizedBox(height: 16),
                  if (_aiFeedback.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(30),
                      ),
                      child: Text(
                        _aiFeedback,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.yellowAccent,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          shadows: [Shadow(blurRadius: 2, color: Colors.black)],
                        ),
                      ),
                    ),
                ],
              ),
            ),

          // UI Controls
          Positioned(
            bottom: 30,
            left: 20,
            right: 20,
            child: Card(
              color: Colors.white.withOpacity(0.9),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isExerciseActive) ...[
                      LinearProgressIndicator(
                        value: progress,
                        minHeight: 15,
                        borderRadius: BorderRadius.circular(10),
                        backgroundColor: Colors.grey[300],
                        valueColor: AlwaysStoppedAnimation<Color>(
                          _isPoseDetected ? Colors.green : AppColors.secondary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "Keep holding...",
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                    ] else
                      ElevatedButton(
                        onPressed: _startExercise,
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size(double.infinity, 50),
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text("Start Therapy Session"),
                      ),
                  ],
                ),
              ),
            ),
          ),

          Positioned(
            top: 50,
            left: 10,
            child: CircleAvatar(
              backgroundColor: Colors.white,
              radius: 20,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.black, size: 20),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSideOption(String label) {
    String val = label.split(" ")[0];
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: ElevatedButton(
        onPressed: () => _saveAffectedSide(val),
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(double.infinity, 50),
          backgroundColor: Colors.white,
          foregroundColor: AppColors.secondary,
          side: const BorderSide(color: AppColors.secondary),
          elevation: 0,
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
