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
  
  try {
    final cameras = await availableCameras();
    runApp(MaterialApp(
      home: ChildsPoseDetectionApp(cameras: cameras),
      debugShowCheckedModeBanner: false,
    ));
  } catch (e) {
    runApp(MaterialApp(
      home: ErrorScreen(error: "Failed to get cameras: $e"),
      debugShowCheckedModeBanner: false,
    ));
  }
}

class ErrorScreen extends StatelessWidget {
  final String error;
  const ErrorScreen({Key? key, required this.error}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            error,
            style: const TextStyle(color: Colors.white, fontSize: 16),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
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
  String _debugInfo = "";
  DateTime _lastTTSTime = DateTime.now();
  String _lastSpokenFeedback = "";
  int _correctPoseCount = 0;
  
  // Camera management
  int _currentCameraIndex = 0;
  bool _isSwitchingCamera = false;
  
  // Initialization states
  bool _cameraInitialized = false;
  bool _poseDetectorInitialized = false;
  bool _permissionsGranted = false;
  bool _hasError = false;
  String _errorMessage = "";

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
    try {
      setState(() {
        _feedback = "Requesting permissions...";
      });
      
      await _requestPermissions();
      
      setState(() {
        _feedback = "Initializing pose detection...";
      });
      
      await _initializePoseDetection();
      
      setState(() {
        _feedback = "Initializing text-to-speech...";
      });
      
      await _initializeTTS();
      
      setState(() {
        _feedback = "Starting camera...";
      });
      
      await _initializeCamera();
      
    } catch (e) {
      setState(() {
        _hasError = true;
        _errorMessage = "Initialization failed: $e";
        _feedback = _errorMessage;
      });
    }
  }

  Future<void> _requestPermissions() async {
    final cameraStatus = await Permission.camera.request();
    final microphoneStatus = await Permission.microphone.request();
    
    _permissionsGranted = cameraStatus.isGranted;
    
    setState(() {
      _debugInfo = "Camera: ${cameraStatus.name}, Microphone: ${microphoneStatus.name}";
    });
    
    if (!cameraStatus.isGranted) {
      throw Exception("Camera permission denied");
    }
  }

  Future<void> _initializeTTS() async {
    try {
      _flutterTts = FlutterTts();
      await _flutterTts?.setLanguage("en-US");
      await _flutterTts?.setSpeechRate(0.8);
    } catch (e) {
      print("TTS initialization failed: $e");
      // Continue without TTS
    }
  }

  Future<void> _initializePoseDetection() async {
    try {
      final options = PoseDetectorOptions(
        model: PoseDetectionModel.base, // Use base model for better performance
        mode: PoseDetectionMode.stream,
      );
      _poseDetector = PoseDetector(options: options);
      _poseDetectorInitialized = true;
      
      setState(() {
        _debugInfo += "\nPose detector: Initialized";
      });
    } catch (e) {
      throw Exception("Failed to initialize pose detector: $e");
    }
  }

  Future<void> _initializeCamera() async {
    if (widget.cameras.isEmpty) {
      throw Exception("No cameras available");
    }
    
    try {
      // Find initial camera (prefer front camera)
      _currentCameraIndex = _findCameraIndex(CameraLensDirection.front);
      if (_currentCameraIndex == -1) {
        _currentCameraIndex = 0; // Use first available camera
      }
      
      // Try different image format groups for better compatibility
      final formatGroups = [
        ImageFormatGroup.nv21,
        ImageFormatGroup.yuv420,
        ImageFormatGroup.bgra8888,
      ];
      
      bool cameraInitialized = false;
      Exception? lastException;
      
      for (final formatGroup in formatGroups) {
        try {
          await _setupCameraWithFormat(_currentCameraIndex, formatGroup);
          cameraInitialized = true;
          setState(() {
            _debugInfo += "\nCamera: Initialized with ${formatGroup.name} (${widget.cameras[_currentCameraIndex].lensDirection.name})";
          });
          break;
        } catch (e) {
          lastException = e as Exception?;
          print("Failed to initialize camera with ${formatGroup.name}: $e");
          continue;
        }
      }
      
      if (!cameraInitialized) {
        throw lastException ?? Exception("Failed to initialize camera with any format");
      }
      
      if (!mounted) return;
      
      _cameraInitialized = true;
      
      setState(() {
        _feedback = "Ready! Position yourself in Child's Pose";
      });
      
      // Start processing after a short delay
      await Future.delayed(const Duration(milliseconds: 500));
      _startImageStream();
      
    } catch (e) {
      throw Exception("Failed to initialize camera: $e");
    }
  }

