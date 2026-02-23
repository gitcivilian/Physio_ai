import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_mesh_detection/google_mlkit_face_mesh_detection.dart';

class FaceMeshPainter extends CustomPainter {
  final List<FaceMesh> meshes;
  final Size imageSize;
  final InputImageRotation rotation;
  final CameraLensDirection cameraLensDirection;
  final String? exerciseType; // To filter what to draw
  final bool isPoseMet; // To change color

  FaceMeshPainter(
    this.meshes,
    this.imageSize,
    this.rotation,
    this.cameraLensDirection, {
    this.exerciseType,
    this.isPoseMet = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (meshes.isEmpty) return;

    final Paint paintCorrect = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..color = Colors.greenAccent;

    final Paint paintNeutral = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = Colors.white.withOpacity(0.5);

    final mesh = meshes.first;

    void drawContour(FaceMeshContourType type, [bool highlight = false]) {
      final points = mesh.contours[type];
      if (points == null || points.isEmpty) return;

      final Path path = Path();

      final Offset first = _translatePoint(points.first, size);
      path.moveTo(first.dx, first.dy);

      for (int i = 1; i < points.length; i++) {
        final Offset p = _translatePoint(points[i], size);
        path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas.drawPath(
        path,
        (isPoseMet || highlight) ? paintCorrect : paintNeutral,
      );
    }

    if (exerciseType == 'smile_assist' ||
        exerciseType == 'mouth_open' ||
        exerciseType == 'show_teeth') {
      drawContour(FaceMeshContourType.upperLipTop);
      drawContour(FaceMeshContourType.upperLipBottom);
      drawContour(FaceMeshContourType.lowerLipTop);
      drawContour(FaceMeshContourType.lowerLipBottom);
    } else if (exerciseType == 'eyebrows') {
      drawContour(FaceMeshContourType.leftEyebrowTop, true);
      drawContour(FaceMeshContourType.rightEyebrowTop, true);
      drawContour(FaceMeshContourType.leftEye);
      drawContour(FaceMeshContourType.rightEye);
    } else if (exerciseType == 'manual_assist' ||
        exerciseType == 'manual_massage') {
      drawContour(FaceMeshContourType.faceOval);
    } else {
      drawContour(FaceMeshContourType.faceOval);
      drawContour(FaceMeshContourType.upperLipTop);
      drawContour(FaceMeshContourType.leftEyebrowTop);
      drawContour(FaceMeshContourType.rightEyebrowTop);
    }
  }

  Offset _translatePoint(FaceMeshPoint point, Size canvasSize) {
    // 1. Normalize (0..1) in IMAGE buffer coordinates
    double x = point.x.toDouble() / imageSize.width;
    double y = point.y.toDouble() / imageSize.height;

    // 2. Rotate to Upright (0..1) based on metadata
    // Android Front (270deg):
    // Image Buffer (Landscape) -> Screen (Portrait)
    // x (long) -> y (long)
    // y (short) -> x (short)

    double rotatedX = x;
    double rotatedY = y;

    // Determine effective dimensions based on rotation
    double bufferW = imageSize.width; // 1280
    double bufferH = imageSize.height; // 720

    if (Platform.isAndroid) {
      switch (rotation) {
        case InputImageRotation.rotation90deg:
          rotatedX = y;
          rotatedY = 1 - x;
          bufferW = imageSize.height;
          bufferH = imageSize.width;
          break;
        case InputImageRotation.rotation180deg:
          rotatedX = 1 - x;
          rotatedY = 1 - y;
          break;
        case InputImageRotation.rotation270deg:
          // Standard Front Camera Android
          // X -> Y (Long axis to Vertical axis)
          // Y -> X (Short axis to Horizontal axis)
          // BUT mapping logic 270 clockwise: (x,y) -> (y, 1-x)
          rotatedX = y;
          rotatedY = 1 - x;

          // Swap dimensions
          bufferW = imageSize.height; // 720
          bufferH = imageSize.width; // 1280
          break;
        default:
          break;
      }
    }

    // 3. Mirror X for Front Camera
    if (cameraLensDirection == CameraLensDirection.front) {
      rotatedX = 1 - rotatedX;
    }

    // 4. Scale to Canvas using BoxFit.cover logic
    // Calculate Scale to COVER the canvas
    // Canvas Size: e.g. 1080x2400
    // Effective Buffer Size: 720x1280

    // Scale X ratio: 1080/720 = 1.5
    // Scale Y ratio: 2400/1280 = 1.875
    // Max Scale = 1.875

    double scaleX = canvasSize.width / bufferW;
    double scaleY = canvasSize.height / bufferH;
    double scale = scaleX > scaleY ? scaleX : scaleY; // Max for Cover

    // Virtual Size = 720*1.875 x 1280*1.875 = 1350 x 2400
    double virtualW = bufferW * scale;
    double virtualH = bufferH * scale;

    // Center Offset
    // (1080 - 1350) / 2 = -135
    double offsetX = (canvasSize.width - virtualW) / 2;
    double offsetY = (canvasSize.height - virtualH) / 2;

    // Apply
    // Point in effective buffer space
    double pX = rotatedX * bufferW;
    double pY = rotatedY * bufferH;

    return Offset(pX * scale + offsetX, pY * scale + offsetY);
  }

  @override
  bool shouldRepaint(FaceMeshPainter oldDelegate) {
    return oldDelegate.imageSize != imageSize ||
        oldDelegate.meshes != meshes ||
        oldDelegate.exerciseType != exerciseType ||
        oldDelegate.isPoseMet != isPoseMet;
  }
}
