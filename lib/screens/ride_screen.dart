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
import '../permissions.dart';
import '../theme.dart';
import '../widgets/language_button.dart';

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

/// The questions, in the order a passenger is asked them. Only one is ever open.
enum _Ask { from, to, fare, who }

const _kigali = LatLng(-1.9441, 30.0619);
const _tokenKey = 'passenger.ride.token';
const _nameKey = 'passenger.name';
const _phoneKey = 'passenger.phone';

class _RideScreenState extends State<RideScreen> with WidgetsBindingObserver {
  final _map = MapController();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _pickupText = TextEditingController();
  final _destText = TextEditingController();
  final _fare = TextEditingController();

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

  /// The question the passenger has reopened, if any. Left null, the sheet asks
  /// the first one that has no answer.
  _Ask? _open;

  /// The destination question has been answered — with a place, with text the
  /// map did not know, or with "no destination, run the meter". Typing alone
  /// does not settle it, because half a word is not an answer.
  bool _toSettled = false;

  /// Looking up the name of the phone's own fix.
  bool _locating = false;

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
    _name.dispose();
    _phone.dispose();
    _pickupText.dispose();
    _destText.dispose();
    _fare.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _ride != null) _refresh();
  }

  /* ── what this device already knows ───────────────────────────────────── */

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    _name.text = prefs.getString(_nameKey) ?? '';
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
    await prefs.setString(_nameKey, _name.text.trim());
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
      // A kilometre-scale fix is a network guess, not GPS: never stand on it.
      if (p.accuracy > 5000 || !mounted) return;
      // The fix is kept, but it is not the answer until the passenger says so:
      // a silently filled pickup is one nobody checked.
      setState(() => _device = p);
      if (!_framed) {
        _framed = true;
        _map.move(LatLng(p.latitude, p.longitude), 16);
      }
    });
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
        if (!_fareTouched && quote.quotedFareRwf != null) {
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
      // Picking a place answers the question, so the next one opens.
      _open = null;
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
    if (_name.text.trim().length < 2) return false;
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
        name: _name.text.trim(),
        phone: _phone.text.trim(),
        pickupLat: at.latitude,
        pickupLng: at.longitude,
        pickupName: _pickupName,
        destLat: _dest?.latitude,
        destLng: _dest?.longitude,
        destName: _dest?.label ??
            (_destText.text.trim().isEmpty ? null : _destText.text.trim()),
        kind: _kind,
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
      _open = null;
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
                        _open = null;
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
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'rw.mpahmapu.motari',
              ),
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
        ],
      ),
    );
  }

  List<Marker> _markers() {
    final markers = <Marker>[];
    final ride = _ride;
    final pickup = ride == null ? _pickup : LatLng(ride.pickupLat, ride.pickupLng);

    if (pickup != null) {
      markers.add(_pin(pickup, Brand.orange, Icons.person));
    }
    final destLat = ride?.destLat ?? _dest?.latitude;
    final destLng = ride?.destLng ?? _dest?.longitude;
    if (destLat != null && destLng != null) {
      markers.add(_pin(LatLng(destLat, destLng), Brand.green, Icons.flag));
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

  /* ── asking, one question at a time ───────────────────────────────────── */

  /// Which question is open. A step opens only once the one before it has an
  /// answer, so the sheet never shows a passenger a field they cannot fill yet.
  _Ask get _step {
    if (_open != null) return _open!;
    if (_pickup == null) return _Ask.from;
    if (!_toSettled) return _Ask.to;
    if (_namedFare == null || _namedFare! < _minFare) return _Ask.fare;
    return _Ask.who;
  }

  bool get _fromDone => _pickup != null;
  bool get _toDone => _toSettled;
  bool get _fareDone => _namedFare != null && _namedFare! >= _minFare;
  bool get _whoDone =>
      _name.text.trim().length >= 2 && RegExp(r'^07\d{8}$').hasMatch(_phone.text.trim());

  /// Move on, and let the steps work out what comes next.
  void _next() {
    FocusScope.of(context).unfocus();
    setState(() {
      _open = null;
      _found = const [];
    });
  }

  List<Widget> _requestForm() {
    final step = _step;
    return [
      // Ride or parcel. The choice comes first because it changes what the rest
      // of the questions mean.
      Row(
        children: [
          _kindTab('RIDE', Icons.two_wheeler, t('ask.ride')),
          const SizedBox(width: 6),
          _kindTab('COURIER', Icons.inventory_2, t('ask.courier')),
        ],
      ),
      const SizedBox(height: 12),

      // Answered questions collapse to a line each, and any of them can be
      // reopened by tapping it.
      if (_fromDone && step != _Ask.from)
        _answered(
          dot: Brand.orange,
          label: t('ask.from'),
          value: _pickupName ?? t('ask.my_location'),
          onTap: () => setState(() => _open = _Ask.from),
        ),
      if (_toDone && step != _Ask.to)
        _answered(
          dot: Brand.green,
          label: t('ask.to_label'),
          value: _destText.text.trim().isEmpty
              ? t('ask.no_destination')
              : _destText.text.trim(),
          onTap: () => setState(() => _open = _Ask.to),
        ),
      if (_fareDone && step != _Ask.fare)
        _answered(
          dot: Brand.orange,
          label: t('ask.fare_label'),
          value: rwf(_namedFare),
          onTap: () => setState(() => _open = _Ask.fare),
        ),
      if (_whoDone && step != _Ask.who)
        _answered(
          dot: Brand.dim,
          label: t('ask.you_label'),
          value: '${_name.text.trim()} · ${_phone.text.trim()}',
          onTap: () => setState(() => _open = _Ask.who),
        ),

      // And the question being asked right now.
      ...switch (step) {
        _Ask.from => _askFrom(),
        _Ask.to => _askTo(),
        _Ask.fare => _askFare(),
        _Ask.who => _askWho(),
      },
    ];
  }

  /// One answered question: a line you can tap to change your mind.
  Widget _answered({
    required Color dot,
    required String label,
    required String value,
    required VoidCallback onTap,
  }) =>
      GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 9),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 9),
              Text(label.toUpperCase(), style: Brand.micro),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      color: Brand.text, fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.edit_outlined, size: 12, color: Brand.dim),
            ],
          ),
        ),
      );

  /// The heading over whichever question is open.
  Widget _question(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: const TextStyle(
              color: Brand.text, fontSize: 15, fontWeight: FontWeight.w900),
        ),
      );

  /* ── 1. where are you ─────────────────────────────────────────────────── */

  List<Widget> _askFrom() => [
        _question(t('ask.q_from')),

        // The phone knows, but only if it is asked: a button, not a silent fill.
        if (_device != null) ...[
          _bigButton(
            icon: Icons.my_location,
            label: _locating ? t('ask.locating') : t('ask.use_my_location'),
            onTap: _locating ? null : _useMyLocation,
          ),
          const SizedBox(height: 9),
          Row(
            children: [
              const Expanded(child: Divider(color: Brand.line, height: 1)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(t('signin.or'), style: Brand.micro),
              ),
              const Expanded(child: Divider(color: Brand.line, height: 1)),
            ],
          ),
          const SizedBox(height: 9),
        ],

        _placeField(
          field: _Field.pickup,
          controller: _pickupText,
          dot: Brand.orange,
          hint: t('ask.from_required'),
        ),
        ..._resultsFor(_Field.pickup),

        const SizedBox(height: 8),
        Text(t('ask.or_tap_map'), style: Brand.micro),
      ];

  /* ── 2. where to ──────────────────────────────────────────────────────── */

  List<Widget> _askTo() => [
        _question(_kind == 'COURIER' ? t('ask.q_to_parcel') : t('ask.q_to')),

        _placeField(
          field: _Field.dest,
          controller: _destText,
          dot: Brand.green,
          hint: _kind == 'COURIER' ? t('ask.to_required') : t('ask.to'),
        ),
        ..._resultsFor(_Field.dest),

        // Typed something the map has never heard of: that is still a place,
        // and it is taken as written.
        if (_typedOnly && !_searching) ...[
          const SizedBox(height: 8),
          Text(t('ask.not_on_map'), style: Brand.micro),
          const SizedBox(height: 8),
          _bigButton(
            icon: Icons.check,
            label: t('ask.use_what_i_typed'),
            onTap: () {
              setState(() => _toSettled = true);
              _next();
            },
          ),
        ],

        // A ride with nowhere named runs on the meter, which is a real answer
        // and not a skipped question.
        if (_kind == 'RIDE' && _destText.text.trim().isEmpty) ...[
          const SizedBox(height: 10),
          _quietButton(
            label: t('ask.no_destination_button'),
            onTap: () {
              setState(() {
                _dest = null;
                _toSettled = true;
              });
              _refreshQuote();
              _next();
            },
          ),
        ],
      ];

  /* ── 3. how much ──────────────────────────────────────────────────────── */

  List<Widget> _askFare() {
    final quote = _quote;
    final min = _minFare;
    final named = _namedFare;
    final tooLittle = named != null && min > 0 && named < min;
    final priced = _measurable && quote?.quotedFareRwf != null;

    return [
      _question(t('ask.q_fare')),

      // Where there is a route, the app has already worked out a price and put
      // it in the box; the passenger is agreeing to it or changing it.
      if (priced)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            t('ask.we_suggest', {
              'amount': rwf(quote!.quotedFareRwf),
              'distance': km(quote.distanceM),
            }),
            style: const TextStyle(color: Brand.muted, fontSize: 11.5, height: 1.4),
          ),
        )
      else if (quote != null)
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
        autofocus: !priced,
        onChanged: (_) => setState(() => _fareTouched = true),
        style: const TextStyle(
            color: Brand.orange, fontSize: 19, fontWeight: FontWeight.w900),
        decoration: InputDecoration(
          hintText: min > 0 ? t('ask.at_least', {'amount': rwf(min)}) : 'RWF',
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

      const SizedBox(height: 10),
      _bigButton(
        icon: Icons.arrow_forward,
        label: t('ask.next'),
        onTap: _fareDone ? _next : null,
      ),
    ];
  }

  /* ── 4. who are you ───────────────────────────────────────────────────── */

  List<Widget> _askWho() => [
        _question(t('ask.q_who')),
        Text(t('ask.who_why'), style: Brand.micro),
        const SizedBox(height: 8),

        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          onChanged: (_) => setState(() {}),
          style: const TextStyle(color: Brand.text, fontSize: 13),
          decoration: InputDecoration(hintText: t('ask.your_name')),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _phone,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(10),
          ],
          onChanged: (_) => setState(() {}),
          style: const TextStyle(color: Brand.text, fontSize: 13),
          decoration: const InputDecoration(hintText: '07xxxxxxxx'),
        ),

        const SizedBox(height: 12),
        PrimaryButton(
          label: _busy ? t('ask.asking') : t('ask.request'),
          icon: Icons.two_wheeler,
          onPressed: _canRequest ? _request : null,
        ),
        const SizedBox(height: 6),
        Text(t('ask.no_account'), textAlign: TextAlign.center, style: Brand.micro),
      ];

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
    _next();
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
      const SizedBox(height: 4),
      for (final place in _found)
        GestureDetector(
          onTap: () => _pick(place),
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Row(
              children: [
                const Icon(Icons.north_east, size: 12, color: Brand.dim),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    place.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Brand.text, fontSize: 12.5),
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
                'EXPIRED' => t('track.expired'),
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
                      driver.name ?? t('app.name'),
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