  Future<void> _setupCameraWithFormat(int cameraIndex, ImageFormatGroup formatGroup) async {
    await _cameraController?.dispose();
    
    _cameraController = CameraController(
      widget.cameras[cameraIndex],
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: formatGroup,
    );

    await _cameraController!.initialize();
  }

  int _findCameraIndex(CameraLensDirection direction) {
    for (int i = 0; i < widget.cameras.length; i++) {
      if (widget.cameras[i].lensDirection == direction) {
        return i;
      }
    }
    return -1;
  }

  Future<void> _setupCamera(int cameraIndex) async {
    await _cameraController?.dispose();
    
    _cameraController = CameraController(
      widget.cameras[cameraIndex],
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21, // Use nv21 for better compatibility
    );

    await _cameraController!.initialize();
  }

  Future<void> _switchCamera() async {
    if (widget.cameras.length <= 1 || _isSwitchingCamera) return;
    
    setState(() {
      _isSwitchingCamera = true;
      _feedback = "Switching camera...";
    });

    try {
      // Stop current image stream
      await _cameraController?.stopImageStream();
      
      // Find next camera
      final currentDirection = widget.cameras[_currentCameraIndex].lensDirection;
      final targetDirection = currentDirection == CameraLensDirection.front 
          ? CameraLensDirection.back 
          : CameraLensDirection.front;
      
      int nextIndex = _findCameraIndex(targetDirection);
      if (nextIndex == -1) {
        // If target direction not found, just use next available camera
        nextIndex = (_currentCameraIndex + 1) % widget.cameras.length;
      }
      
      _currentCameraIndex = nextIndex;
      
      // Try different formats for camera switching
      final formatGroups = [
        ImageFormatGroup.nv21,
        ImageFormatGroup.yuv420,
        ImageFormatGroup.bgra8888,
      ];
      
      bool cameraInitialized = false;
      Exception? lastException;
      
      for (final formatGroup in formatGroups) {
        try {
          await _setupCameraWithFormat(_currentCameraIndex, formatGroup);
          cameraInitialized = true;
          setState(() {
            _debugInfo += "\nSwitched to: ${widget.cameras[_currentCameraIndex].lensDirection.name} (${formatGroup.name})";
          });
          break;
        } catch (e) {
          lastException = e as Exception?;
          continue;
        }
      }
      
      if (!cameraInitialized) {
        throw lastException ?? Exception("Failed to initialize new camera");
      }
      
      setState(() {
        _feedback = "Camera switched. Ready for Child's Pose";
      });
      
      // Restart image stream
      await Future.delayed(const Duration(milliseconds: 500));
      _startImageStream();
      
    } catch (e) {
      setState(() {
        _errorMessage = "Failed to switch camera: $e";
        _feedback = _errorMessage;
      });
    } finally {
      setState(() {
        _isSwitchingCamera = false;
      });
    }
  }

  void _startImageStream() {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    
    try {
      _cameraController!.startImageStream((image) {
        if (!_isProcessing && _poseDetector != null && !_isSwitchingCamera) {
          _isProcessing = true;
          _processImage(image);
        }
      });
      
      setState(() {
        _debugInfo += "\nImage stream: Started";
      });
      
    } catch (e) {
      setState(() {
        _errorMessage = "Failed to start image stream: $e";
        _feedback = _errorMessage;
      });
    }
  }

  Future<void> _processImage(CameraImage image) async {
    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage == null) {
        _isProcessing = false;
        return;
      }

      final poses = await _poseDetector?.processImage(inputImage);
      
