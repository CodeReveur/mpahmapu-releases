import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../i18n.dart';
import '../models.dart';
import '../routing.dart' show metresBetween;
import '../permissions.dart';
import '../theme.dart';
import '../widgets/language_button.dart';
import '../widgets/map_layers.dart';

/// Asking for a motari, and watching one arrive.
///
/// No account: a name and a phone number are the whole of it. The ride is held
/// by a token kept on the device, so closing the app and coming back lands the
/// passenger straight back on the ride they already have.
class RideScreen extends StatefulWidget {
  final Api api;
  final VoidCallback onDrive;
  const RideScreen({super.key, required this.api, required this.onDrive});

  @override
  State<RideScreen> createState() => _RideScreenState();
}

/// Which of the two place fields the type-ahead is serving.
enum _Field { pickup, dest }

/// What no trip may be priced under, before the server has said otherwise.
const int _kFloorRwf = 500;

const _kigali = LatLng(-1.9441, 30.0619);
const _tokenKey = 'passenger.ride.token';
const _phoneKey = 'passenger.phone';

class _RideScreenState extends State<RideScreen> with WidgetsBindingObserver {
  final _map = MapController();
  final _phone = TextEditingController();
  final _pickupText = TextEditingController();
  final _destText = TextEditingController();
  final _fare = TextEditingController();
  final _parcelNote = TextEditingController();

  Position? _device;
  bool _framed = false;
  StreamSubscription<Position>? _positions;

  /// Where the motari is being asked to come. The device fix sets it when there
  /// is one; a tap on the map or a typed place moves it. On a phone that never
  /// gets a fix, typing is the only way there is, which is why the field exists.
  LatLng? _pickup;
  String? _pickupName;

  Place? _dest;

  /// Type-ahead runs for whichever field is being typed in. Two independent
  /// searches would be two of everything, so one set of state serves both and
  /// remembers which field it belongs to.
  _Field _field = _Field.dest;
  List<Place> _found = const [];
  Timer? _searchDebounce;
  bool _searching = false;

  /// True once the passenger has touched the amount, after which a new quote
  /// stops overwriting what they typed.
  bool _fareTouched = false;

  /// The sheet folded down so the map can be seen.
  bool _minimised = false;
  bool _menuOpen = false;




  /// Looking up the name of the phone's own fix.
  bool _locating = false;

  /// Streets or satellite. A passenger describing where they are standing has
  /// an easier time on satellite — a roof, a yard, the shape of a junction —
  /// so it is one tap away rather than buried.
  Basemap _basemap = Basemap.satellite;

  String _kind = 'RIDE';
  Quote? _quote;
  Supply? _supply;

  PassengerRide? _ride;
  Timer? _poll;
  Timer? _beat;

