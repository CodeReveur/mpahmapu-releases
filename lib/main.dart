import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import 'api.dart';
import 'i18n.dart';
import 'screens/drive_screen.dart';
import 'screens/permission_gate.dart';
import 'screens/ride_screen.dart';
import 'permissions.dart';
import 'screens/sign_in_screen.dart';
import 'screens/splash_screen.dart';
import 'theme.dart';

/// Motari — the moto taxi app for MpahMapu.
///
/// It carries the Motari vertical from both ends: a passenger asks for a moto
/// with no account at all, and a motari signs in to take the work, get paid and
/// settle the daily fee. Everything else the platform does stays on the website.
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

class _MotariAppState extends State<MotariApp> with WidgetsBindingObserver {
  final _api = Api();
  bool _ready = false;

  /// Cleared on every launch: the phone is asked what it allows each time the
  /// app starts, because a motari can revoke location between two shifts.
  bool _permitted = false;

  /// Most people opening this app want a ride, not work. A motari says so once
  /// and the app remembers by keeping their session.
  bool _driving = false;

  /// Location being switched off mid-shift, which puts the gate back up.
  StreamSubscription<ServiceStatus>? _locationWatch;

  /// The opening animation has had its turn. Session restore is usually done
  /// long before it is, so this is what actually decides when the app appears.
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // A motari stays signed in until they log out, so the app opens straight
    // into work if a session is already on the device.
    _api.restore().then((_) {
      if (mounted) setState(() => _ready = true);
    });

    // Nothing in this app works without location: a passenger cannot be found
    // and a motari cannot be placed. Allowing it once at startup is not the
    // same as having it, so the phone's own switch is watched for the whole
    // session and the gate goes back up the moment it is turned off.
    _locationWatch = Geolocator.getServiceStatusStream().listen((status) {
      if (status == ServiceStatus.disabled && mounted) {
        setState(() => _permitted = false);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _locationWatch?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Permission can be taken away in the system settings, which the service
    // stream says nothing about: coming back is the moment to ask again.
    if (state == AppLifecycleState.resumed && _permitted) _recheckLocation();
  }

  Future<void> _recheckLocation() async {
    final access = await Permissions.locationStatus();
    if (!access.ok && mounted) setState(() => _permitted = false);
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
    // The moto rides in while the session is being read off the device.
    if (!_shown) {
      return SplashScreen(onDone: () {
        if (mounted) setState(() => _shown = true);
      });
    }
    // Reading the session takes milliseconds and the ride takes seconds, so
    // this is only ever reached by a phone having a very bad day.
    if (!_ready) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: Brand.orange)),
      );
    }
    // Location comes before everything, either side of the app: one cannot be
    // found, the other cannot be placed.
    if (!_permitted) {
      return PermissionGate(onReady: () => setState(() => _permitted = true));
    }
    // A signed-in motari is here to work, and goes straight to the map.
    if (_api.signedIn) {
      return DriveScreen(api: _api, onSignedOut: _onSignedOut);
    }
    if (_driving) {
      return SignInScreen(
        api: _api,
        onSignedIn: () => setState(() {}),
        onBack: () => setState(() => _driving = false),
      );
    }
    return RideScreen(api: _api, onDrive: () => setState(() => _driving = true));
  }

  void _onSignedOut() => setState(() => _driving = false);
}
