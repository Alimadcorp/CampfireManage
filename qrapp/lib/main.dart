import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          secondary: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          elevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
          iconTheme: IconThemeData(color: Colors.white),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white10,
          labelStyle: const TextStyle(color: Colors.white70),
          hintStyle: const TextStyle(color: Colors.white54),
          border: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.circular(6)),
        ),
        textTheme: ThemeData.dark().textTheme.apply(bodyColor: Colors.white, displayColor: Colors.white),
      ),
      home: const Loader(),
    );
  }
}

class Loader extends StatefulWidget {
  const Loader({super.key});
  @override
  State<Loader> createState() => _LoaderState();
}

class _LoaderState extends State<Loader> {
  @override
  void initState() {
    super.initState();
    boot();
  }

  void boot() async {
    final prefs = await SharedPreferences.getInstance();
    final socket = prefs.getString('socket');
    if (!mounted) return;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) =>
            socket == null ? const SetupPage() : const ScannerPage(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class SetupPage extends StatefulWidget {
  const SetupPage({super.key});
  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final socketCtrl = TextEditingController(text: "ws://YOUR_SERVER:8080");
  final idCtrl = TextEditingController();
  final timeoutCtrl = TextEditingController(text: "15");

  void save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('socket', socketCtrl.text.trim());
    await prefs.setString('scannerId', idCtrl.text.trim());
    await prefs.setInt('timeout', int.parse(timeoutCtrl.text.trim()));
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const ScannerPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Quick Stream")),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: socketCtrl,
              decoration: const InputDecoration(labelText: "Socket Address"),
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: idCtrl,
              decoration: const InputDecoration(labelText: "Scanner ID"),
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: timeoutCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: "Duplicate Timeout (sec)",
              ),
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(onPressed: save, child: const Text("Start")),
            ),
            const Spacer(),
            const Text(
              "For Campfire checkins",
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}

class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});
  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  bool enabled = false;
  bool authenticated = false;
  String status = "Connecting...";
  WebSocketChannel? channel;
  final MobileScannerController cameraController = MobileScannerController();

  final Map<String, DateTime> lastScans = {};
  int timeoutSeconds = 15;
  String scannerId = "";
  String socket = "";

  @override
  void initState() {
    super.initState();
    connect();
    // Start in standby (paused) until user enables scanning
    cameraController.stop();
  }

  Future<Map<String, dynamic>> getMetadata() async {
    final deviceInfo = DeviceInfoPlugin();
    final pkg = await PackageInfo.fromPlatform();

    if (Platform.isAndroid) {
      final android = await deviceInfo.androidInfo;
      return {
        "brand": android.brand,
        "model": android.model,
        "device": android.device,
        "product": android.product,
        "manufacturer": android.manufacturer,
        "androidVersion": android.version.release,
        "sdkInt": android.version.sdkInt,
        "buildId": android.id,
        "fingerprint": android.fingerprint,
        "appVersion": pkg.version,
        "packageName": pkg.packageName,
      };
    }
    return {};
  }

  void connect() async {
    final prefs = await SharedPreferences.getInstance();
    socket = prefs.getString('socket') ?? '';
    scannerId = prefs.getString('scannerId') ?? "";
    timeoutSeconds = prefs.getInt('timeout') ?? 15;

    if (socket.isEmpty) {
      if (!mounted) return;
      setState(() => status = "No socket configured");
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const SetupPage()),
      );
      return;
    }

    try {
      channel = WebSocketChannel.connect(Uri.parse(socket));
    } catch (e) {
      setState(() => status = "Connection failed");
      return;
    }

    channel?.stream.listen(
      (message) {
        try {
          final data = jsonDecode(message);
          if (data['type'] == 'auth') {
            if (data['status'] == 'success') {
              setState(() {
                authenticated = true;
                status = "Connected";
              });
            } else {
              setState(() {
                status = "Auth failed";
              });
            }
          }
        } catch (_) {
          // ignore malformed messages
        }
      },
      onError: (_) {
        setState(() => status = "Connection error");
      },
    );

    final meta = await getMetadata();

    channel?.sink.add(
      jsonEncode({
        "type": "auth",
        "password": "29678292",
        "scannerId": scannerId,
        "metadata": meta,
      }),
    );
  }

  void sendScan(String value) {
    final now = DateTime.now();
    final last = lastScans[value];

    if (last != null && now.difference(last).inSeconds < timeoutSeconds) return;

    lastScans[value] = now;

    channel?.sink.add(
      jsonEncode({
        "type": "scan",
        "data": value,
        "time": now.toIso8601String(),
        "scannerId": scannerId,
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!authenticated) {
      return Scaffold(
        body: Center(
          child: Text(
            status,
            style: const TextStyle(color: Colors.white70, fontSize: 16),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("QR Scanner"),
        actions: [
          IconButton(
            icon: const Icon(Icons.code),
            onPressed: () => launchUrl(Uri.parse("https://github.com/Alimadcorp/campfiremanage")),
          ),
        ],
      ),
      body: Column(
        children: [
          SwitchListTile(
            title: const Text("Enable", style: TextStyle(color: Colors.white)),
            value: enabled,
            activeColor: Colors.white,
            onChanged: (v) {
              setState(() => enabled = v);
              if (v) {
                cameraController.start();
              } else {
                cameraController.stop();
              }
            },
          ),
          Expanded(
            child: MobileScanner(
              controller: cameraController,
              onDetect: (barcodeCapture) {
                if (!enabled) return;

                for (final code in barcodeCapture.barcodes) {
                  final value = code.rawValue;
                  if (value != null) sendScan(value);
                }
              },
            ),
          ),
          if (!enabled)
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white24),
                  ),
                  onPressed: () {
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(builder: (_) => const SetupPage()),
                    );
                  },
                  child: const Text('Setup'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    channel?.sink.close();
    cameraController.dispose();
    super.dispose();
  }
}