      if (mounted && poses != null) {
        setState(() {
          _poses = poses;
          _debugInfo = "Poses detected: ${poses.length} | Format: ${image.format.raw}";
        });
        
        _analyzePose();
      }
    } catch (e) {
      print('Error processing image: $e');
      setState(() {
        _debugInfo += "\nProcessing error: $e";
      });
      
      // If we get repeated processing errors, try to restart the image stream
      if (e.toString().contains('format') || e.toString().contains('null')) {
        print('Image format error detected, attempting to restart image stream...');
        _restartImageStreamWithDelay();
      }
    } finally {
      _isProcessing = false;
    }
  }

  void _restartImageStreamWithDelay() async {
    try {
      await _cameraController?.stopImageStream();
      await Future.delayed(const Duration(milliseconds: 1000));
      if (mounted && _cameraController != null && _cameraController!.value.isInitialized) {
        _startImageStream();
      }
    } catch (e) {
      print('Error restarting image stream: $e');
    }
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    try {
      final camera = widget.cameras[_currentCameraIndex];
      final sensorOrientation = camera.sensorOrientation;
      InputImageRotation? rotation;
      
      // Determine rotation based on device orientation and camera
      if (camera.lensDirection == CameraLensDirection.front) {
        switch (sensorOrientation) {
          case 90:
            rotation = InputImageRotation.rotation270deg;
            break;
          case 180:
            rotation = InputImageRotation.rotation180deg;
            break;
          case 270:
            rotation = InputImageRotation.rotation90deg;
            break;
          default:
            rotation = InputImageRotation.rotation0deg;
        }
      } else {
        switch (sensorOrientation) {
          case 90:
            rotation = InputImageRotation.rotation90deg;
            break;
          case 180:
            rotation = InputImageRotation.rotation180deg;
            break;
          case 270:
            rotation = InputImageRotation.rotation270deg;
            break;
          default:
            rotation = InputImageRotation.rotation0deg;
        }
      }

      // Handle different image formats with fallback
      InputImageFormat? format;
      
      // Try to get format from raw value
      try {
        format = InputImageFormatValue.fromRawValue(image.format.raw);
      } catch (e) {
        print('Failed to get format from raw value: $e');
      }
      
      // If format is null, try common formats based on platform
      if (format == null) {
        // Common formats for Android/iOS
        switch (image.format.raw) {
          case 35: // ImageFormat.YUV_420_888 on Android
            format = InputImageFormat.yuv420;
            break;
          case 17: // ImageFormat.NV21 on Android
            format = InputImageFormat.nv21;
            break;
          case 842094169: // kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange on iOS
            format = InputImageFormat.yuv420;
            break;
          case 875704422: // kCVPixelFormatType_420YpCbCr8BiPlanarFullRange on iOS
            format = InputImageFormat.yuv420;
            break;
          default:
            print('Unsupported image format: ${image.format.raw}');
            // Try to use YUV420 as fallback
            format = InputImageFormat.yuv420;
        }
      }

      if (image.planes.isEmpty) {
        print('No image planes available');
        return null;
      }

      final plane = image.planes.first;
      
      // Validate plane data
      if (plane.bytes.isEmpty) {
        print('Empty plane bytes');
        return null;
      }

      return InputImage.fromBytes(
        bytes: plane.bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: format,
          bytesPerRow: plane.bytesPerRow,
        ),
      );
    } catch (e) {
      print('Error creating InputImage: $e');
      setState(() {
        _debugInfo += "\nInputImage error: $e";
      });
      return null;
    }
  }

  void _analyzePose() {
    if (_poses.isEmpty) {
      setState(() {
        _feedback = "No person detected. Please step into camera view.";
      });
      _lastSpokenFeedback = "";
      _correctPoseCount = 0;
      return;
    }

    final pose = _poses.first;
    final landmarks = pose.landmarks;
    
    // Check if we have the required landmarks
    final requiredLandmarks = [
      PoseLandmarkType.leftHip,
      PoseLandmarkType.rightHip,
      PoseLandmarkType.leftKnee,
      PoseLandmarkType.rightKnee,
      PoseLandmarkType.leftAnkle,
      PoseLandmarkType.rightAnkle,
      PoseLandmarkType.leftShoulder,
      PoseLandmarkType.rightShoulder,
      PoseLandmarkType.nose,
    ];

    bool hasAllLandmarks = true;
    for (final landmarkType in requiredLandmarks) {
      if (landmarks[landmarkType] == null) {
        hasAllLandmarks = false;
        break;
      }
    }

    if (!hasAllLandmarks) {
      setState(() {
        _feedback = "Cannot detect all required body parts. Please ensure your whole body is visible.";
      });
      return;
    }

    // Get landmarks
    final leftHip = landmarks[PoseLandmarkType.leftHip]!;
    final rightHip = landmarks[PoseLandmarkType.rightHip]!;
    final leftKnee = landmarks[PoseLandmarkType.leftKnee]!;
    final rightKnee = landmarks[PoseLandmarkType.rightKnee]!;
    final leftAnkle = landmarks[PoseLandmarkType.leftAnkle]!;
    final rightAnkle = landmarks[PoseLandmarkType.rightAnkle]!;
    final leftShoulder = landmarks[PoseLandmarkType.leftShoulder]!;
    final rightShoulder = landmarks[PoseLandmarkType.rightShoulder]!;
    final nose = landmarks[PoseLandmarkType.nose]!;

    final feedback = <String>[];

    // 1. Knee Flexion Analysis
    final leftKneeAngle = _calculateAngle(leftHip.x, leftHip.y, leftKnee.x, leftKnee.y, leftAnkle.x, leftAnkle.y);
    final rightKneeAngle = _calculateAngle(rightHip.x, rightHip.y, rightKnee.x, rightKnee.y, rightAnkle.x, rightAnkle.y);
    final avgKneeAngle = (leftKneeAngle + rightKneeAngle) / 2;

    if (avgKneeAngle < IDEAL['knee_flexion'][0] - TOLERANCE['knee_flexion'] ||
        avgKneeAngle > IDEAL['knee_flexion'][1] + TOLERANCE['knee_flexion']) {
      feedback.add("Sit deeper on your heels. Knee angle needs adjustment.");
    }

    // 2. Hip-Heel Contact (using available landmarks)
    final hipCenter = Point((leftHip.x + rightHip.x) / 2, (leftHip.y + rightHip.y) / 2);
    final ankleCenter = Point((leftAnkle.x + rightAnkle.x) / 2, (leftAnkle.y + rightAnkle.y) / 2);
    final hipAnkleDistance = _calculateDistance(hipCenter.x, hipCenter.y, ankleCenter.x, ankleCenter.y);

    if (hipAnkleDistance > IDEAL['hip_heel_distance'] + TOLERANCE['hip_heel_distance']) {
      feedback.add("Bring your hips closer to your ankles.");
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

    // Update feedback
    if (feedback.isNotEmpty) {
      setState(() {
        _feedback = feedback.join("\n");
      });
      _speakFeedback(feedback.first);
    } else {
      _correctPoseCount++;
      String goodMsg = "Good pose!";
      if (_correctPoseCount >= 3 && _correctPoseCount < 6) {
        goodMsg = "You're doing great!";
      } else if (_correctPoseCount >= 6) {
        goodMsg = "Excellent! Keep going.";
      }
      
      final breathMsg = "Now take slow, deep breaths.";
      setState(() {
        _feedback = "$goodMsg\n$breathMsg";
      });
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
    if (!_soundEnabled || _flutterTts == null) return;

    final now = DateTime.now();
    if (now.difference(_lastTTSTime).inSeconds > 5 && text != _lastSpokenFeedback) {
      _flutterTts!.speak(text);
      _lastTTSTime = now;
      _lastSpokenFeedback = text;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error, color: Colors.red, size: 64),
                const SizedBox(height: 20),
                Text(
                  _errorMessage,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _hasError = false;
                      _errorMessage = "";
                      _feedback = "Retrying...";
                    });
                    _initializeServices();
                  },
                  child: const Text("Retry"),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (!_cameraInitialized || _cameraController == null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(color: Colors.white),
              const SizedBox(height: 20),
              Text(
                _feedback,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                textAlign: TextAlign.center,
              ),
              if (_debugInfo.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  _debugInfo,
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ]
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Child's Pose Detection"),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          // Camera flip button
          if (widget.cameras.length > 1)
            IconButton(
              icon: _isSwitchingCamera 
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Icon(Icons.flip_camera_ios),
              onPressed: _isSwitchingCamera ? null : _switchCamera,
              tooltip: 'Switch Camera',
            ),
          // Sound toggle button
          IconButton(
            icon: Icon(_soundEnabled ? Icons.volume_up : Icons.volume_off),
            onPressed: () {
              setState(() {
                _soundEnabled = !_soundEnabled;
              });
            },
            tooltip: 'Toggle Sound',
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

          // Debug info (top)
          if (_debugInfo.isNotEmpty)
            Positioned(
              top: 20,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _debugInfo,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),

          // Camera indicator
          Positioned(
            top: 80,
            right: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                widget.cameras[_currentCameraIndex].lensDirection == CameraLensDirection.front 
                    ? "Front" : "Back",
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
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
        if (landmark.likelihood > 0.5) {
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
          point1.likelihood > 0.5 && point2.likelihood > 0.5) {
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