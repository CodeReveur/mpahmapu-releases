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
import '../navigator.dart';
import '../permissions.dart';
import '../routing.dart' as nav;
import '../theme.dart';
import '../updater.dart';
import '../widgets/fee_banner.dart';
import '../widgets/language_button.dart';
import '../widgets/map_layers.dart';
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
  final VoidCallback? onSwitchToPassenger;
  const DriveScreen({
    super.key,
    required this.api,
    required this.onSignedOut,
    this.onSwitchToPassenger,
  });

  @override
  State<DriveScreen> createState() => _DriveScreenState();
}

class _DriveScreenState extends State<DriveScreen> with WidgetsBindingObserver {
  static const _pollInterval = Duration(seconds: 3);
  static const _heartbeatInterval = Duration(seconds: 3);
  static final _kigali = LatLng(-1.9441, 30.0619);

  final _map = MapController();
  final _ring = AudioPlayer();
  final _bellPlayer = AudioPlayer();
  final _nav = TurnByTurn();

  /// Streets by default here, unlike the passenger side: a motari is following
  /// a road, and a road is easier to follow drawn than photographed. Satellite
  /// is one tap away for the last hundred metres, where a compound gate or a
  /// track off the tarmac is the thing they are actually looking for.
  Basemap _basemap = Basemap.streets;

  /// The road to the next thing, and what it was worked out from. Both are
  /// remembered so a route is refetched when it stops being about this ride
  /// rather than on a timer.
  nav.Route? _route;
  LatLng? _routeTo;
  LatLng? _routedFrom;
  bool _routing = false;

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
  DateTime? _lastPassengerBellAt;
  bool _framed = false;

  MotariProfile? get _profile => _state?.profile;
  Ride? get _ride => _state?.activeRide;
  Offer? get _offer => _state?.offer;
  bool get isMandatoryOnlineHours {
    final now = DateTime.now().toUtc();
    final kigaliHour = (now.hour + 2) % 24;
    return kigaliHour >= 5 && kigaliHour < 21;
  }

  bool get _online => isMandatoryOnlineHours || (_profile?.online ?? false);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppUpdater.onOfferAction = _handleNativeOfferAction;
    _checkPendingNativeOfferAction();
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
    if (AppUpdater.onOfferAction == _handleNativeOfferAction) {
      AppUpdater.onOfferAction = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _heartbeat?.cancel();
    _tick?.cancel();
    _positions?.cancel();
    _ring.dispose();
    _bellPlayer.dispose();
    _nav.stop();
    Permissions.clearOffer(_offerNotificationId);
    AppUpdater.dismissIncomingOfferCall();
    super.dispose();
  }

  Future<void> _checkPendingNativeOfferAction() async {
    final pending = await AppUpdater.consumePendingOfferAction();
    if (pending != null) {
      _handleNativeOfferAction(pending['action']!, pending['rideId']!);
    }
  }

  void _handleNativeOfferAction(String action, String rideId) {
    if (!mounted) return;
    _ringingFor = null;
    _ring.stop();
    Permissions.clearOffer(_offerNotificationId);
    // OfferActionReceiver already posts to the backend, and we also refresh/act
    // here so the UI immediately transitions onto the accepted ride or clears the offer.
    if (action == 'accept') {
      _act(() => widget.api.accept(rideId)).whenComplete(_refresh);
    } else {
      _act(() => widget.api.decline(rideId)).whenComplete(_refresh);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the app should show the truth immediately, not in five
    // seconds: a ride may have been reassigned while it was in the background.
    if (state == AppLifecycleState.resumed) {
      _checkPendingNativeOfferAction();
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
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
      ),
    ).listen((p) {
      if (!mounted) return;
      // Zero-error exact coordinate tracking: keep tight fixes so GPS drift is rejected.
      if (_position == null || p.accuracy <= 35.0 || p.accuracy <= _position!.accuracy) {
        setState(() => _position = p);
        if (!_framed) {
          _framed = true;
          _map.move(LatLng(p.latitude, p.longitude), 16);
        }
        _follow(LatLng(p.latitude, p.longitude));
      }
    });
  }

  /* ── the way there ─────────────────────────────────────────────────────── */

  /// Where this ride is going next: the passenger until they are aboard, the
  /// destination once they are. A parcel counts as aboard from the moment it
  /// was collected.
  LatLng? get _heading {
    final ride = _ride;
    if (ride == null) return null;
    final aboard = ride.status == 'IN_RIDE' || ride.pickedUpAt != null;
    if (aboard && ride.destLat != null && ride.destLng != null) {
      return LatLng(ride.destLat!, ride.destLng!);
    }
    return LatLng(ride.pickupLat, ride.pickupLng);
  }