  bool _busy = false;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restore();
    _watchPosition();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _positions?.cancel();
    _poll?.cancel();
    _beat?.cancel();
    _searchDebounce?.cancel();
    _phone.dispose();
    _pickupText.dispose();
    _destText.dispose();
    _fare.dispose();
    _parcelNote.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _ride != null) _refresh();
  }

  /* ── what this device already knows ───────────────────────────────────── */

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    _phone.text = prefs.getString(_phoneKey) ?? '';
    final token = prefs.getString(_tokenKey);
    if (token != null) {
      try {
        final ride = await widget.api.trackRide(token);
        // A ride that is over should not greet them on the next launch.
        if (!ride.done) {
          _hold(ride);
        } else {
          await prefs.remove(_tokenKey);
        }
      } catch (_) {
        await prefs.remove(_tokenKey);
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _remember() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_phoneKey, _phone.text.trim());
  }

  /* ── location ─────────────────────────────────────────────────────────── */

  Future<void> _watchPosition() async {
    final access = await Permissions.requestLocation();
    if (!access.ok) return;
    _positions = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen((p) {
      if (!mounted) return;

      /*
       * Every reading is kept, however coarse.
       *
       * Anything worse than five kilometres used to be dropped as "a network
       * guess, not GPS", which is true, and throwing it away meant the map
       * never centred and the passenger never saw themselves on it. A coarse
       * fix drawn inside its accuracy ring is honest. A coarse fix discarded
       * looks like a broken app.
       */
      // Keep the better of what we have and what just arrived, so a stray
      // coarse reading cannot throw away a good one. Something no worse than
      // half as good still wins, because the passenger does move.
      if (_device == null || p.accuracy <= _bestAccuracy * 2) {
        if (p.accuracy < _bestAccuracy) _bestAccuracy = p.accuracy;
        setState(() => _device = p);
      }
      if (!_framed) {
        _framed = true;
        _map.move(LatLng(p.latitude, p.longitude), 16);
      }
      _autoLocate(p);
    });
  }

  /// How tight a fix has to be before a pickup pin is put on it.
  ///
  /// Twenty five metres, not two hundred. Two hundred was enough to name the
  /// wrong street: Kigali's KK and KG districts meet along roads narrower than
  /// that, so a fix well inside its own stated accuracy could still be
  /// reverse geocoded to the wrong side of a junction and tell a passenger
  /// standing on KK that they were on KG. A phone outdoors reaches this in a
  /// few seconds.
  ///
  /// A coarser reading is still drawn; what it does not get is a name and a
  /// pin. Sending a motari to the middle of a five kilometre circle wastes
  /// the trip for both of them.
  static const double _trustworthyM = 25;

  /// The tightest fix seen so far.
  ///
  /// Readings arrive worst first: the phone answers from the network while the
  /// GPS is still warming up, and wanders afterwards. Taking the latest would
  /// let a good position be replaced by a worse one; taking the best lets the
  /// marker settle instead of jitter.
  double _bestAccuracy = double.infinity;

  /// Whether the pickup has already been filled in from the phone's own fix.
  /// A courtesy is offered once; after that the field is the passenger's.
  bool _autoLocated = false;

  /// Fill the pickup in from the first fix worth standing on.
  ///
  /// Somebody opening this screen wants a moto where they are, and making them
  /// tap to say so is a step with only one answer. It is written into the
  /// field rather than held quietly, so they can read it and change it, and it
  /// never lands on top of a pickup they chose themselves.
  Future<void> _autoLocate(Position p) async {
    if (_autoLocated || _pickup != null || _ride != null) return;
    if (p.accuracy > _trustworthyM) return;
    _autoLocated = true;

    final name = await widget.api.nameOfPlace(p.latitude, p.longitude);
    // They may have typed something while the name was on its way.
    if (!mounted || _pickup != null) return;
    setState(() {
      _pickup = LatLng(p.latitude, p.longitude);
      _pickupName = name;
      _pickupText.text = name ?? '';
    });
    _refreshQuote();
  }

  /* ── the fare, and how much moto is around ────────────────────────────── */

  Future<void> _refreshQuote() async {
    final at = _pickup;
    if (at == null) return;
    try {
      final quote = await widget.api.quote(
        pickupLat: at.latitude,
        pickupLng: at.longitude,
        destLat: _dest?.latitude,
        destLng: _dest?.longitude,
        kind: _kind,
      );
      final supply = await widget.api.supply(at.latitude, at.longitude, kind: _kind);
      if (!mounted) return;
      setState(() {
        _quote = quote;
        _supply = supply;
        // The fare is always the passenger's to name, but when there is a route
        // to price, the app opens with that price already in the box rather
        // than an empty one.
        if (!_fareTouched && quote.quotedFareRwf != null && _measurable) {
          _fare.text = '${quote.quotedFareRwf}';
        }
      });
    } catch (_) {
      // A missing quote is not worth an error: the rate card shows instead.
    }
  }

  /* ── typing a destination ─────────────────────────────────────────────── */

  void _onTyped(_Field field, String value) {
    _searchDebounce?.cancel();
    setState(() {
      _field = field;
      // Typing past a chosen place means they want a different one.
      if (field == _Field.dest && _dest != null && value.trim() != _dest!.label) {
        _dest = null;
      }
      if (field == _Field.pickup && _pickupName != null && value.trim() != _pickupName) {
        _pickupName = null;
      }
    });
    if (value.trim().length < 2) {
      setState(() { _found = const []; _searching = false; });
      return;
    }
    setState(() => _searching = true);
    _searchDebounce = Timer(const Duration(milliseconds: 350), () async {
      final results = await widget.api.searchPlaces(
        value,
        // Bias to the device if there is one, otherwise to the pickup they have
        // already set, otherwise not at all.
        lat: _device?.latitude ?? _pickup?.latitude,
        lng: _device?.longitude ?? _pickup?.longitude,
      );
      if (!mounted) return;
      setState(() { _found = results; _searching = false; });
    });
  }

  void _pick(Place place) {
    FocusScope.of(context).unfocus();
    setState(() {
      if (_field == _Field.pickup) {
        _pickup = LatLng(place.latitude, place.longitude);
        _pickupName = place.label;
        _pickupText.text = place.label;
        _map.move(_pickup!, 16);
      } else {
        _dest = place;
        _destText.text = place.label;
      }
      _found = const [];
    });
    _refreshQuote();
  }

  bool get _measurable => _dest != null;

  /* ── asking ───────────────────────────────────────────────────────────── */

  bool get _canRequest {
    // Without a pickup there is nowhere to send anyone. A device fix gives one;
    // so does typing a place or tapping the map.
    if (_busy || _pickup == null) return false;
    if (!RegExp(r'^07\d{8}$').hasMatch(_phone.text.trim())) return false;
    // A parcel always needs somewhere to go.
    if (_kind == 'COURIER' && _destText.text.trim().isEmpty) return false;
    // Every request carries a price. A motari should never be asked to guess
    // what a trip is worth, and a passenger should never be surprised by it.
    final named = _namedFare;
    if (named == null || named < _minFare) return false;
    return true;
  }

  int? get _namedFare {
    final v = int.tryParse(_fare.text.trim());
    if (v == null || v <= 0) return null;
    return v;
  }

  /// The floor for this kind of trip. A parcel's is higher than a ride's,
  /// because the motari makes the whole journey for it. The server is the
  /// authority, but until it has answered the field still holds the floor: an
  /// unanswered quote must never let a fare through under it.
  int get _minFare => _supply?.minFareRwf ?? _quote?.minFareRwf ?? _kFloorRwf;

  Future<void> _request() async {
    if (!_canRequest) return;
    setState(() { _busy = true; _error = null; });
    try {
      final at = _pickup!;
      final ride = await widget.api.requestRide(
        name: 'Passenger',
        phone: _phone.text.trim(),
        pickupLat: at.latitude,
        pickupLng: at.longitude,
        pickupName: _pickupName,
        destLat: _dest?.latitude,
        destLng: _dest?.longitude,
        destName: _dest?.label ??
            (_destText.text.trim().isEmpty ? null : _destText.text.trim()),
        kind: _kind,
        parcelNote: _kind == 'COURIER' && _parcelNote.text.trim().isNotEmpty
            ? _parcelNote.text.trim()
            : null,
        offeredFareRwf: _namedFare,
      );
      await _remember();
      final prefs = await SharedPreferences.getInstance();
      if (ride.token != null) await prefs.setString(_tokenKey, ride.token!);
      _hold(ride);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = t('common.error'));
    }
    if (mounted) setState(() => _busy = false);
  }

  /* ── watching it happen ───────────────────────────────────────────────── */

  /// Take hold of a live ride: poll it, and report this phone's position so the
  /// ride can start itself when passenger and motari move off together.
  void _hold(PassengerRide ride) {
    if (!mounted) return;
    setState(() => _ride = ride);
    _poll?.cancel();
    _beat?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
    _beat = Timer.periodic(const Duration(seconds: 8), (_) => _sendPosition());
    if (ride.driver?.latitude != null) _frameRide(ride);
  }

  void _release() {
    _poll?.cancel();
    _beat?.cancel();
    _poll = null;
    _beat = null;
  }

  Future<void> _refresh() async {
    final token = _ride?.token;
    if (token == null) return;
    try {
      final next = await widget.api.trackRide(token);
      if (!mounted) return;
      setState(() => _ride = next);
      if (next.done) {
        _release();
        // A finished ride still shows until they dismiss it, but nothing on
        // this device should hold onto it after that.
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_tokenKey);
      }
    } catch (_) {
      // A dropped poll is normal on a phone in a pocket; the next one carries.
    }
  }

  Future<void> _sendPosition() async {
    final token = _ride?.token;
    final at = _device;
    if (token == null || at == null || !(_ride?.live ?? false)) return;
    try {
      await widget.api.sendPosition(token, at.latitude, at.longitude);
    } catch (_) {
      // Same: the next beat carries.
    }
  }

  void _frameRide(PassengerRide ride) {
    final driver = ride.driver;
    if (driver?.latitude == null || driver?.longitude == null) return;
    final a = LatLng(ride.pickupLat, ride.pickupLng);
    final b = LatLng(driver!.latitude!, driver.longitude!);
    _map.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds(a, b),
      padding: const EdgeInsets.fromLTRB(50, 90, 50, 260),
    ));
  }

  Future<void> _act(Future<PassengerRide> Function() action) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      final next = await action();
      if (mounted) setState(() => _ride = next);
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

  void _startOver() {
    _release();
    setState(() {
      _ride = null;
      _dest = null;
      _destText.clear();
      _fare.clear();
      _found = const [];
      _error = null;
      _fareTouched = false;
      _minimised = false;
    });
    _refreshQuote();
  }

  /* ── build ────────────────────────────────────────────────────────────── */

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: Brand.orange)),
      );
    }

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _pickup ?? _kigali,
              initialZoom: 14,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
              // Before a ride exists, the map is how you move the pickup.
              onTap: _ride == null
                  ? (_, point) async {
                      setState(() {
                        _pickup = point;
                        _pickupName = null;
                      });
                      _refreshQuote();
                      // Name it, so the answered line reads as a place.
                      final name =
                          await widget.api.nameOfPlace(point.latitude, point.longitude);
                      if (mounted && name != null) {
                        setState(() {
                          _pickupName = name;
                          _pickupText.text = name;
                        });
                      }
                    }
                  : null,
            ),
            children: [
              basemapTiles(_basemap),
              MarkerLayer(markers: _markers()),
            ],
          ),

          // Top Bar: Hamburger Menu (left), Brand Chip (center), Language (right)
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _hamburgerMenuButton(),
                  ),
                  _brandChip(),
                  Align(
                    alignment: Alignment.centerRight,
                    child: const LanguageButton(),
                  ),
                ],
              ),
            ),
          ),

          // Menu Dropdown if open
          if (_menuOpen)
            Positioned(
              top: MediaQuery.of(context).padding.top + 48,
              left: 14,
              child: _menuDropdown(),
            ),

          // Floating controls right above the sheet: Supply (left), Basemap & MapCredit (right)
          Positioned(
            left: 14,
            right: 14,
            bottom: (_minimised ? 56 : MediaQuery.of(context).size.height * 0.58) + 12,
            child: Row(
              children: [
                if (_supply != null && _ride == null) _supplyChip(),
                const Spacer(),
                MapCredit(map: _basemap),
                const SizedBox(width: 8),
                BasemapButton(
                  value: _basemap,
                  onChanged: (m) => setState(() => _basemap = m),
                ),
              ],
            ),
          ),

          Align(
            alignment: Alignment.bottomCenter,
            child: _sheet(),
          ),
        ],
      ),
    );
  }

  List<Marker> _markers() {
    final markers = <Marker>[];
    final ride = _ride;
    final pickup = ride == null ? _pickup : LatLng(ride.pickupLat, ride.pickupLng);

    // The pickup, unless it is simply where the passenger is standing, in
    // which case the blue person below already marks the spot. Two markers on
    // one point read as two people, and say nothing the one did not.
    final here = _device;
    final pickupIsHere = pickup != null &&
        here != null &&
        ride == null &&
        metresBetween(pickup, LatLng(here.latitude, here.longitude)) < 25;

    if (pickup != null && !pickupIsHere) {
      markers.add(_pin(pickup, Brand.orange, Icons.person));
    }
    final destLat = ride?.destLat ?? _dest?.latitude;
    final destLng = ride?.destLng ?? _dest?.longitude;
    if (destLat != null && destLng != null) {
      markers.add(_pin(LatLng(destLat, destLng), Brand.green, Icons.flag));
    }
    // Where the phone thinks it is. Drawn under the pins, because a chosen
    // pickup outranks a guess at one, and only while there is no ride: once a
    // motari is coming, the two things worth watching are them and the pin.
    final device = _device;
    if (device != null && ride == null) {
      markers.add(Marker(
        point: LatLng(device.latitude, device.longitude),
        width: 30,
        height: 30,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF3B82F6),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 7)],
          ),
          child: const Icon(Icons.person, color: Colors.white, size: 15),
        ),
      ));
    }

    final driver = ride?.driver;
    if (driver?.latitude != null && driver?.longitude != null) {
      markers.add(Marker(
        point: LatLng(driver!.latitude!, driver.longitude!),
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

  Widget _supplyChip() {
    final supply = _supply!;
    final near = supply.nearestM;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: Brand.black.withValues(alpha: 0.94),
        border: Border.all(color: supply.active > 0 ? const Color(0xFF14532D) : Brand.line),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.two_wheeler, size: 12, color: supply.active > 0 ? Brand.green : Brand.dim),
          const SizedBox(width: 6),
          Text(
            supply.active == 0
                ? t('ask.none_around')
                : near == null
                    ? t('ask.around', {'count': supply.active})
                    : t('ask.nearest', {'count': supply.active, 'distance': km(near)}),
            style: TextStyle(
              color: supply.active > 0 ? Brand.text : Brand.muted,
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _brandChip() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xFF121212).withValues(alpha: 0.96),
          border: Border.all(color: const Color(0xFF2E2E2E)),
          borderRadius: BorderRadius.circular(999),
          boxShadow: const [
            BoxShadow(color: Colors.black54, blurRadius: 16, offset: Offset(0, 4)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.two_wheeler, size: 12, color: Brand.orange),
            const SizedBox(width: 6),
            Text(
              t('app.name').toUpperCase(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 9.5,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.0,
              ),
            ),
          ],
        ),
      );

  Widget _hamburgerMenuButton() => GestureDetector(
        onTap: () => setState(() => _menuOpen = !_menuOpen),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: const Color(0xFF121212).withValues(alpha: 0.96),
            border: Border.all(color: const Color(0xFF2E2E2E)),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(
            _menuOpen ? Icons.close : Icons.menu,
            size: 14,
            color: const Color(0xFFEEEEEE),
          ),
        ),
      );

  Widget _menuDropdown() => Container(
        width: 175,
        decoration: BoxDecoration(
          color: const Color(0xFF121212).withValues(alpha: 0.96),
          border: Border.all(color: const Color(0xFF2E2E2E)),
          borderRadius: BorderRadius.circular(12),
          boxShadow: const [
            BoxShadow(color: Colors.black87, blurRadius: 24, offset: Offset(0, 8)),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _menuItem(
                icon: Icons.two_wheeler,
                label: t('ask.i_drive'),
                onTap: () {
                  setState(() => _menuOpen = false);
                  widget.onDrive();
                },
              ),
              _menuItem(
                icon: Icons.login,
                label: t('common.nav.signin'),
                onTap: () {
                  setState(() => _menuOpen = false);
                  widget.onDrive();
                },
              ),
              _menuItem(
                icon: Icons.help_outline,
                label: t('common.nav.help'),
                onTap: () {
                  setState(() => _menuOpen = false);
                  _showHelpDialog();
                },
                isLast: true,
              ),
            ],
          ),
        ),
      );

  Widget _menuItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool isLast = false,
  }) =>
      InkWell(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
          decoration: BoxDecoration(
            border: isLast
                ? null
                : const Border(bottom: BorderSide(color: Color(0xFF1F1F1F))),
          ),
          child: Row(
            children: [
              Icon(icon, size: 13, color: Brand.orange),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: Color(0xFFCCCCCC),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141414),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF2C2C2C)),
        ),
        title: Row(
          children: [
            const Icon(Icons.help_outline, color: Brand.orange, size: 20),
            const SizedBox(width: 8),
            Text(t('common.nav.help'),
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Need assistance with a ride or delivery? Contact Ask Motari support:',
              style: TextStyle(color: Color(0xFFCCCCCC), fontSize: 12.5, height: 1.5),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF1C140C),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF4A2810)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.phone, color: Brand.orange, size: 16),
                  const SizedBox(width: 10),
                  const Text('+250 788 000 000',
                      style: TextStyle(color: Brand.orange, fontWeight: FontWeight.w800, fontSize: 13)),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => launchUrl(Uri.parse('tel:+250788000000')),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Brand.orange,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text('CALL',
                          style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 10)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('CLOSE', style: TextStyle(color: Brand.orange, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }

  /* ── the sheet ────────────────────────────────────────────────────────── */

  Widget _sheet() => Container(
        width: double.infinity,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.58,
        ),
        decoration: BoxDecoration(
          color: Brand.black.withValues(alpha: 0.97),
          border: const Border(top: BorderSide(color: Brand.line)),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _handle(),
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    12,
                    0,
                    12,
                    10 + MediaQuery.of(context).viewInsets.bottom,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_minimised)
                        _oneLine()
                      else ...[
                        if (_ride == null) ..._requestForm() else ..._tracking(_ride!),
                        if (_error != null) ...[
                          const SizedBox(height: 10),
                          Text(_error!,
                              style: const TextStyle(color: Brand.red, fontSize: 11.5)),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  /// The grip at the top of the sheet. Dragging it or tapping it puts the sheet
  /// out of the way, because the map underneath is half the point.
  Widget _handle() => GestureDetector(
        onTap: () => setState(() => _minimised = !_minimised),
        onVerticalDragEnd: (details) {
          final v = details.primaryVelocity ?? 0;
          if (v > 120) setState(() => _minimised = true);
          if (v < -120) setState(() => _minimised = false);
        },
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 5, 0, 1),
          child: Column(
            children: [
              Container(
                width: 32,
                height: 3,
                decoration: BoxDecoration(
                  color: const Color(0xFF333333),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 2),
              Icon(
                _minimised ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                size: 17,
                color: Brand.dim,
              ),
            ],
          ),
        ),
      );

  /// What the sheet says when it is out of the way.
  Widget _oneLine() {
    final ride = _ride;
    final text = ride == null
        ? t('ask.request')
        : switch (ride.status) {
            'SEARCHING' => t('track.searching'),
            'ASSIGNED' => t('track.on_the_way'),
            'ARRIVED' => t('track.arrived'),
            'IN_RIDE' => t('track.riding'),
            _ => t('track.completed'),
          };
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          if (ride?.searching ?? false) ...[
            const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 2, color: Brand.orange),
            ),
            const SizedBox(width: 9),
          ],
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Brand.text, fontSize: 12.5, fontWeight: FontWeight.w800),
            ),
          ),
          if (ride?.driver?.plateNumber != null)
            Text(
              ride!.driver!.plateNumber!,
              style: const TextStyle(
                  color: Brand.orange, fontSize: 12, fontWeight: FontWeight.w900),
            ),
        ],
      ),
    );
  }

  /* ── asking, in the order the answers arrive ──────────────────────────── */

  /// A destination taken off the map has a route behind it, so the app can
  /// price it and only asks the passenger to agree. One typed as free text has
  /// nothing to measure, so the price is theirs to set.
  bool get _pricedByRoute => _measurable && (_quote?.quotedFareRwf ?? 0) > 0;

  void _collapse() {
    FocusScope.of(context).unfocus();
    setState(() {
      _found = const [];
    });
  }

  List<Widget> _requestForm() {
    return [
      // 1. Kind tabs (Ride vs Delivery) + active supply counter
      Row(
        children: [
          _kindTab('RIDE', Icons.two_wheeler, t('ask.ride_tab')),
          const SizedBox(width: 6),
          _kindTab('COURIER', Icons.inventory_2_outlined, t('ask.delivery_tab')),
          const Spacer(),
          if (_supply != null)
            Text(
              _supply!.active > 0
                  ? '${_supply!.active} ${t('motari.request.available')}${_supply!.nearestM != null ? ' · ${km(_supply!.nearestM)}' : ''}'
                  : t('ask.none_around'),
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w800,
                color: _supply!.active > 0 ? const Color(0xFF4ADE80) : const Color(0xFF888888),
              ),
            ),
        ],
      ),
      const SizedBox(height: 8),

      // 2. Compact unified route card (From & To)
      _routeCard(),

      // 3. Address suggestions / typed address dropdown
      ..._resultsFor(_field),

      // 4. Parcel note if courier
      if (_kind == 'COURIER') ...[
        const SizedBox(height: 7),
        Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF141414),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF2C2C2C)),
          ),
          child: Row(
            children: [
              const Icon(Icons.inventory_2_outlined, size: 12, color: Brand.orange),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _parcelNote,
                  textCapitalization: TextCapitalization.sentences,
                  style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w500),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    fillColor: Colors.transparent,
                    hintText: t('motari.request.parcel_note'),
                    hintStyle: const TextStyle(color: Color(0xFF888888), fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
      const SizedBox(height: 8),

      // 5. Fare offer & Phone number side-by-side
      _fareAndPhoneRow(),
      const SizedBox(height: 8),

      // 6. Action CTA button (Request Ride / Request Delivery)
      PrimaryButton(
        label: _busy
            ? t('ask.asking')
            : _kind == 'COURIER' ? t('ask.request_delivery') : t('ask.request_ride'),
        icon: _kind == 'COURIER' ? Icons.local_shipping_outlined : Icons.two_wheeler,
        onPressed: _canRequest ? _request : null,
      ),
      const SizedBox(height: 6),
      Text(
        t('ask.footer_trust'),
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Color(0xFF666666),
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    ];
  }

  /* ── compact unified route card (From & To) ────────────────────────── */

  Widget _routeCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF141414),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF2C2C2C)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Pickup row
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Brand.orange,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _pickupText,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                  onTap: () => setState(() => _field = _Field.pickup),
                  onChanged: (v) => _onTyped(_Field.pickup, v),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 4),
                    hintText: t('ask.pickup_location'),
                    hintStyle: const TextStyle(
                      color: Color(0xFF888888),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    fillColor: Colors.transparent,
                  ),
                ),
              ),
              if (_pickupText.text.isNotEmpty)
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _pickupText.clear();
                      _pickup = null;
                      _pickupName = null;
                      _found = const [];
                    });
                    _refreshQuote();
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(Icons.close, size: 13, color: Color(0xFF666666)),
                  ),
                ),
              GestureDetector(
                onTap: _locating ? null : _useMyLocation,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: const Color(0xFF221910),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF4A2810)),
                  ),
                  child: _locating
                      ? const Center(
                          child: SizedBox(
                            width: 11,
                            height: 11,
                            child: CircularProgressIndicator(strokeWidth: 1.5, color: Brand.orange),
                          ),
                        )
                      : const Icon(Icons.my_location, size: 12, color: Brand.orange),
                ),
              ),
            ],
          ),

          // Vertical connector line
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Container(
                  margin: const EdgeInsets.only(left: 3),
                  width: 2,
                  height: 10,
                  color: const Color(0xFF333333),
                ),
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.only(left: 10),
                    height: 1,
                    color: const Color(0xFF222222),
                  ),
                ),
              ],
            ),
          ),

          // Destination row
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _kind == 'COURIER' && _dest == null ? Brand.orange : Brand.green,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _destText,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                  onTap: () => setState(() => _field = _Field.dest),
                  onChanged: (v) => _onTyped(_Field.dest, v),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 4),
                    hintText: _kind == 'COURIER'
                        ? t('ask.destination_required')
                        : t('ask.destination_optional'),
                    hintStyle: const TextStyle(
                      color: Color(0xFF888888),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    fillColor: Colors.transparent,
                  ),
                ),
              ),
              if (_destText.text.isNotEmpty)
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _destText.clear();
                      _dest = null;
                      _found = const [];
                    });
                    _refreshQuote();
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(Icons.close, size: 13, color: Color(0xFF666666)),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /* ── fare and phone side-by-side ────────────────────────────────────── */

  Widget _fareAndPhoneRow() {
    final quote = _quote;
    final min = _minFare;
    final named = _namedFare;
    final tooLittle = named != null && min > 0 && named < min;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // Left: Fare offer (50%)
            Expanded(
              flex: 1,
              child: Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF141414),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: tooLittle ? Brand.amber : const Color(0xFF2C2C2C),
                  ),
                ),
                child: Row(
                  children: [
                    const Text(
                      'RWF',
                      style: TextStyle(
                        color: Color(0xFF777777),
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: TextField(
                        controller: _fare,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        onChanged: (_) => setState(() => _fareTouched = true),
                        style: const TextStyle(
                          color: Brand.orange,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w900,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          fillColor: Colors.transparent,
                          hintText: min > 0 ? '$min' : 'Fare',
                          hintStyle: const TextStyle(color: Color(0xFF777777), fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Right: Phone number (50%)
            Expanded(
              flex: 1,
              child: Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF141414),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF2C2C2C)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.phone_outlined, size: 12, color: Color(0xFF777777)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: TextField(
                        controller: _phone,
                        keyboardType: TextInputType.phone,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(10),
                        ],
                        onChanged: (_) => setState(() {}),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          fillColor: Colors.transparent,
                          hintText: '07xxxxxxxx',
                          hintStyle: TextStyle(color: Color(0xFF777777), fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (tooLittle)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 2),
            child: Text(
              t('ask.too_little', {'amount': rwf(min)}),
              style: const TextStyle(color: Brand.amber, fontSize: 10.5),
            ),
          )
        else if (_pricedByRoute && quote?.distanceM != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 2),
            child: Text(
              '${km(quote!.distanceM)} route · Est. ${rwf(quote.quotedFareRwf)}',
              style: const TextStyle(color: Color(0xFF888888), fontSize: 10.5),
            ),
          ),
      ],
    );
  }

  /* ── address suggestions with custom typed address option ─────────── */

  List<Widget> _resultsFor(_Field field) {
    final controller = field == _Field.dest ? _destText : _pickupText;
    final text = controller.text.trim();
    if (_field != field || text.length < 2) return const [];

    return [
      const SizedBox(height: 5),
      Container(
        constraints: const BoxConstraints(maxHeight: 180),
        decoration: BoxDecoration(
          color: const Color(0xFF141414),
          border: Border.all(color: const Color(0xFF2E2E2E)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              // 1. "Use: ..." option with app brand background color
              InkWell(
                onTap: () {
                  if (field == _Field.dest) {
                    setState(() {
                      _dest = Place(label: text, fullName: text, latitude: 0, longitude: 0);
                      _found = const [];
                    });
                    _refreshQuote();
                  } else {
                    final dev = _device;
                    final here = dev != null ? LatLng(dev.latitude, dev.longitude) : _kigali;
                    setState(() {
                      _pickup = here;
                      _pickupName = text;
                      _found = const [];
                    });
                    _refreshQuote();
                  }
                  _collapse();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: const BoxDecoration(
                    color: Color(0xFF1C140C),
                    border: Border(bottom: BorderSide(color: Color(0xFF2E1C0D))),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.location_on, size: 14, color: Brand.orange),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Use: "$text"',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Brand.orange,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              field == _Field.dest
                                  ? 'Tap to select this custom address'
                                  : 'Tap to use this typed pickup address',
                              style: const TextStyle(
                                color: Color(0xFF888888),
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              if (_searching)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Center(
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.5, color: Brand.orange),
                    ),
                  ),
                )
              else
                ..._found.map(
                  (place) => InkWell(
                    onTap: () => _pick(place),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: const BoxDecoration(
                        border: Border(top: BorderSide(color: Color(0xFF1F1F1F))),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.location_on_outlined,
                            size: 13,
                            color: field == _Field.dest ? Brand.green : Brand.orange,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  place.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (place.fullName.isNotEmpty && place.fullName != place.label) ...[
                                  const SizedBox(height: 1),
                                  Text(
                                    place.fullName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Color(0xFF777777),
                                      fontSize: 10,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ];
  }

  Widget _kindTab(String kind, IconData icon, String label) {
    final on = _kind == kind;
    return GestureDetector(
      onTap: () {
        setState(() {
          _kind = kind;
          _fare.clear();
          _fareTouched = false;
        });
        _refreshQuote();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: on ? Brand.orange : const Color(0xFF181818),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: on ? Brand.orange : const Color(0xFF2E2E2E),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: on ? Colors.black : const Color(0xFF9E9E9E)),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: on ? Colors.black : const Color(0xFF9E9E9E),
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _useMyLocation() async {
    final at = _device;
    if (at == null) return;
    setState(() => _locating = true);
    final here = LatLng(at.latitude, at.longitude);
    final name = await widget.api.nameOfPlace(at.latitude, at.longitude);
    if (!mounted) return;
    setState(() {
      _pickup = here;
      _pickupName = name;
      _pickupText.text = name ?? '';
      _locating = false;
      _found = const [];
    });
    _map.move(here, 16);
    _refreshQuote();
    _collapse();
  }

  /* ── watching the ride ────────────────────────────────────────────────── */

  List<Widget> _tracking(PassengerRide ride) {
    final driver = ride.driver;
    return [
      Row(
        children: [
          Expanded(
            child: Text(
              switch (ride.status) {
                'SEARCHING' => t('track.searching'),
                'ASSIGNED' => t('track.on_the_way'),
                'ARRIVED' => t('track.arrived'),
                'IN_RIDE' => t('track.riding'),
                'COMPLETED' => t('track.completed'),
                'CLOSED' => t('track.closed'),
                'CANCELLED' => t('track.cancelled'),
                'NO_MATCH' => t('track.expired'),
                _ => ride.status,
              },
              style: const TextStyle(
                  color: Brand.text, fontSize: 14.5, fontWeight: FontWeight.w900),
            ),
          ),
          if (ride.searching)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: Brand.orange),
            ),
        ],
      ),

      if (ride.searching && ride.searchRadiusKm != null) ...[
        const SizedBox(height: 4),
        Text(t('track.widening', {'km': ride.searchRadiusKm}), style: Brand.micro),
      ],

      // Who took it, and how to reach them.
      if (driver != null) ...[
        const SizedBox(height: 10),
        Panel(
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(color: Brand.orange, shape: BoxShape.circle),
                child: const Icon(Icons.two_wheeler, size: 19, color: Colors.black),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      driver.name ?? t('ride.unnamed_driver'),
                      style: const TextStyle(
                          color: Brand.text, fontSize: 13, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        // The plate is the trust anchor: it reads loudest.
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            driver.plateNumber ?? '',
                            style: const TextStyle(
                              color: Colors.black,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.9,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if ((driver.rating ?? 0) > 0)
                          Row(
                            children: [
                              for (var n = 1; n <= 5; n++)
                                Icon(
                                  n <= driver.rating!.round()
                                      ? Icons.star
                                      : Icons.star_border,
                                  size: 11,
                                  color: Brand.amber,
                                ),
                              const SizedBox(width: 3),
                              Text(
                                driver.rating!.toStringAsFixed(1),
                                style: const TextStyle(
                                    color: Brand.text,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800),
                              ),
                            ],
                          )
                        else
                          Text(t('track.new_motari'), style: Brand.micro),
                      ],
                    ),
                  ],
                ),
              ),
              if (driver.phone != null)
                GestureDetector(
                  onTap: () => _call(driver.phone!),
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: const BoxDecoration(
                        color: Brand.orange, shape: BoxShape.circle),
                    child: const Icon(Icons.call, size: 17, color: Colors.black),
                  ),
                ),
            ],
          ),
        ),
      ],

      const SizedBox(height: 10),
      Panel(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('● ${ride.pickupName ?? t('ask.my_location')}',
                style: const TextStyle(color: Brand.muted, fontSize: 11.5)),
            Text('● ${ride.destName ?? t('track.meter_ride')}',
                style: const TextStyle(color: Brand.muted, fontSize: 11.5)),
            if (ride.fareRwf != null) ...[
              const SizedBox(height: 6),
              Text(
                rwf(ride.fareRwf),
                style: const TextStyle(
                    color: Brand.text, fontSize: 14, fontWeight: FontWeight.w900),
              ),
            ],
          ],
        ),
      ),

      const SizedBox(height: 10),
      ..._trackingActions(ride),
    ];
  }

  List<Widget> _trackingActions(PassengerRide ride) {
    if (ride.isCourier) return _parcelActions(ride);
    return _rideActions(ride);
  }

  /// The parcel owner's side. Once a motari has the parcel it stops being
  /// theirs to call off, and once it is said to be delivered they have two
  /// things to do and one right to keep: pay, agree, or say it never came.
  List<Widget> _parcelActions(PassengerRide ride) {
    final delivered = ride.deliveredAt != null;
    final settled = ride.deliveryConfirmedAt != null;
    final disputed = ride.deliveryDisputedAt != null;
    final paid = ride.paymentStatus == 'PAID' || ride.cashDeclaredAt != null;

    if (disputed) {
      return [
        Text(t('parcel.you_disputed'),
            style: const TextStyle(color: Brand.red, fontSize: 12, height: 1.4)),
        const SizedBox(height: 8),
        Text(t('parcel.support_will_call'), style: Brand.micro),
      ];
    }

    if (settled) {
      return [
        Text(t('parcel.delivered_ok'),
            style: const TextStyle(
                color: Brand.green, fontSize: 12, fontWeight: FontWeight.w800)),
        if (ride.rating == null) ...[
          const SizedBox(height: 10),
          Text(t('track.rate'), style: Brand.micro),
          const SizedBox(height: 4),
          Row(
            children: [
              for (var n = 1; n <= 5; n++)
                IconButton(
                  padding: const EdgeInsets.only(right: 2),
                  constraints: const BoxConstraints(),
                  onPressed: _busy
                      ? null
                      : () => _act(() => widget.api.rateRide(ride.token!, n)),
                  icon: const Icon(Icons.star_border, size: 26, color: Brand.amber),
                ),
            ],
          ),
        ],
        const SizedBox(height: 10),
        PrimaryButton(label: t('track.new_ride'), onPressed: _startOver),
      ];
    }

    if (delivered) {
      return [
        Text(t('parcel.motari_says_delivered'),
            style: const TextStyle(
                color: Brand.text, fontSize: 12.5, fontWeight: FontWeight.w700, height: 1.4)),
        const SizedBox(height: 4),
        Text(t('parcel.stands_soon'), style: Brand.micro),
        const SizedBox(height: 10),
        // Pay and confirm are two different things, so they are two buttons.
        Row(
          children: [
            if (!paid)
              Expanded(
                child: PrimaryButton(
                  label: t('parcel.pay_now'),
                  icon: Icons.smartphone,
                  onPressed: _busy
                      ? null
                      : () => _act(() => widget.api.payRide(
                            ride.token!,
                            phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
                          )),
                ),
              ),
            if (!paid) const SizedBox(width: 8),
            Expanded(
              child: PrimaryButton(
                label: t('parcel.confirm'),
                icon: Icons.check,
                onPressed:
                    _busy ? null : () => _act(() => widget.api.confirmDelivery(ride.token!)),
              ),
            ),
          ],
        ),
        if (!paid) ...[
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _busy ? null : () => _act(() => widget.api.declareCash(ride.token!)),
            style: OutlinedButton.styleFrom(
              foregroundColor: Brand.text,
              side: const BorderSide(color: Brand.line),
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: Text(t('track.paid_cash_button'),
                style: const TextStyle(
                    fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
          ),
        ],
        const SizedBox(height: 10),
        // The right they keep, whatever the clock does.
        GestureDetector(
          onTap: _busy ? null : () => _act(() => widget.api.disputeDelivery(ride.token!)),
          behavior: HitTestBehavior.opaque,
          child: Center(
            child: Text(
              t('parcel.not_delivered'),
              style: const TextStyle(
                color: Brand.red,
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
              ),
            ),
          ),
        ),
      ];
    }

    // On its way. Once the motari has it in hand there is nothing to cancel.
    if (ride.pickedUpAt != null) {
      return [
        Text(t('parcel.on_its_way'), style: Brand.micro),
        const SizedBox(height: 8),
        Text(t('parcel.cannot_cancel'),
            style: const TextStyle(color: Brand.muted, fontSize: 11.5, height: 1.4)),
      ];
    }

    return _rideActions(ride);
  }

  List<Widget> _rideActions(PassengerRide ride) {
    // Paid, and nothing left to do but say how it went.
    if (ride.paymentStatus == 'PAID' || ride.status == 'CLOSED') {
      return [
        Text(
          ride.paymentMethod == 'CASH' ? t('track.paid_cash') : t('track.paid'),
          style: const TextStyle(
              color: Brand.green, fontSize: 12, fontWeight: FontWeight.w800),
        ),
        if (ride.rating == null) ...[
          const SizedBox(height: 10),
          Text(t('track.rate'), style: Brand.micro),
          const SizedBox(height: 4),
          Row(
            children: [
              for (var n = 1; n <= 5; n++)
                IconButton(
                  padding: const EdgeInsets.only(right: 2),
                  constraints: const BoxConstraints(),
                  onPressed: _busy
                      ? null
                      : () => _act(() => widget.api.rateRide(ride.token!, n)),
                  icon: const Icon(Icons.star_border, size: 26, color: Brand.amber),
                ),
            ],
          ),
        ] else ...[
          const SizedBox(height: 8),
          Text(t('track.thanks'), style: Brand.micro),
        ],
        const SizedBox(height: 10),
        PrimaryButton(label: t('track.new_ride'), onPressed: _startOver),
      ];
    }

    if (ride.done) {
      return [
        Text(
          ride.cancelReason ?? t('track.over'),
          style: const TextStyle(color: Brand.muted, fontSize: 12),
        ),
        const SizedBox(height: 10),
        PrimaryButton(label: t('track.new_ride'), onPressed: _startOver),
      ];
    }

    // The fare has been asked for, or the ride is finished and unpaid.
    if (ride.payDue || ride.status == 'COMPLETED') {
      if (ride.cashDeclaredAt != null) {
        return [
          Text(t('track.cash_recorded'),
              style: const TextStyle(
                  color: Brand.green, fontSize: 12, fontWeight: FontWeight.w700)),
        ];
      }
      return [
        if (ride.payDue && ride.status != 'COMPLETED') ...[
          Text(t('track.almost_there'),
              style: const TextStyle(
                  color: Brand.amber, fontSize: 11.5, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
        ],
        Row(
          children: [
            Expanded(
              child: PrimaryButton(
                label: t('track.pay_momo'),
                icon: Icons.smartphone,
                onPressed: _busy
                    ? null
                    : () => _act(() => widget.api.payRide(
                          ride.token!,
                          phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
                        )),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed:
                    _busy ? null : () => _act(() => widget.api.declareCash(ride.token!)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Brand.text,
                  side: const BorderSide(color: Brand.line),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: Text(
                  t('track.paid_cash_button'),
                  style: const TextStyle(
                      fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.5),
                ),
              ),
            ),
          ],
        ),
        if (ride.paymentStatus == 'PENDING' && ride.paymentMethod == 'PLATFORM') ...[
          const SizedBox(height: 8),
          Text(t('track.approve_on_phone'),
              style: const TextStyle(color: Brand.amber, fontSize: 11)),
        ],
      ];
    }

    // Still early enough to change their mind.
    return [
      OutlinedButton(
        onPressed: _busy
            ? null
            : () async {
                await _act(() => widget.api.cancelRide(ride.token!));
                if (mounted && (_ride?.done ?? false)) _release();
              },
        style: OutlinedButton.styleFrom(
          foregroundColor: Brand.red,
          side: const BorderSide(color: Color(0xFF451A1A)),
          padding: const EdgeInsets.symmetric(vertical: 11),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: Text(
          t('track.cancel'),
          style: const TextStyle(
              fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.8),
        ),
      ),
    ];
  }
}
