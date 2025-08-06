import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  runApp(const MaterialApp(home: MyPoseOverlayPage(), debugShowCheckedModeBanner: false));
}

class MyPoseOverlayPage extends StatefulWidget {
  const MyPoseOverlayPage({super.key});

  @override
  State<MyPoseOverlayPage> createState() => _MyPoseOverlayPageState();
}

class _MyPoseOverlayPageState extends State<MyPoseOverlayPage> {
  WebViewController? _controller;
  bool _permissionDenied = false;

  @override
  void initState() {
    super.initState();
    _requestCameraPermission();
  }

  Future<void> _requestCameraPermission() async {
    final status = await Permission.camera.request();

    if (status.isGranted) {
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..loadFlutterAsset('assets/index.html');
      setState(() {}); // trigger rebuild with controller
    } else {
      setState(() {
        _permissionDenied = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Main Flutter content (could be camera or UI background)
          Center(
            child: Text(
              'Flutter Main Screen',
              style: TextStyle(color: Colors.white, fontSize: 24),
            ),
          ),

          // Show permission denied message
          if (_permissionDenied)
            const Center(
              child: Text(
                'Camera permission denied.\nPlease allow access to continue.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.redAccent, fontSize: 18),
              ),
            ),

          // Only show WebView if permission granted and controller initialized
          if (_controller != null)
            Positioned(
              top: 100,
              right: 20,
              width: 320,
              height: 240,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: WebViewWidget(controller: _controller!),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
