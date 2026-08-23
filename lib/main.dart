import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'i18n.dart';
import 'screens/drive_screen.dart';
import 'screens/permission_gate.dart';
import 'screens/sign_in_screen.dart';
import 'theme.dart';

/// Motari — the moto taxi driver app for MpahMapu.
///
/// It carries only the Motari vertical: sign in, go online, take rides and
/// parcels, get paid, and settle the daily fee. Everything else the platform
/// does stays on the website.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  // The language is read before the first frame, so nobody sees English flash
  // past on a phone set to Kinyarwanda.
  await restoreLanguage();
  runApp(const MotariApp());
}

class MotariApp extends StatefulWidget {
  const MotariApp({super.key});

  @override
  State<MotariApp> createState() => _MotariAppState();
}

class _MotariAppState extends State<MotariApp> {
  final _api = Api();
  bool _ready = false;

  /// Cleared on every launch: the phone is asked what it allows each time the
  /// app starts, because a motari can revoke location between two shifts.
  bool _permitted = false;

  @override
  void initState() {
    super.initState();
    // A motari stays signed in until they log out, so the app opens straight
    // into work if a session is already on the device.
    _api.restore().then((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Everything the app says is rebuilt when the language changes, so the
    // switch takes effect on the screen the motari is already looking at.
    return ValueListenableBuilder<String>(
      valueListenable: appLanguage,
      builder: (context, _, _) => MaterialApp(
        title: 'Motari',
        debugShowCheckedModeBanner: false,
        theme: Brand.theme,
        home: _home(),
      ),
    );
  }

  Widget _home() {
    if (!_ready) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: Brand.orange)),
      );
    }
    // Location comes before everything, signed in or not: an app that cannot
    // place the moto has nothing to show either side.
    if (!_permitted) {
      return PermissionGate(onReady: () => setState(() => _permitted = true));
    }
    return _api.signedIn
        ? DriveScreen(api: _api, onSignedOut: _onSignedOut)
        : SignInScreen(api: _api, onSignedIn: () => setState(() {}));
  }

  void _onSignedOut() => setState(() {});
}