  /// A new fix arrived. Keep the drawn road honest, and say the turn if this
  /// position has earned it.
  Future<void> _follow(LatLng at) async {
    final to = _heading;

    // No ride, or it ended: drop the line rather than leave a stale one drawn.
    if (to == null) {
      if (_route != null || _nav.next != null) {
        _nav.reset();
        if (mounted) {
          setState(() {
            _route = null;
            _routeTo = null;
            _routedFrom = null;
          });
        }
      }
      return;
    }

    // Worth asking again when the destination changed, when there is no road
    // yet, or when we have moved far enough that the old one may be wrong,
    // which is also what happens after a missed turn.
    final movedFar = _routedFrom == null || nav.metresBetween(_routedFrom!, at) > 120;
    final newTarget = _routeTo == null || nav.metresBetween(_routeTo!, to) > 30;
    if (!_routing && (newTarget || _route == null || movedFar)) {
      _routing = true;
      if (newTarget) _nav.reset();
      final found = await nav.Routing.between(at, to);
      _routing = false;
      if (!mounted) return;
      // A lookup that failed leaves the last good road on screen: an old line
      // is better guidance than none, and the pin has not moved.
      if (found != null) {
        setState(() {
          _route = found;
          _routeTo = to;
          _routedFrom = at;
        });
      } else if (newTarget) {
        setState(() => _routeTo = to);
      }
    }

    await _nav.update(_route, at);
    if (mounted) setState(() {});
  }

  /// How tight a fix has to be before it is worth telling passengers about.
  ///
  /// Generous: a motari on a phone in a street beats this by an order of
  /// magnitude, and the ones who do not are indoors, where the position is a
  /// guess at the neighbourhood rather than the corner they are standing on.
  static const double _usableFixM = 500;

  /// Whether the last fix is good enough to dispatch on.
  bool get _fixUsable {
    final p = _position;
    return p != null && p.accuracy <= _usableFixM;
  }

  Future<void> _sendHeartbeat() async {
    final p = _position;
    if (p == null || !_online || !_fixUsable) return;
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
    setMapProviderFromConfig(next.mapProvider);
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
    if (isMandatoryOnlineHours && next.profile != null && !next.profile!.online && !_busy) {
      widget.api.setOnline(true).then((s) {
        if (mounted) setState(() => _state = s);
      }).catchError((_) {});
    }
    AppUpdater.startBackgroundService(online: _online);
    _updateRinging(offer);
    _checkPassengerBell(next.activeRide);
  }

