import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../i18n.dart';
import '../models.dart';
import '../permissions.dart';
import '../theme.dart';
import '../widgets/fee_banner.dart';
import '../widgets/offer_card.dart';
import '../widgets/ride_panel.dart';
import 'money_screen.dart';
import 'settings_screen.dart';

/// The motari's working screen: the map behind, the day's work in front.
///
/// One poll drives everything — presence, the offer being held, nearby
/// requests, the active ride and the daily fee — exactly as the web app does,
/// so the two stay in step without a second source of truth.
class DriveScreen extends StatefulWidget {
  final Api api;
  final VoidCallback onSignedOut;
  const DriveScreen({super.key, required this.api, required this.onSignedOut});

  @override
  State<DriveScreen> createState() => _DriveScreenState();
}

class _DriveScreenState extends State<DriveScreen> with WidgetsBindingObserver {
  static const _pollInterval = Duration(seconds: 5);
  static const _heartbeatInterval = Duration(seconds: 4);
  static final _kigali = LatLng(-1.9441, 30.0619);

  final _map = MapController();
  final _ring = AudioPlayer();

  MotariState? _state;
  Position? _position;
  Timer? _poll;
  Timer? _heartbeat;
  Timer? _tick;
  StreamSubscription<Position>? _positions;

  bool _loading = true;
  bool _busy = false;
  String? _error;
  int _offerLeft = 0;
  String? _ringingFor;
  bool _framed = false;

