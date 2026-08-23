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
      setState(() {
        _device = p;
        _pickup ??= LatLng(p.latitude, p.longitude);
      });
      if (!_framed) {
        _framed = true;
        _map.move(LatLng(p.latitude, p.longitude), 16);
        _refreshQuote();
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
  /// because the motari makes the whole journey for it.
  int get _minFare => _supply?.minFareRwf ?? _quote?.minFareRwf ?? 0;

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
                  ? (_, point) => setState(() {
                        _pickup = point;
                        _pickupName = null;
                        _refreshQuote();
                      })
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

  Widget _sheet() => Container(
        width: double.infinity,
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.72),
        decoration: BoxDecoration(
          color: Brand.black.withValues(alpha: 0.97),
          border: const Border(top: BorderSide(color: Brand.line)),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              14,
              12,
              14,
              14 + MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_ride == null) ..._requestForm() else ..._tracking(_ride!),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!, style: const TextStyle(color: Brand.red, fontSize: 11.5)),
                ],
              ],
            ),
          ),
        ),
      );

  /* ── the form ─────────────────────────────────────────────────────────── */

  List<Widget> _requestForm() => [
        Row(
          children: [
            _kindTab('RIDE', Icons.two_wheeler, t('ask.ride')),
            const SizedBox(width: 6),
            _kindTab('COURIER', Icons.inventory_2, t('ask.courier')),
          ],
        ),
        const SizedBox(height: 12),

        // Where from. A device fix fills this in on its own, but a phone that
        // never gets one leaves the passenger with nothing to say, so the field
        // is always here and always typeable.
        _placeField(
          field: _Field.pickup,
          controller: _pickupText,
          dot: Brand.orange,
          hint: _device != null ? t('ask.my_location') : t('ask.from_required'),
        ),
        if (_field == _Field.pickup && _found.isNotEmpty) ..._results(),

        const SizedBox(height: 6),

        // Where to.
        _placeField(
          field: _Field.dest,
          controller: _destText,
          dot: Brand.green,
          hint: _kind == 'COURIER' ? t('ask.to_required') : t('ask.to'),
        ),
        if (_field == _Field.dest && _found.isNotEmpty) ..._results(),

        // Nothing on the map matched what they typed: it is still a place, and
        // the price they name is the whole of what the motari is agreeing to.
        if (_typedOnly && !_searching) ...[
          const SizedBox(height: 4),
          Text(t('ask.not_on_map'), style: Brand.micro),
        ],

        // No fix, and nothing typed: say why the button is not going anywhere.
        if (_pickup == null) ...[
          const SizedBox(height: 6),
          Text(
            t('ask.where_are_you'),
            style: const TextStyle(color: Brand.amber, fontSize: 11, height: 1.4),
          ),
        ],

        const SizedBox(height: 10),
        _fareLine(),
        const SizedBox(height: 10),

        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(color: Brand.text, fontSize: 13),
                decoration: InputDecoration(hintText: t('ask.your_name')),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
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
            ),
          ],
        ),
        const SizedBox(height: 10),

        PrimaryButton(
          label: _busy ? t('ask.asking') : t('ask.request'),
          icon: Icons.two_wheeler,
          onPressed: _canRequest ? _request : null,
        ),
        const SizedBox(height: 6),
        Text(t('ask.no_account'), textAlign: TextAlign.center, style: Brand.micro),
      ];

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
      onChanged: (v) => _onTyped(field, v),
      onTap: () => setState(() {
        // Moving between the fields should not leave the other one's results up.
        if (_field != field) {
          _field = field;
          _found = const [];
        }
      }),
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
                        } else {
                          _pickupName = null;
                          // Clearing the pickup falls back to the phone, if the
                          // phone has anything to fall back to.
                          final at = _device;
                          _pickup = at == null ? null : LatLng(at.latitude, at.longitude);
                        }
                      });
                      _refreshQuote();
                    },
                  ),
      ),
    );
  }

  List<Widget> _results() => [
        const SizedBox(height: 6),
        for (final place in _found)
          GestureDetector(
            onTap: () => _pick(place),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                children: [
                  const Icon(Icons.north_east, size: 12, color: Brand.dim),
                  const SizedBox(width: 8),
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

  Widget _kindTab(String kind, IconData icon, String label) {
    final on = _kind == kind;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            _kind = kind;
            _fare.clear();
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

  /// What the trip is worth, and the passenger says so on every request.
  ///
  /// When there is a route to measure, the box opens with that price already
  /// in it and they may change it. When there is not — no destination, or one
  /// the map has never heard of — the box is empty and the number they write
  /// is the whole of what the motari is agreeing to.
  Widget _fareLine() {
    final quote = _quote;
    final min = _minFare;
    final named = _namedFare;
    final tooLittle = named != null && min > 0 && named < min;
    final priced = _measurable && quote?.quotedFareRwf != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(t('ask.name_your_price'), style: Brand.micro),
            const Spacer(),
            if (priced && quote!.distanceM != null)
              Text(
                '${km(quote.distanceM)} · ${t('ask.suggested')}',
                style: Brand.micro,
              )
            else if (quote != null && !priced)
              Text(
                t('ask.meter_card', {
                  'base': rwf(quote.baseFareRwf),
                  'perKm': rwf(quote.perKmRwf),
                }),
                style: Brand.micro,
              ),
          ],
        ),
        const SizedBox(height: 5),
        TextField(
          controller: _fare,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (_) => setState(() => _fareTouched = true),
          style: const TextStyle(
              color: Brand.orange, fontSize: 17, fontWeight: FontWeight.w900),
          decoration: InputDecoration(
            hintText: min > 0 ? t('ask.at_least', {'amount': rwf(min)}) : 'RWF',
            prefixIcon: const Padding(
              padding: EdgeInsets.only(left: 12, right: 8),
              child: Center(
                widthFactor: 0,
                child: Text(
                  'RWF',
                  style: TextStyle(
                      color: Brand.dim, fontSize: 11, fontWeight: FontWeight.w800),
                ),
              ),
            ),
            prefixIconConstraints: const BoxConstraints(minWidth: 30),
          ),
        ),
        if (tooLittle) ...[
          const SizedBox(height: 4),
          Text(
            t('ask.too_little', {'amount': rwf(min)}),
            style: const TextStyle(color: Brand.amber, fontSize: 11),
          ),
        ],
      ],
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
