// pubspec.yaml dependencies:
// dependencies:
//   flutter:
//     sdk: flutter
//   camera: ^0.10.5+5
//   google_mlkit_pose_detection: ^0.5.0
//   permission_handler: ^11.0.1
//   flutter_tts: ^3.8.3

import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'dart:math';
import 'dart:async';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(MaterialApp(
    home: ChildsPoseDetectionApp(cameras: cameras),
    debugShowCheckedModeBanner: false,
  ));
}

class ChildsPoseDetectionApp extends StatefulWidget {
  final List<CameraDescription> cameras;

  const ChildsPoseDetectionApp({Key? key, required this.cameras}) : super(key: key);

  @override
  State<ChildsPoseDetectionApp> createState() => _ChildsPoseDetectionAppState();
}

class _ChildsPoseDetectionAppState extends State<ChildsPoseDetectionApp> {
  CameraController? _cameraController;
  PoseDetector? _poseDetector;
  FlutterTts? _flutterTts;
  
  List<Pose> _poses = [];
  bool _isProcessing = false;
  bool _soundEnabled = true;
  String _feedback = "Initializing...";
  DateTime _lastTTSTime = DateTime.now();
  String _lastSpokenFeedback = "";
  int _correctPoseCount = 0;

  // Pose analysis parameters (normalized for Flutter coordinates)
  static const Map<String, dynamic> IDEAL = {
    'knee_flexion': [10.0, 35.0],
    'hip_heel_distance': 0.12,
    'torso_thigh_contact': 0.15,
    'spine_curvature': [40.0, 120.0],
    'shoulder_relaxation': 0.06,
    'arm_relaxation': 0.2
  };

  static const Map<String, dynamic> TOLERANCE = {
    'knee_flexion': 15.0,
    'hip_heel_distance': 0.06,
    'torso_thigh_contact': 0.08,
    'spine_curvature': 25.0,
    'shoulder_relaxation': 0.04,
    'arm_relaxation': 0.08
  };

  @override
  void initState() {
    super.initState();
    _initializeServices();
  }

  Future<void> _initializeServices() async {
    await _requestPermissions();
    await _initializeTTS();
    await _initializePoseDetection();
    await _initializeCamera();
  }

  Future<void> _requestPermissions() async {
    await [Permission.camera, Permission.microphone].request();
  }

  Future<void> _initializeTTS() async {
    _flutterTts = FlutterTts();
    await _flutterTts?.setLanguage("en-US");
    await _flutterTts?.setSpeechRate(0.8);
  }

  Future<void> _initializePoseDetection() async {
    final options = PoseDetectorOptions(
      model: PoseDetectionModel.accurate,
      mode: PoseDetectionMode.stream,
    );
    _poseDetector = PoseDetector(options: options);
  }

  Future<void> _initializeCamera() async {
    if (widget.cameras.isEmpty) return;
    
    _cameraController = CameraController(
      widget.cameras.first,
      ResolutionPreset.medium,
      enableAudio: false,
    );

    await _cameraController?.initialize();
    if (mounted) {
      setState(() {});
      _startImageStream();
    }
  }

  void _startImageStream() {
    _cameraController?.startImageStream((image) {
      if (!_isProcessing) {
        _isProcessing = true;
        _processImage(image);
      }
    });
  }

