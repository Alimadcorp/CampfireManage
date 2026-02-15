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
    return const MaterialApp(debugShowCheckedModeBanner: false, home: Loader());
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
            ),
            TextField(
              controller: idCtrl,
              decoration: const InputDecoration(labelText: "Scanner ID"),
            ),
            TextField(
              controller: timeoutCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: "Duplicate Timeout (sec)",
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(onPressed: save, child: const Text("Save & Start")),
            const Spacer(),
            const Text(
              "For Campfire checkins",
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            const Text(
              "Made with silliness by Muhammad Ali :>",
              style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
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
  late WebSocketChannel channel;

  final Map<String, DateTime> lastScans = {};
  int timeoutSeconds = 15;
  String scannerId = "";
  String socket = "";

  @override
  void initState() {
    super.initState();
    connect();
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
    socket = prefs.getString('socket')!;
    scannerId = prefs.getString('scannerId') ?? "";
    timeoutSeconds = prefs.getInt('timeout') ?? 15;

    channel = WebSocketChannel.connect(Uri.parse(socket));

    channel.stream.listen(
      (message) {
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
      },
      onError: (_) {
        setState(() => status = "Connection error");
      },
    );

    final meta = await getMetadata();

    channel.sink.add(
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

    channel.sink.add(
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
      return Scaffold(body: Center(child: Text(status)));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("QR Scanner"),
        actions: [
          IconButton(
            icon: const Icon(Icons.code),
            onPressed: () =>
                launchUrl(Uri.parse("https://github.com/Alimadcorp/campfiremanage")),
          ),
        ],
      ),
      body: Column(
        children: [
          SwitchListTile(
            title: const Text("Enable"),
            value: enabled,
            onChanged: (v) => setState(() => enabled = v),
          ),
          Expanded(
            child: MobileScanner(
              onDetect: (barcodeCapture) {
                if (!enabled) return;

                for (final code in barcodeCapture.barcodes) {
                  final value = code.rawValue;
                  if (value != null) sendScan(value);
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    channel.sink.close();
    super.dispose();
  }
}