  Future<void> _checkPassengerBell(Ride? ride) async {
    if (ride == null || ride.lastRingAt == null || ride.lastRingBy != 'PASSENGER') return;
    if (_lastPassengerBellAt != null && !ride.lastRingAt!.isAfter(_lastPassengerBellAt!)) {
      return;
    }
    _lastPassengerBellAt = ride.lastRingAt;
    await Permissions.showAlertNotification(
      id: 77,
      title: '🔔 ${ride.passengerName} is ringing you!',
      body: 'Passenger rang your bell at ${ride.pickupName ?? "pickup location"}.',
    );
    try {
      await _bellPlayer.stop();
      await _bellPlayer.setReleaseMode(ReleaseMode.stop);
      await _bellPlayer.play(AssetSource('audio/incoming-ride.wav'));
    } catch (_) {}
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Brand.orange,
          content: Text(
            '🔔 ${ride.passengerName} rang your bell!',
            style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w900),
          ),
        ),
      );
    }
  }

  /// A live offer rings for its whole window, like a phone call: a parcel with
  /// the delivery tone, a passenger with the ride tone.
  Future<void> _updateRinging(Offer? offer) async {
    final shouldRing = offer != null && _ride == null && _offerLeft > 0;
    if (shouldRing) {
      if (_ringingFor == offer.rideId) return;
      _ringingFor = offer.rideId;
      await AppUpdater.showIncomingOfferCall(offer);
      AppUpdater.bringToFront();
      final asset = offer.isCourier ? 'audio/incoming-delivery.wav' : 'audio/incoming-ride.wav';
      await _ring.stop();
      await _ring.setReleaseMode(ReleaseMode.loop);
      await _ring.play(AssetSource(asset));
    } else if (_ringingFor != null) {
      _ringingFor = null;
      await _ring.stop();
      await Permissions.clearOffer(_offerNotificationId);
      await AppUpdater.dismissIncomingOfferCall();
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
              basemapTiles(_basemap),
              if (_route != null)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _route!.line,
                      strokeWidth: 5,
                      color: Brand.orange,
                      borderStrokeWidth: 2,
                      borderColor: Brand.black,
                    ),
                  ],
                ),
              MarkerLayer(markers: _markers()),
            ],
          ),

          // Top Bar: Plate (left), Language (center), Online switch (right)
          Positioned(
            top: MediaQuery.of(context).padding.top + 12,
            left: 14,
            right: 14,
            child: SizedBox(
              height: 34,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _chip(
                      icon: Icons.two_wheeler,
                      label: _profile?.plateNumber ?? t('drive.no_plate'),
                    ),
                  ),
                  const LanguageButton(),
                  if (!isMandatoryOnlineHours)
                    Align(
                      alignment: Alignment.centerRight,
                      child: _onlineButton(),
                    ),
                ],
              ),
            ),
          ),

          // Top Banners (GPS warning, Navigation turns, Fees, Incoming Offer)
          Positioned(
            top: MediaQuery.of(context).padding.top + 54,
            left: 14,
            right: 14,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!_fixUsable && _position != null) ...[
                  _gpsCoarseBanner(),
                  const SizedBox(height: 8),
                ],
                if (ride != null) ...[
                  _turnBanner(),
                  const SizedBox(height: 8),
                ],
                if (showFee) ...[
                  FeeBanner(
                    fees: fees,
                    busy: _busy,
                    onPay: () => _act(() => widget.api.payFees()),
                  ),
                  const SizedBox(height: 8),
                ],
                if (offer != null && ride == null && _offerLeft > 0) ...[
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

          // Floating controls + the working sheet anchored together at the bottom.
          Align(
            alignment: Alignment.bottomCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const UpdateBanner(),
                      Row(
                        children: [
                          const Spacer(),
                          MapCredit(map: _basemap),
                          const SizedBox(width: 8),
                          if (ride != null) ...[
                            _voiceButton(),
                            const SizedBox(width: 6),
                          ],
                          BasemapButton(
                            value: _basemap,
                            onChanged: (m) => setState(() => _basemap = m),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                RidePanel(
                  state: _state,
                  busy: _busy,
                  error: _error,
                  onAccept: (id) => _act(() => widget.api.accept(id)),
                  onArrived: (id) => _act(() => widget.api.arrived(id)),
                  onComplete: (id) => _act(() => widget.api.complete(id)),
                  onParcelReceived: (id) => _act(() => widget.api.parcelReceived(id)),
                  onParcelDelivered: (id) => _act(() => widget.api.parcelDelivered(id)),
                  onConfirmCash: (id) => _act(() => widget.api.paid(id, 'CASH')),
                  onDenyCash: (id) => _act(() => widget.api.denyCash(id)),
                  onRingPassenger: (id) => _act(() => widget.api.ringPassenger(id)),
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
                  onOpenTrips: () => _openMoney(focusTrips: true),
                  onOpenSettings: _openSettings,
                ),
              ],
            ),
          ),

          // Centered Modal when Passenger declares Cash Payment
          if (ride != null && ride.cashDeclaredAt != null && ride.paymentStatus != 'PAID')
            Positioned.fill(
              child: _cashConfirmModalOverlay(ride),
            ),
        ],
      ),
    );
  }

  Widget _cashConfirmModalOverlay(Ride ride) {
    final fare = ride.fareRwf;
    return Container(
      color: Colors.black.withValues(alpha: 0.88),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      alignment: Alignment.center,
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxWidth: 400),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 28),
        decoration: BoxDecoration(
          color: const Color(0xFF0E0E0E),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Brand.amber, width: 1.5),
          boxShadow: const [BoxShadow(color: Colors.black, blurRadius: 40)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                color: Brand.amber.withValues(alpha: 0.16),
                shape: BoxShape.circle,
                border: Border.all(color: Brand.amber, width: 2),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.payments_outlined, color: Brand.amber, size: 30),
            ),
            const SizedBox(height: 14),
            Text(
              t('ride.cash_confirm_title').toUpperCase(),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Brand.amber,
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
              ),
            ),
            if (fare != null) ...[
              const SizedBox(height: 8),
              Text(
                rwf(fare),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              t('ride.cash_confirm_body'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFFDDDDDD),
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _busy ? null : () => _act(() => widget.api.paid(ride.id, 'CASH')),
                icon: const Icon(Icons.check_circle, size: 18, color: Colors.black),
                label: Text(
                  t('ride.confirm_cash_btn'),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.4,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Brand.green,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _busy ? null : () => _act(() => widget.api.denyCash(ride.id)),
                icon: const Icon(Icons.cancel_outlined, size: 18, color: Brand.red),
                label: Text(
                  t('ride.decline_cash_btn'),
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Brand.red,
                  side: const BorderSide(color: Color(0xFF7F1D1D), width: 1.5),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _gpsCoarseBanner() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: const Color(0xFF161616).withValues(alpha: 0.96),
          border: Border.all(color: const Color(0xFF7C3A10)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          t('drive.gps_coarse'),
          style: const TextStyle(
            color: Color(0xFFFBBF24),
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      );

  Widget _chip({required IconData icon, required String label}) => Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Brand.black.withValues(alpha: 0.94),
          border: Border.all(color: Brand.line),
          borderRadius: BorderRadius.circular(10),
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
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ],
        ),
      );

  /// The next manoeuvre, written out. It says the same words the voice says,
  /// so a motari who missed the sound can read it at the next stop, and one
  /// who heard it has the distance in front of them.
  Widget _turnBanner() {
    final turn = _nav.next;
    final where = _heading;

    // Between accepting and the first route coming back there is nothing to
    // draw. Say what is happening rather than leave a gap.
    if (turn == null) {
      final ride = _ride!;
      final aboard = ride.status == 'IN_RIDE' || ride.pickedUpAt != null;
      return _navCard(
        icon: Icons.navigation_outlined,
        headline: aboard ? t('nav.to_dest') : t('nav.to_pickup'),
        detail: _route == null && where != null && !_routing ? t('nav.no_route') : null,
      );
    }

    return _navCard(
      icon: _turnIcon(turn.step),
      headline: turn.step.spoken,
      detail: turn.metresAway >= 1000
          ? km(turn.metresAway)
          : '${(turn.metresAway / 10).round() * 10} m',
    );
  }

  Widget _navCard({required IconData icon, required String headline, String? detail}) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        decoration: BoxDecoration(
          color: Brand.black.withValues(alpha: 0.94),
          border: Border.all(color: Brand.line),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(icon, size: 21, color: Brand.orange),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    headline,
                    style: const TextStyle(
                      color: Brand.text,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                      height: 1.25,
                    ),
                  ),
                  if (detail != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      style: const TextStyle(color: Brand.muted, fontSize: 11.5, height: 1.35),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );

  /// An arrow that matches the words, so the shape is readable at a glance
  /// without reading anything.
  IconData _turnIcon(nav.RouteStep step) {
    if (step.type == 'arrive') return Icons.flag;
    if (step.type == 'roundabout' || step.type == 'rotary') return Icons.roundabout_right;
    final mod = step.modifier.toLowerCase();
    if (mod.contains('uturn')) return Icons.u_turn_left;
    if (mod.contains('sharp') && mod.contains('left')) return Icons.turn_sharp_left;
    if (mod.contains('sharp') && mod.contains('right')) return Icons.turn_sharp_right;
    if (mod.contains('slight') && mod.contains('left')) return Icons.turn_slight_left;
    if (mod.contains('slight') && mod.contains('right')) return Icons.turn_slight_right;
    if (mod.contains('left')) return Icons.turn_left;
    if (mod.contains('right')) return Icons.turn_right;
    return Icons.straight;
  }

  /// Silence, for a motari who would rather not be spoken to. It only stops the
  /// voice: the banner keeps showing the turn either way.
  Widget _voiceButton() {
    final on = !_nav.muted;
    return GestureDetector(
      onTap: () {
        setState(() => _nav.muted = on);
        if (!on) {
          // Turned back on: pick the voice up again in case the language
          // changed while it was silent.
          _nav.relearnVoice();
        } else {
          _nav.stop();
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: Brand.black.withValues(alpha: 0.94),
          border: Border.all(color: on ? Brand.orange : Brand.line),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(on ? Icons.volume_up : Icons.volume_off,
                size: 12, color: on ? Brand.orange : Brand.muted),
            const SizedBox(width: 5),
            Text(
              on ? t('nav.sound_on') : t('nav.sound_off'),
              style: TextStyle(
                color: on ? Brand.text : Brand.muted,
                fontSize: 9.5,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.9,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _onlineButton() {
    if (isMandatoryOnlineHours) {
      return const SizedBox.shrink();
    }
    final online = _online;
    final blocked = _ride != null || _profile == null;
    return GestureDetector(
      onTap: blocked || _busy ? null : () => _act(() => widget.api.setOnline(!online)),
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Brand.black.withValues(alpha: 0.94),
          border: Border.all(color: online ? const Color(0xFF14532D) : Brand.line),
          borderRadius: BorderRadius.circular(10),
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
                letterSpacing: 0.8,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openMoney({bool focusTrips = false}) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MoneyScreen(
        api: widget.api,
        fees: _state?.fees,
        focusTrips: focusTrips,
      ),
    ));
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SettingsScreen(
        api: widget.api,
        profile: _profile,
        onSignedOut: widget.onSignedOut,
        onSwitchToPassenger: widget.onSwitchToPassenger,
      ),
    ));
    // Logging out clears the session on the way back through here; there is
    // nothing left to ask the driver API for.
    if (mounted && widget.api.signedIn) _refresh();
  }
}
