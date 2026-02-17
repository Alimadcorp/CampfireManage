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

  @override
  void initState() {
    super.initState();
    load();
  }

  void load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      socketCtrl.text = prefs.getString('socket') ?? "ws://192.168.10.23:8080";
      idCtrl.text = prefs.getString('scannerId') ?? "";
      timeoutCtrl.text = (prefs.getInt('timeout') ?? 15).toString();
    });
  }

  void save() async {
    final socket = socketCtrl.text.trim();
    final id = idCtrl.text.trim();
    final timeoutStr = timeoutCtrl.text.trim();

    if (socket.isEmpty || id.isEmpty || timeoutStr.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please fill all fields"), backgroundColor: Colors.redAccent),
      );
      return;
    }

    final timeout = int.tryParse(timeoutStr);
    if (timeout == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Timeout must be a number"), backgroundColor: Colors.redAccent),
      );
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('socket', socket);
    await prefs.setString('scannerId', id);
    await prefs.setInt('timeout', timeout);
    
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
              child: ElevatedButton(onPressed: save, child: const Text("Start Scanning")),
            ),
            const Spacer(),
            InkWell(
              onTap: () => launchUrl(Uri.parse("https://github.com/Alimadcorp/campfiremanage")),
              child: const Text(
                "Source Code",
                style: TextStyle(fontSize: 13, decoration: TextDecoration.underline, color: Colors.blueAccent),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              "For Campfire Checkins,",
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: Colors.white60),
            ),
            const Text(
              "Made with Silliness by Muhammad Ali :>",
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

  int nextNum = 1;
  final Map<int, String> sentHistory = {};
  int? lastSentNum;
  bool showFlash = false;

  final Map<String, DateTime> lastScans = {};
  int timeoutSeconds = 15;
  String scannerId = "";
  String socket = "";

  @override
  void initState() {
    super.initState();
    connect();
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
    nextNum = prefs.getInt('nextNum') ?? 1;

    final histJson = prefs.getString('sentHistory');
    if (histJson != null) {
      try {
        final decoded = jsonDecode(histJson) as Map<String, dynamic>;
        decoded.forEach((k, v) {
          final key = int.tryParse(k);
          if (key != null && v is String) sentHistory[key] = v;
        });
      } catch (_) {}
    }

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
      await Future.delayed(const Duration(milliseconds: 500));
    } catch (e) {
      if (!mounted) return;
      setState(() => status = "Connection failed: $e");
      return;
    }

    channel?.stream.listen(
      (message) {
        try {
          final data = jsonDecode(message);
          final t = data['type'];
          if (t == 'auth') {
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
          } else if (t == 'resend') {
            final num = data['num'];
            if (num is int && sentHistory.containsKey(num)) {
              final value = sentHistory[num]!;
              channel?.sink.add(jsonEncode({
                "type": "scan",
                "data": value,
                "time": DateTime.now().toIso8601String(),
                "scannerId": scannerId,
                "num": num,
              }));
            }
          } else if (t == 'received') {
            final num = data['num'];
            final statusResp = data['status'];
            if (num is int && statusResp == 'success') {
              sentHistory.remove(num);
              final mapToStore = <String, String>{};
              for (final e in sentHistory.entries) {
                mapToStore['${e.key}'] = e.value;
              }
              prefs.setString('sentHistory', jsonEncode(mapToStore));
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('#$num sent'),
                  backgroundColor: Colors.green,
                  duration: const Duration(seconds: 1),
                )
              );
            }
          }
        } catch (_) {
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

  void sendScan(String value) async {
    final now = DateTime.now();
    final last = lastScans[value];

    if (last != null && now.difference(last).inSeconds < timeoutSeconds) return;

    lastScans[value] = now;

    final prefs = await SharedPreferences.getInstance();

    final num = nextNum;
    sentHistory[num] = value;
    nextNum = nextNum + 1;
    await prefs.setInt('nextNum', nextNum);
    final mapToStore = <String, String>{};
    for (final e in sentHistory.entries) {
      mapToStore['${e.key}'] = e.value;
    }
    await prefs.setString('sentHistory', jsonEncode(mapToStore));

    channel?.sink.add(
      jsonEncode({
        "type": "scan",
        "data": value,
        "time": now.toIso8601String(),
        "scannerId": scannerId,
        "num": num,
      }),
    );

    setState(() {
      lastSentNum = num;
      showFlash = true;
    });

    Future.delayed(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() => showFlash = false);
    });
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
        title: const Text("Quick Stream"),
        actions: [
          IconButton(
            icon: const Icon(Icons.code),
            onPressed: () => launchUrl(Uri.parse("https://github.com/Alimadcorp/campfiremanage")),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 12.0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                lastSentNum != null ? '#${lastSentNum}' : '-',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
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
                  child: const Text('Back'),
                ),
              ),
            ),
            ],
          ),

          Positioned.fill(
            child: AnimatedOpacity(
              opacity: showFlash ? 0.45 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: true,
                child: Container(
                  color: showFlash ? Colors.greenAccent.withOpacity(0.25) : Colors.transparent,
                ),
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