  MotariProfile? get _profile => _state?.profile;
  Ride? get _ride => _state?.activeRide;
  Offer? get _offer => _state?.offer;
  bool get _online => _profile?.online ?? false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _poll = Timer.periodic(_pollInterval, (_) => _refresh());
    _heartbeat = Timer.periodic(_heartbeatInterval, (_) => _sendHeartbeat());
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_offerLeft > 0 && mounted) setState(() => _offerLeft--);
    });
    _watchPosition();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _heartbeat?.cancel();
    _tick?.cancel();
    _positions?.cancel();
    _ring.dispose();
    Permissions.clearOffer(_offerNotificationId);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the app should show the truth immediately, not in five
    // seconds: a ride may have been reassigned while it was in the background.
    if (state == AppLifecycleState.resumed) {
      _refresh();
      // Location can be switched off between two shifts: pick the stream back
      // up if it was lost, and say so plainly if it is still gone.
      if (_positions == null) _watchPosition();
    }
  }

  /* ── location ─────────────────────────────────────────────────────────── */

  Future<void> _watchPosition() async {
    // The gate cleared this before the app opened; asking again here is what
    // catches a motari who turned it off after starting work.
    final access = await Permissions.requestLocation();
    if (!access.ok) {
      if (mounted) setState(() => _error = t('drive.allow_location'));
      return;
    }
    _positions = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen((p) {
      // A kilometre-scale fix is a network guess, not GPS: never draw it.
      if (p.accuracy > 5000) return;
      if (!mounted) return;
      setState(() => _position = p);
      if (!_framed) {
        _framed = true;
        _map.move(LatLng(p.latitude, p.longitude), 16);
      }
    });
  }

  Future<void> _sendHeartbeat() async {
    final p = _position;
    if (p == null || !_online) return;
    try {
      final next = await widget.api.heartbeat(p.latitude, p.longitude);
      if (mounted) _apply(next);
    } catch (_) {
      // A dropped heartbeat is normal on a moving bike; the next one carries.
    }
  }

  /* ── state ────────────────────────────────────────────────────────────── */

  Future<void> _refresh() async {
    try {
      final next = await widget.api.state();
      if (!mounted) return;
      _apply(next);
      setState(() {
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _apply(MotariState next) {
    final offer = next.offer;
    setState(() {
      _state = next;
      if (offer != null) {
        // The server clock rules; the local tick only fills the gaps between polls.
        if (_ringingFor != offer.rideId) _offerLeft = offer.expiresInSeconds;
        if (offer.expiresInSeconds > _offerLeft + 2 || offer.expiresInSeconds < _offerLeft - 2) {
          _offerLeft = offer.expiresInSeconds;
        }
      } else {
        _offerLeft = 0;
      }
    });
    _updateRinging(offer);
  }

  /// A live offer rings for its whole window, like a phone call: a parcel with
  /// the delivery tone, a passenger with the ride tone.
  Future<void> _updateRinging(Offer? offer) async {
    final shouldRing = offer != null && _ride == null && _offerLeft > 0;
    if (shouldRing) {
      if (_ringingFor == offer.rideId) return;
      _ringingFor = offer.rideId;
      final asset = offer.isCourier ? 'audio/incoming-delivery.wav' : 'audio/incoming-ride.wav';
      await _ring.stop();
      await _ring.setReleaseMode(ReleaseMode.loop);
      await _ring.play(AssetSource(asset));
      await Permissions.showOffer(
        id: _offerNotificationId,
        title: offer.isCourier ? t('notify.parcel') : t('notify.ride'),
        body: t('notify.body', {
          'name': offer.passengerName,
          'distance': km(offer.distanceToPickupM),
        }),
      );
    } else if (_ringingFor != null) {
      _ringingFor = null;
      await _ring.stop();
      await Permissions.clearOffer(_offerNotificationId);
    }
  }

  /// One offer is live at a time, so one notification slot is all it needs.
  static const _offerNotificationId = 1;

  Future<void> _act(Future<MotariState> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _apply(await action());
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = t('common.error'));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _call(String phone) async {
    final uri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  /* ── map ──────────────────────────────────────────────────────────────── */

  List<Marker> _markers() {
    final markers = <Marker>[];
    final ride = _ride;

    if (ride != null) {
      markers.add(_pin(LatLng(ride.pickupLat, ride.pickupLng), Brand.orange, Icons.place));
      if (ride.destLat != null && ride.destLng != null) {
        markers.add(_pin(LatLng(ride.destLat!, ride.destLng!), Brand.green, Icons.flag));
      }
    } else if (_online) {
      for (final n in _state?.nearby ?? const <NearbyRide>[]) {
        markers.add(_pin(
          LatLng(n.pickupLat, n.pickupLng),
          Brand.orange,
          n.isCourier ? Icons.inventory_2 : Icons.person,
        ));
      }
    }

    final p = _position;
    if (p != null) {
      markers.add(Marker(
        point: LatLng(p.latitude, p.longitude),
        width: 34,
        height: 34,
        child: Container(
          decoration: BoxDecoration(
            color: Brand.black,
            shape: BoxShape.circle,
            border: Border.all(color: Brand.orange, width: 2),
          ),
          child: const Icon(Icons.two_wheeler, color: Brand.orange, size: 17),
        ),
      ));
    }
    return markers;
  }

  Marker _pin(LatLng at, Color color, IconData icon) => Marker(
        point: at,
        width: 30,
        height: 30,
        child: Container(
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
          ),
          child: Icon(icon, color: Colors.white, size: 15),
        ),
      );

  /* ── build ────────────────────────────────────────────────────────────── */

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: Brand.orange)),
      );
    }

    final fees = _state?.fees;
    final ride = _ride;
    final offer = _offer;
    final hour = DateTime.now().hour;
    // The fee sits on the map through the evening and night; in working hours
    // it lives on the money screen. A paused account shows at any hour.
    final feeHours = hour >= 16 || hour < 8;
    final showFee = fees != null &&
        (fees.paused || (fees.dueAmountRwf > 0 && feeHours));

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _kigali,
              initialZoom: 14,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'rw.mpahmapu.motari',
              ),
              MarkerLayer(markers: _markers()),
            ],
          ),

          // Plate, and the online switch.
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      _chip(
                        icon: Icons.two_wheeler,
                        label: _profile?.plateNumber ?? t('app.name'),
                      ),
                      if (_position == null) ...[
                        const SizedBox(width: 6),
                        Flexible(child: _chip(icon: Icons.gps_not_fixed, label: t("gate.finding_you"))),
                      ],
                      const Spacer(),
                      _onlineButton(),
                    ],
                  ),
                  if (showFee) ...[
                    const SizedBox(height: 8),
                    FeeBanner(
                      fees: fees,
                      busy: _busy,
                      onPay: () => _act(() => widget.api.payFees()),
                    ),
                  ],
                  if (offer != null && ride == null && _offerLeft > 0) ...[
                    const SizedBox(height: 8),
                    OfferCard(
                      offer: offer,
                      secondsLeft: _offerLeft,
                      busy: _busy,
                      onAccept: () => _act(() => widget.api.accept(offer.rideId)),
                      onPass: () => _act(() => widget.api.decline(offer.rideId)),
                    ),
                  ],
                ],
              ),
            ),
          ),

          // The working sheet.
          Align(
            alignment: Alignment.bottomCenter,
            child: RidePanel(
              state: _state,
              busy: _busy,
              error: _error,
              onAccept: (id) => _act(() => widget.api.accept(id)),
              onArrived: (id) => _act(() => widget.api.arrived(id)),
              onComplete: (id) => _act(() => widget.api.complete(id)),
              onDenyCash: (id) => _act(() => widget.api.denyCash(id)),
              onRate: (id, stars) => _act(() => widget.api.ratePassenger(id, stars)),
              onHandBack: (id) => _act(() => widget.api.handBack(id)),
              onGoOnline: () => _act(() => widget.api.setOnline(true)),
              onCall: _call,
              onSaveProfile: (plate, brand, legalName) =>
                  _act(() => widget.api.saveProfile(
                        plateNumber: plate,
                        brandModel: brand,
                        legalName: legalName,
                      )),
              onOpenMoney: _openMoney,
              onOpenSettings: _openSettings,
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip({required IconData icon, required String label}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: Brand.black.withValues(alpha: 0.94),
          border: Border.all(color: Brand.line),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: Brand.orange),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label.toUpperCase(),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Brand.text,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _onlineButton() {
    final online = _online;
    final blocked = _ride != null || _profile == null;
    return GestureDetector(
      onTap: blocked || _busy ? null : () => _act(() => widget.api.setOnline(!online)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        decoration: BoxDecoration(
          color: Brand.black.withValues(alpha: 0.94),
          border: Border.all(color: online ? const Color(0xFF14532D) : Brand.line),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.power_settings_new, size: 13, color: online ? Brand.green : Brand.muted),
            const SizedBox(width: 6),
            Text(
              online ? t('drive.online') : t('drive.offline'),
              style: TextStyle(
                color: online ? Brand.green : Brand.muted,
                fontSize: 10,
                fontWeight: FontWeight.w900,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openMoney() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MoneyScreen(api: widget.api, fees: _state?.fees),
    ));
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SettingsScreen(
        api: widget.api,
        profile: _profile,
        onSignedOut: widget.onSignedOut,
      ),
    ));
    _refresh();
  }
}