  Future<void> _processImage(CameraImage image) async {
    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage != null) {
        final poses = await _poseDetector?.processImage(inputImage);
        if (mounted && poses != null) {
          setState(() {
            _poses = poses;
            _analyzePose();
          });
        }
      }
    } catch (e) {
      print('Error processing image: $e');
    } finally {
      _isProcessing = false;
    }
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    final camera = widget.cameras.first;
    final sensorOrientation = camera.sensorOrientation;
    
    InputImageRotation? rotation;
    if (sensorOrientation == 90) {
      rotation = InputImageRotation.rotation90deg;
    } else if (sensorOrientation == 180) {
      rotation = InputImageRotation.rotation180deg;
    } else if (sensorOrientation == 270) {
      rotation = InputImageRotation.rotation270deg;
    } else {
      rotation = InputImageRotation.rotation0deg;
    }

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    if (image.planes.length != 1) return null;
    final plane = image.planes.first;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  void _analyzePose() {
    if (_poses.isEmpty) {
      _feedback = "No person detected.";
      _lastSpokenFeedback = "";
      _correctPoseCount = 0;
      return;
    }

    final pose = _poses.first;
    final landmarks = pose.landmarks;
    
    // Get key landmarks
    final leftHip = landmarks[PoseLandmarkType.leftHip];
    final rightHip = landmarks[PoseLandmarkType.rightHip];
    final leftKnee = landmarks[PoseLandmarkType.leftKnee];
    final rightKnee = landmarks[PoseLandmarkType.rightKnee];
    final leftAnkle = landmarks[PoseLandmarkType.leftAnkle];
    final rightAnkle = landmarks[PoseLandmarkType.rightAnkle];
    final leftHeel = landmarks[PoseLandmarkType.leftHeel];
    final rightHeel = landmarks[PoseLandmarkType.rightHeel];
    final leftShoulder = landmarks[PoseLandmarkType.leftShoulder];
    final rightShoulder = landmarks[PoseLandmarkType.rightShoulder];
    final leftWrist = landmarks[PoseLandmarkType.leftWrist];
    final rightWrist = landmarks[PoseLandmarkType.rightWrist];
    final nose = landmarks[PoseLandmarkType.nose];

    if (leftHip == null || rightHip == null || leftKnee == null || rightKnee == null ||
        leftAnkle == null || rightAnkle == null || leftShoulder == null || rightShoulder == null ||
        nose == null) {
      _feedback = "Cannot detect all required body parts.";
      return;
    }

    final feedback = <String>[];

    // 1. Knee Flexion Analysis
    final leftKneeAngle = _calculateAngle(leftHip.x, leftHip.y, leftKnee.x, leftKnee.y, leftAnkle!.x, leftAnkle.y);
    final rightKneeAngle = _calculateAngle(rightHip.x, rightHip.y, rightKnee.x, rightKnee.y, rightAnkle!.x, rightAnkle.y);
    final avgKneeAngle = (leftKneeAngle + rightKneeAngle) / 2;

    if (avgKneeAngle < IDEAL['knee_flexion'][0] - TOLERANCE['knee_flexion'] ||
        avgKneeAngle > IDEAL['knee_flexion'][1] + TOLERANCE['knee_flexion']) {
      feedback.add("Sit deeper on your heels. Knee angle needs adjustment.");
    }

    // 2. Hip-Heel Contact
    final hipCenter = Point((leftHip.x + rightHip.x) / 2, (leftHip.y + rightHip.y) / 2);
    final heelCenter = Point((leftHeel!.x + rightHeel!.x) / 2, (leftHeel.y + rightHeel.y) / 2);
    final hipHeelDistance = _calculateDistance(hipCenter.x, hipCenter.y, heelCenter.x, heelCenter.y);

    if (hipHeelDistance > IDEAL['hip_heel_distance'] + TOLERANCE['hip_heel_distance']) {
      feedback.add("Bring your hips closer to your heels.");
    }

    // 3. Head Position
    if (nose.y <= hipCenter.y) {
      feedback.add("Lower your head below your hips.");
    }

    // 4. Spine Curvature
    final shoulderCenter = Point((leftShoulder.x + rightShoulder.x) / 2, (leftShoulder.y + rightShoulder.y) / 2);
    final spineCurve = _calculateAngle(nose.x, nose.y, shoulderCenter.x, shoulderCenter.y, hipCenter.x, hipCenter.y);

    if (spineCurve < IDEAL['spine_curvature'][0] - TOLERANCE['spine_curvature'] ||
        spineCurve > IDEAL['spine_curvature'][1] + TOLERANCE['spine_curvature']) {
      feedback.add("Relax your spine more. Allow natural curve.");
    }

    // 5. Shoulder Relaxation
    final shoulderDiff = (leftShoulder.y - rightShoulder.y).abs();
    if (shoulderDiff > IDEAL['shoulder_relaxation'] + TOLERANCE['shoulder_relaxation']) {
      feedback.add("Relax and level your shoulders.");
    }

    // 6. Arm Position
    if (leftWrist != null && rightWrist != null) {
      final leftArm = _calculateDistance(leftShoulder.x, leftShoulder.y, leftWrist.x, leftWrist.y);
      final rightArm = _calculateDistance(rightShoulder.x, rightShoulder.y, rightWrist.x, rightWrist.y);
      final armRelaxation = (leftArm + rightArm) / 2;

      if (armRelaxation > IDEAL['arm_relaxation'] + TOLERANCE['arm_relaxation']) {
        feedback.add("Let your arms relax alongside your body.");
      }
    }

    // Update feedback
    if (feedback.isNotEmpty) {
      _feedback = feedback.join("\n");
      _speakFeedback(feedback.first);
    } else {
      _correctPoseCount++;
      String goodMsg = "Good pose!";
      if (_correctPoseCount >= 3 && _correctPoseCount < 6) {
        goodMsg = "You're doing great!";
      } else if (_correctPoseCount >= 6) {
        goodMsg = "Excellent! Keep going.";
      }
      
      final breathMsg = "Now take slow, deep breaths. Inhale through your nose, exhale gently, and relax your body in this posture.";
      _feedback = "$goodMsg\n$breathMsg";
      _speakFeedback("$goodMsg $breathMsg");
    }
  }

  double _calculateAngle(double x1, double y1, double x2, double y2, double x3, double y3) {
    final radians = atan2(y3 - y2, x3 - x2) - atan2(y1 - y2, x1 - x2);
    double angle = (radians * 180.0 / pi).abs();
    return angle > 180 ? 360 - angle : angle;
  }

  double _calculateDistance(double x1, double y1, double x2, double y2) {
    return sqrt(pow(x2 - x1, 2) + pow(y2 - y1, 2));
  }

  void _speakFeedback(String text) {
    if (!_soundEnabled) return;

    final now = DateTime.now();
    if (now.difference(_lastTTSTime).inSeconds > 5 && text != _lastSpokenFeedback) {
      _flutterTts?.speak(text);
      _lastTTSTime = now;
      _lastSpokenFeedback = text;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Child's Pose Detection"),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: Icon(_soundEnabled ? Icons.volume_up : Icons.volume_off),
            onPressed: () {
              setState(() {
                _soundEnabled = !_soundEnabled;
              });
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          // Camera Preview
          Positioned.fill(
            child: CameraPreview(_cameraController!),
          ),
          
          // Pose Overlay
          Positioned.fill(
            child: CustomPaint(
              painter: PosePainter(_poses),
            ),
          ),

          // Feedback Panel
          Positioned(
            bottom: 20,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.8),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _feedback,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _poseDetector?.close();
    _flutterTts?.stop();
    super.dispose();
  }
}

class PosePainter extends CustomPainter {
  final List<Pose> poses;
  
  PosePainter(this.poses);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.green
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    final pointPaint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.fill;

    for (final pose in poses) {
      // Draw pose connections
      _drawPoseConnections(canvas, pose, size, paint);
      
      // Draw landmarks
      for (final landmark in pose.landmarks.values) {
        if (landmark.likelihood > 0.1) {
          canvas.drawCircle(
            Offset(landmark.x * size.width, landmark.y * size.height),
            6,
            pointPaint,
          );
        }
      }
    }
  }

  void _drawPoseConnections(Canvas canvas, Pose pose, Size size, Paint paint) {
    final landmarks = pose.landmarks;
    
    // Define connections (simplified set)
    final connections = [
      [PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder],
      [PoseLandmarkType.leftShoulder, PoseLandmarkType.leftHip],
      [PoseLandmarkType.rightShoulder, PoseLandmarkType.rightHip],
      [PoseLandmarkType.leftHip, PoseLandmarkType.rightHip],
      [PoseLandmarkType.leftHip, PoseLandmarkType.leftKnee],
      [PoseLandmarkType.rightHip, PoseLandmarkType.rightKnee],
      [PoseLandmarkType.leftKnee, PoseLandmarkType.leftAnkle],
      [PoseLandmarkType.rightKnee, PoseLandmarkType.rightAnkle],
      [PoseLandmarkType.leftShoulder, PoseLandmarkType.leftElbow],
      [PoseLandmarkType.rightShoulder, PoseLandmarkType.rightElbow],
      [PoseLandmarkType.leftElbow, PoseLandmarkType.leftWrist],
      [PoseLandmarkType.rightElbow, PoseLandmarkType.rightWrist],
    ];

    for (final connection in connections) {
      final point1 = landmarks[connection[0]];
      final point2 = landmarks[connection[1]];
      
      if (point1 != null && point2 != null && 
          point1.likelihood > 0.1 && point2.likelihood > 0.1) {
        canvas.drawLine(
          Offset(point1.x * size.width, point1.y * size.height),
          Offset(point2.x * size.width, point2.y * size.height),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}