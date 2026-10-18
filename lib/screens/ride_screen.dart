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


  /// The destination question has been answered — with a place, with text the
  /// map did not know, or with "no destination, run the meter". Typing alone
  /// does not settle it, because half a word is not an answer.
  bool _toSettled = false;

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
        _toSettled = true;
      }
      _found = const [];
    });
    _refreshQuote();
  }

  /// A place the map has never heard of is still a place. The passenger names
  /// their own price for it, because there is no route to measure.
  bool get _typedOnly => _dest == null && _destText.text.trim().isNotEmpty;

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
      _toSettled = false;
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

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  if (_supply != null && _ride == null) _supplyChip(),
                  const Spacer(),
                  BasemapButton(
                    value: _basemap,
                    onChanged: (m) => setState(() => _basemap = m),
                  ),
                  const SizedBox(width: 8),
                  const LanguageButton(),
                  const SizedBox(width: 8),
                  _driveButton(),
                ],
              ),
            ),
          ),

          Align(
            alignment: Alignment.bottomCenter,
            child: _sheet(),
          ),

          // Above the sheet, so it is never buried under it.
          Positioned(
            left: 8,
            bottom: MediaQuery.of(context).size.height * 0.74 + 6,
            child: MapCredit(map: _basemap),
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

  Widget _driveButton() => GestureDetector(
        onTap: widget.onDrive,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: Brand.black.withValues(alpha: 0.94),
            border: Border.all(color: Brand.line),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.two_wheeler, size: 12, color: Brand.orange),
              const SizedBox(width: 5),
              Text(
                t('ask.i_drive'),
                style: const TextStyle(
                  color: Brand.text,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.9,
                ),
              ),
            ],
          ),
        ),
      );

  /* ── the sheet ────────────────────────────────────────────────────────── */

  Widget _sheet() => Container(
        width: double.infinity,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.74,
        ),
        decoration: BoxDecoration(
          color: Brand.black.withValues(alpha: 0.97),
          border: const Border(top: BorderSide(color: Brand.line)),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
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
                    14,
                    2,
                    14,
                    14 + MediaQuery.of(context).viewInsets.bottom,
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
          padding: const EdgeInsets.fromLTRB(0, 9, 0, 4),
          child: Column(
            children: [
              Container(
                width: 38,
                height: 4,
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
      // What kind of job (Ride or Delivery/Courier)
      Row(
        children: [
          _kindTab('RIDE', Icons.two_wheeler, t('ask.ride')),
          const SizedBox(width: 6),
          _kindTab('COURIER', Icons.inventory_2, t('ask.courier')),
        ],
      ),
      const SizedBox(height: 12),

      // From (pickup)
      ..._fromField(),
      const SizedBox(height: 12),

      // To (destination)
      ..._toField(),
      const SizedBox(height: 12),

      // If courier: parcel note
      if (_kind == 'COURIER') ...[
        _label(t('motari.request.parcel_note')),
        TextField(
          controller: _parcelNote,
          textCapitalization: TextCapitalization.sentences,
          style: const TextStyle(color: Brand.text, fontSize: 13),
          decoration: InputDecoration(
            hintText: t('motari.request.parcel_note'),
            prefixIcon: const Icon(Icons.inventory_2_outlined, size: 15, color: Brand.orange),
            prefixIconConstraints: const BoxConstraints(minWidth: 36),
          ),
        ),
        const SizedBox(height: 12),
      ],

      // Money (Fare offer)
      ..._fareField(),
      const SizedBox(height: 12),

      // Phone
      _phoneField(),
      const SizedBox(height: 14),

      // Request CTA button: always present
      PrimaryButton(
        label: _busy
            ? t('ask.asking')
            : _kind == 'COURIER' ? t('ask.find_delivery') : t('ask.find'),
        icon: Icons.search,
        onPressed: _canRequest ? _request : null,
      ),
      const SizedBox(height: 6),
      Text(t('ask.no_account'), textAlign: TextAlign.center, style: Brand.micro),
    ];
  }



  /// A small heading over a field, so every part of the sheet says what it is.
  Widget _label(String text, {String? hint}) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            Text(text.toUpperCase(), style: Brand.micro),
            if (hint != null) ...[
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(color: Brand.dim, fontSize: 10.5),
                ),
              ),
            ],
          ],
        ),
      );

  /* ── where from ───────────────────────────────────────────────────────── */

  List<Widget> _fromField() => [
        _label(t('ask.from'), hint: _device == null ? null : t('ask.tap_map_hint')),
        _placeField(
          field: _Field.pickup,
          controller: _pickupText,
          dot: Brand.orange,
          hint: t('ask.from_required'),
        ),
        ..._resultsFor(_Field.pickup),

        if (_pickup == null && _pickupText.text.trim().length >= 2 && !_searching) ...[
          const SizedBox(height: 8),
          _typedAddressCard(
            text: _pickupText.text.trim(),
            isPickup: true,
            onTap: () {
              final dev = _device;
              final here = dev != null ? LatLng(dev.latitude, dev.longitude) : _kigali;
              setState(() {
                _pickup = here;
                _pickupName = _pickupText.text.trim();
              });
              _refreshQuote();
              _collapse();
            },
          ),
        ],

        // The phone knows where it is, but only says so when asked.
        if (_device != null) ...[
          const SizedBox(height: 8),
          _bigButton(
            icon: Icons.my_location,
            label: _locating ? t('ask.locating') : t('ask.use_my_location'),
            onTap: _locating ? null : _useMyLocation,
          ),
        ],
      ];

  /* ── where to ─────────────────────────────────────────────────────────── */

  List<Widget> _toField() => [
        _label(_kind == 'COURIER' ? t('ask.to_label_parcel') : t('ask.to_label')),
        _placeField(
          field: _Field.dest,
          controller: _destText,
          dot: Brand.green,
          hint: _kind == 'COURIER' ? t('ask.to_required') : t('ask.to'),
        ),
        ..._resultsFor(_Field.dest),

        // Typed something the map has never heard of or custom address:
        if (_typedOnly && !_searching) ...[
          const SizedBox(height: 8),
          _typedAddressCard(
            text: _destText.text.trim(),
            onTap: () {
              setState(() {
                _dest = null;
                _toSettled = true;
              });
              _refreshQuote();
              _collapse();
            },
          ),
        ],

        // A ride with nowhere named runs on the meter, which is a real answer.
        if (_kind == 'RIDE' && _destText.text.trim().isEmpty) ...[
          const SizedBox(height: 8),
          _quietButton(
            label: t('ask.no_destination_button'),
            onTap: () {
              setState(() {
                _dest = null;
                _toSettled = true;
              });
              _refreshQuote();
              _collapse();
            },
          ),
        ],
      ];

  /* ── how much ─────────────────────────────────────────────────────────── */

  List<Widget> _fareField() {
    final quote = _quote;
    final min = _minFare;
    final named = _namedFare;
    final tooLittle = named != null && min > 0 && named < min;

    return [
      // A route the app measured gives a price to agree with; a place only the
      // passenger knows leaves the price to them.
      _label(
        _pricedByRoute ? t('ask.approx_amount') : t('ask.q_fare'),
        hint: _pricedByRoute && quote?.distanceM != null ? km(quote!.distanceM) : null,
      ),

      if (_pricedByRoute)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(t('ask.approx_hint'),
              style: const TextStyle(color: Brand.muted, fontSize: 11.5, height: 1.4)),
        )
      else if (quote != null && !_measurable)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            t('ask.meter_card', {
              'base': rwf(quote.baseFareRwf),
              'perKm': rwf(quote.perKmRwf),
            }),
            style: const TextStyle(color: Brand.muted, fontSize: 11.5, height: 1.4),
          ),
        ),

      TextField(
        controller: _fare,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        onChanged: (_) => setState(() => _fareTouched = true),
        style: const TextStyle(
            color: Brand.orange, fontSize: 19, fontWeight: FontWeight.w900),
        decoration: InputDecoration(
          hintText: min > 0 ? t('ask.at_least', {'amount': rwf(min)}) : 'RWF',
          // The currency sits in the field rather than in the number, so what
          // the passenger types is only ever the amount.
          prefixIcon: const Padding(
            padding: EdgeInsets.only(left: 12, right: 8),
            child: Center(
              widthFactor: 0,
              child: Text('RWF',
                  style: TextStyle(
                      color: Brand.dim, fontSize: 11, fontWeight: FontWeight.w800)),
            ),
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 30),
        ),
      ),

      if (tooLittle) ...[
        const SizedBox(height: 6),
        Text(t('ask.too_little', {'amount': rwf(min)}),
            style: const TextStyle(color: Brand.amber, fontSize: 11)),
      ],
    ];
  }

  /* ── who is asking (phone number) ─────────────────────────────────────── */

  Widget _phoneField() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label(t('ask.phone'), hint: '07xxxxxxxx'),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(10),
            ],
            onChanged: (_) => setState(() {}),
            style: const TextStyle(color: Brand.text, fontSize: 13),
            decoration: const InputDecoration(
              hintText: '07xxxxxxxx',
              prefixIcon: Icon(Icons.call_outlined, size: 15, color: Brand.dim),
              prefixIconConstraints: BoxConstraints(minWidth: 36),
            ),
          ),
        ],
      );

  Widget _typedAddressCard({
    required String text,
    bool isPickup = false,
    required VoidCallback onTap,
  }) {
    final active = isPickup ? _pickup != null : _toSettled;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF14532D) : const Color(0xFF1C130B),
          border: Border.all(color: active ? Brand.green : Brand.orange),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(
              active ? Icons.check_circle : Icons.pin_drop,
              size: 16,
              color: active ? Brand.green : Brand.orange,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    active
                        ? '${t('ask.using_typed')}: "$text"'
                        : '${t('ask.send_typed')}: "$text"',
                    style: const TextStyle(
                        color: Brand.text, fontSize: 12, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    active
                        ? t('ask.typed_ready')
                        : t('ask.not_on_map'),
                    style: const TextStyle(color: Brand.muted, fontSize: 10.5),
                  ),
                ],
              ),
            ),
            Icon(
              active ? Icons.check : Icons.arrow_forward_ios,
              size: 12,
              color: active ? Brand.green : Brand.orange,
            ),
          ],
        ),
      ),
    );
  }

  /* ── the pieces the questions are made of ─────────────────────────────── */

  /// The phone's own fix, taken only when asked for, and named so it reads as a
  /// place rather than as a dot.
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

  Widget _bigButton({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
  }) =>
      SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 15),
          label: Text(
            label.toUpperCase(),
            style: const TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w900, letterSpacing: 0.6),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: onTap == null ? const Color(0xFF1A1A1A) : Brand.orange,
            foregroundColor: onTap == null ? Brand.dim : Colors.black,
            disabledBackgroundColor: const Color(0xFF1A1A1A),
            disabledForegroundColor: Brand.dim,
            elevation: 0,
            padding: const EdgeInsets.symmetric(vertical: 13),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      );

  Widget _quietButton({required String label, required VoidCallback onTap}) =>
      SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            foregroundColor: Brand.muted,
            side: const BorderSide(color: Brand.line),
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: Text(
            label.toUpperCase(),
            style: const TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.6),
          ),
        ),
      );

  /// A place field: type into it, pick from what comes back, or clear it. The
  /// pickup and the destination are the same thing pointed at different state.
  Widget _placeField({
    required _Field field,
    required TextEditingController controller,
    required Color dot,
    required String hint,
  }) {
    final busy = _searching && _field == field;
    return TextField(
      controller: controller,
      autofocus: true,
      onChanged: (v) => _onTyped(field, v),
      style: const TextStyle(color: Brand.text, fontSize: 13),
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Padding(
          padding: const EdgeInsets.only(left: 13, right: 9),
          child: Center(
            widthFactor: 0,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
          ),
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 30),
        suffixIcon: busy
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 1.6, color: Brand.dim),
                ),
              )
            : controller.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close, size: 14, color: Brand.dim),
                    onPressed: () {
                      setState(() {
                        controller.clear();
                        _found = const [];
                        if (field == _Field.dest) {
                          _dest = null;
                          _toSettled = false;
                        } else {
                          _pickupName = null;
                          _pickup = null;
                        }
                      });
                    },
                  ),
      ),
    );
  }

  List<Widget> _resultsFor(_Field field) {
    if (_field != field || _found.isEmpty) return const [];
    return [
      const SizedBox(height: 6),
      Container(
        constraints: const BoxConstraints(maxHeight: 220),
        decoration: BoxDecoration(
          color: Brand.surface,
          border: Border.all(color: Brand.line),
          borderRadius: BorderRadius.circular(10),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: ListView.separated(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            itemCount: _found.length,
            separatorBuilder: (context, index) => const Divider(height: 1, color: Brand.line),
            itemBuilder: (context, i) {
              final place = _found[i];
              return InkWell(
                onTap: () => _pick(place),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.place_outlined, size: 14, color: Brand.orange),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          place.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Brand.text, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ];
  }

  Widget _kindTab(String kind, IconData icon, String label) {
    final on = _kind == kind;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            _kind = kind;
            _fare.clear();
            _fareTouched = false;
            // A parcel must go somewhere, so switching to one reopens that
            // question rather than carrying a metered ride's answer over.
            if (kind == 'COURIER' && _destText.text.trim().isEmpty) {
              _toSettled = false;
            }
          });
          _refreshQuote();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? Brand.orange : Brand.surface,
            border: Border.all(color: on ? Brand.orange : Brand.line),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 13, color: on ? Colors.black : Brand.muted),
              const SizedBox(width: 6),
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  color: on ? Colors.black : Brand.muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
