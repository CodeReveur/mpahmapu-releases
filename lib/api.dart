import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Raised when the API answers with a message meant for the driver to read.
class ApiException implements Exception {
  final String message;
  final int status;
  const ApiException(this.message, this.status);
  @override
  String toString() => message;
}

/// The MpahMapu ride API, as the Motari app uses it.
///
/// Unlike the browser, the app talks to the backend directly: there is no
/// same-origin gateway to hide behind, so [baseUrl] points at the API itself
/// and can be pointed at a laptop during development with --dart-define.
class Api {
  static const String baseUrl = String.fromEnvironment(
    'MOTARI_API',
    defaultValue: 'https://backend.mpahmapu.com',
  );

  static const _accessKey = 'access_token';
  static const _refreshKey = 'refresh_token';
  static const _nameKey = 'user_name';
  static const _emailKey = 'user_email';

  String? _access;
  String? _refresh;
  String? userName;

  /// The address on the account. Support messages are threaded by it, so a
  /// complaint sent without one is a complaint the server refuses.
  String? userEmail;

  bool get signedIn => _access != null;

  /// Restore the session saved on this device. A motari stays signed in until
  /// they log out, so this is what makes the app open straight into work.
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    _access = prefs.getString(_accessKey);
    _refresh = prefs.getString(_refreshKey);
    userName = prefs.getString(_nameKey);
    userEmail = prefs.getString(_emailKey);
  }

  Future<void> _saveSession(Map<String, dynamic> data) async {
    _access = data['accessToken'] as String?;
    _refresh = data['refreshToken'] as String?;
    final user = data['user'] as Map<String, dynamic>?;
    userName = user?['name'] as String?;
    userEmail = user?['email'] as String?;

    final prefs = await SharedPreferences.getInstance();
    if (_access != null) await prefs.setString(_accessKey, _access!);
    if (_refresh != null) await prefs.setString(_refreshKey, _refresh!);
    if (userName != null) await prefs.setString(_nameKey, userName!);
    if (userEmail != null) await prefs.setString(_emailKey, userEmail!);
  }

  Future<void> signOut() async {
    _access = null;
    _refresh = null;
    userName = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_accessKey);
    await prefs.remove(_refreshKey);
    await prefs.remove(_nameKey);
  }

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_access != null) 'Authorization': 'Bearer $_access',
      };

  /// Unwraps the ApiResponse envelope every endpoint answers with, turning a
  /// failure into an [ApiException] carrying the server's own wording.
  dynamic _unwrap(http.Response res) {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException('The server is unreachable. Try again.', res.statusCode);
    }
    if (res.statusCode >= 400 || body['success'] == false) {
      throw ApiException(
        body['message'] as String? ?? 'Something went wrong. Try again.',
        res.statusCode,
      );
    }
    return body['data'];
  }

  /// A call made with no session at all: guest passengers request and track
  /// rides by token, and an anonymous 401 has no session to refresh.
  Future<dynamic> _public(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    final uri = _uri(path, query);
    const headers = {'Content-Type': 'application/json', 'Accept': 'application/json'};
    late http.Response res;
    try {
      res = switch (method) {
        'POST' => await http.post(uri, headers: headers, body: jsonEncode(body ?? {})),
        _ => await http.get(uri, headers: headers),
      };
    } catch (_) {
      throw const ApiException('No connection. Check your data and try again.', 0);
    }
    return _unwrap(res);
  }

  /// One request, retried once with a refreshed token when the session has
  /// merely expired — a driver should never be thrown out mid-shift.
  Future<dynamic> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
    bool retry = true,
  }) async {
    final uri = _uri(path, query);
    late http.Response res;
    try {
      res = switch (method) {
        'POST' => await http.post(uri, headers: _headers, body: jsonEncode(body ?? {})),
        _ => await http.get(uri, headers: _headers),
      };
    } catch (_) {
      throw const ApiException('No connection. Check your data and try again.', 0);
    }

    if (res.statusCode == 401 && retry && _refresh != null) {
      if (await _refreshSession()) {
        return _send(method, path, body: body, query: query, retry: false);
      }
    }
    return _unwrap(res);
  }

  Future<bool> _refreshSession() async {
    try {
      final res = await http.post(
        _uri('/api/auth/refresh'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'refreshToken': _refresh}),
      );
      if (res.statusCode >= 400) return false;
      final data = (jsonDecode(res.body) as Map<String, dynamic>)['data'];
      await _saveSession(data as Map<String, dynamic>);
      return _access != null;
    } catch (_) {
      return false;
    }
  }

  // ── Sign in ───────────────────────────────────────────────────────────────

  /// Signs in and keeps the session. Returns the login result so the caller can
  /// see whether a code step is still in the way.
  Future<Map<String, dynamic>> signIn(String email, String password) async {
    final data = await _send('POST', '/api/auth/login',
        body: {'email': email, 'password': password}) as Map<String, dynamic>;
    final needsCode = data['requires2fa'] == true ||
        data['requiresEmailVerification'] == true ||
        data['requires2faSetup'] == true;
    if (!needsCode) await _saveSession(data);
    return data;
  }

  /// Open an account from inside the app. The role is fixed: this app makes
  /// motari, and nothing else.
  ///
  /// The session that comes back is kept rather than discarded. It used to be
  /// thrown away and picked up again after the email code, which meant the moto
  /// details typed on the form could not be written down until then, and were
  /// lost outright by anybody who closed the app at the code screen. Whether
  /// the address still needs confirming is the caller's next question, and the
  /// answer is in what comes back.
  Future<Map<String, dynamic>> register({
    required String name,
    required String email,
    required String phone,
    required String password,
    String? plateNumber,
    String? brandModel,
    String? referralCode,
  }) async {
    final data = await _send('POST', '/api/auth/register', body: {
      'name': name,
      'email': email,
      'phone': phone,
      'password': password,
      'role': 'MOTARI',
      // The moto travels with the account. Sent here rather than saved by a
      // second call, so a plate the regulator refuses fails the registration
      // instead of leaving an account that exists and cannot ride.
      if (plateNumber != null && plateNumber.isNotEmpty) 'plateNumber': plateNumber,
      if (brandModel != null && brandModel.isNotEmpty) 'brandModel': brandModel,
      if (referralCode != null && referralCode.isNotEmpty) 'referralCode': referralCode,
    }) as Map<String, dynamic>;
    await _saveSession(data);
    return data;
  }

  /// Finishes a login that asked for an authenticator code.
  Future<void> verifyTotp(String tempToken, String code) async {
    final data = await _send('POST', '/api/auth/2fa/authenticate',
        body: {'tempToken': tempToken, 'code': code}) as Map<String, dynamic>;
    await _saveSession(data);
  }

  Future<void> verifyEmail(String email, String code) =>
      _send('POST', '/api/auth/verify-email', body: {'email': email, 'code': code});

  Future<void> resendCode(String email) =>
      _send('POST', '/api/auth/resend-otp', body: {'email': email});

  /// Start a password reset. The server emails a link to the website, which is
  /// where the new password is actually set: there is one reset flow, and the
  /// app points at it rather than inventing a second one.
  Future<void> forgotPassword(String email) =>
      _public('POST', '/api/auth/forgot-password', body: {'email': email});

  // ── Asking for a motari (guest passenger, no account) ─────────────────────

  /// What a ride would cost. With no destination this is the rate card for a
  /// metered ride rather than a price.
  Future<Quote> quote({
    required double pickupLat,
    required double pickupLng,
    double? destLat,
    double? destLng,
    String kind = 'RIDE',
  }) async =>
      Quote.fromJson(await _public('GET', '/api/rides/public/quote', query: {
        'pickupLat': '$pickupLat',
        'pickupLng': '$pickupLng',
        if (destLat != null) 'destLat': '$destLat',
        if (destLng != null) 'destLng': '$destLng',
        'kind': kind,
      }) as Map<String, dynamic>);

  /// How many motari are around, so the passenger knows before they ask.
  Future<Supply> supply(double lat, double lng, {String kind = 'RIDE'}) async =>
      Supply.fromJson(await _public('GET', '/api/rides/public/supply', query: {
        'lat': '$lat',
        'lng': '$lng',
        'kind': kind,
      }) as Map<String, dynamic>);

  /// Ask for a motari. No account: a name and a phone number are the whole of
  /// it, and the ride comes back with the token that tracks it.
  Future<PassengerRide> requestRide({
    required String name,
    required String phone,
    required double pickupLat,
    required double pickupLng,
    String? pickupName,
    double? destLat,
    double? destLng,
    String? destName,
    String kind = 'RIDE',
    String? parcelNote,
    int? offeredFareRwf,
    bool payViaPlatform = false,
  }) async =>
      PassengerRide.fromJson(await _public('POST', '/api/rides/public', body: {
        'name': name,
        'phone': phone,
        'pickupLat': pickupLat,
        'pickupLng': pickupLng,
        'pickupName': pickupName,
        'destLat': destLat,
        'destLng': destLng,
        'destName': destName,
        'kind': kind,
        'parcelNote': parcelNote,
        'offeredFareRwf': offeredFareRwf,
        'payViaPlatform': payViaPlatform,
      }) as Map<String, dynamic>);

  Future<PassengerRide> trackRide(String token) async => PassengerRide.fromJson(
      await _public('GET', '/api/rides/public/$token') as Map<String, dynamic>);

  Future<PassengerRide> cancelRide(String token, {String? reason}) async =>
      PassengerRide.fromJson(await _public('POST', '/api/rides/public/$token/cancel',
          body: {'reason': reason}) as Map<String, dynamic>);

  /// Pay through the platform: a mobile money prompt reaches the phone.
  Future<PassengerRide> payRide(String token, {String? phone}) async =>
      PassengerRide.fromJson(await _public('POST', '/api/rides/public/$token/pay',
          body: {'phone': phone}) as Map<String, dynamic>);

  /// The passenger's own position, which is what lets a ride start itself when
  /// the two phones pull away from the pickup together.
  Future<PassengerRide> sendPosition(String token, double lat, double lng) async =>
      PassengerRide.fromJson(await _public('POST', '/api/rides/public/$token/position',
          body: {'lat': lat, 'lng': lng}) as Map<String, dynamic>);

  /// Paying in cash. It stands on its own unless the motari says otherwise.
  Future<PassengerRide> declareCash(String token) async => PassengerRide.fromJson(
      await _public('POST', '/api/rides/public/$token/cash') as Map<String, dynamic>);

  /// The owner agreeing the parcel arrived.
  Future<PassengerRide> confirmDelivery(String token) async =>
      PassengerRide.fromJson(await _public(
          'POST', '/api/rides/public/$token/confirm-delivery') as Map<String, dynamic>);

  /// The owner saying it never arrived. Support takes it from there.
  Future<PassengerRide> disputeDelivery(String token, {String? note}) async =>
      PassengerRide.fromJson(await _public('POST', '/api/rides/public/$token/dispute-delivery',
          body: {'note': note}) as Map<String, dynamic>);

  Future<PassengerRide> rateRide(String token, int stars) async =>
      PassengerRide.fromJson(await _public('POST', '/api/rides/public/$token/rate',
          body: {'stars': stars}) as Map<String, dynamic>);

  /// Place search for the pickup and destination fields.
  ///
  /// The web goes through its own proxy because a browser cannot set a
  /// User-Agent and Nominatim throttles anonymous browser traffic hard. An app
  /// can set one, so it asks directly, biased to where the passenger is.
  Future<List<Place>> searchPlaces(String query, {double? lat, double? lng}) async {
    final q = query.trim();
    if (q.length < 2) return const [];
    const box = 0.22; // roughly 25 km, a bias rather than a fence
    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'format': 'jsonv2',
      'limit': '6',
      'countrycodes': 'rw',
      'addressdetails': '1',
      'q': q,
      if (lat != null && lng != null) ...{
        'viewbox': '${lng - box},${lat + box},${lng + box},${lat - box}',
        'bounded': '0',
      },
    });
    try {
      final res = await http.get(uri, headers: {
        'User-Agent': 'MpahMapu-Motari/1.0 (https://www.mpahmapu.com; support@mpahmapu.com)',
        'Accept-Language': 'en',
      }).timeout(const Duration(seconds: 6));
      if (res.statusCode >= 400) return const [];
      final raw = jsonDecode(res.body);
      if (raw is! List) return const [];
      return raw
          .map((d) => Place.fromNominatim(d as Map<String, dynamic>))
          .whereType<Place>()
          .toList();
    } catch (_) {
      // Type-ahead that fails is silent: the passenger can still tap the map.
      return const [];
    }
  }

  /// The name of a point, so a pickup taken from the phone reads as a place
  /// rather than a pair of numbers. Null when the lookup finds nothing, which
  /// the caller treats as "my location" and carries on.
  Future<String?> nameOfPlace(double lat, double lng) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
      'format': 'jsonv2',
      'lat': '$lat',
      'lon': '$lng',
      'zoom': '17',
      'addressdetails': '1',
    });
    try {
      final res = await http.get(uri, headers: {
        'User-Agent': 'MpahMapu-Motari/1.0 (https://www.mpahmapu.com; support@mpahmapu.com)',
        'Accept-Language': 'en',
      }).timeout(const Duration(seconds: 6));
      if (res.statusCode >= 400) return null;
      final j = jsonDecode(res.body);
      if (j is! Map<String, dynamic>) return null;
      final full = (j['display_name'] as String?)?.trim() ?? '';
      if (full.isEmpty) return null;
      return full.split(',').take(2).join(',').trim();
    } catch (_) {
      return null;
    }
  }
  // ── The working screen ────────────────────────────────────────────────────

  Future<MotariState> state() async =>
      MotariState.fromJson(await _send('GET', '/api/rides/driver/state') as Map<String, dynamic>);

  Future<MotariHistory> history() async => MotariHistory.fromJson(
      await _send('GET', '/api/rides/driver/history') as Map<String, dynamic>);

  /// What this motari has earned, is close to earning, and has been paid for
  /// bringing other people in. One call, because it is one screen.
  Future<Map<String, dynamic>> rewards() async =>
      await _send('GET', '/api/rides/driver/rewards') as Map<String, dynamic>;

  /// Move everything waiting into the wallet. Until claimed, a bonus is a
  /// promise rather than money.
  Future<void> claimBonuses() async =>
      await _send('POST', '/api/wallet/bonuses/claim');

  Future<MotariState> saveProfile({
    required String plateNumber,
    String? brandModel,
    String? legalName,
    String? licenseNumber,
  }) async =>
      MotariState.fromJson(await _send('POST', '/api/rides/driver/profile', body: {
        'plateNumber': plateNumber,
        'brandModel': brandModel,
        'legalName': legalName,
        'licenseNumber': licenseNumber,
      }) as Map<String, dynamic>);

  /// Take money out of the wallet to the number on the account.
  ///
  /// No amount means everything that can go. There is no code to confirm,
  /// because the money can only reach the number already on the account:
  /// there is nothing for a code to protect.
  Future<MotariState> withdraw({int? amount}) async =>
      MotariState.fromJson(await _send('POST', '/api/rides/driver/withdraw',
          body: amount == null ? <String, dynamic>{} : {'amount': amount}) as Map<String, dynamic>);

  Future<MotariState> setOnline(bool online) async => MotariState.fromJson(
      await _send('POST', '/api/rides/driver/online', body: {'online': online})
          as Map<String, dynamic>);

  Future<MotariState> setCourier(bool courier) async => MotariState.fromJson(
      await _send('POST', '/api/rides/driver/courier', body: {'courier': courier})
          as Map<String, dynamic>);

  Future<MotariState> setPayout({
    bool? instantPayout,
    String? payoutMethod,
    String? payoutPhone,
  }) async =>
      MotariState.fromJson(await _send('POST', '/api/rides/driver/payout', body: {
        'instantPayout': ?instantPayout,
        'payoutMethod': ?payoutMethod,
        'payoutPhone': ?payoutPhone,
      }) as Map<String, dynamic>);

  /// The GPS heartbeat: presence for dispatch, and the meter while riding.
  Future<MotariState> heartbeat(double lat, double lng) async => MotariState.fromJson(
      await _send('POST', '/api/rides/driver/heartbeat', body: {'lat': lat, 'lng': lng})
          as Map<String, dynamic>);

  Future<MotariState> _rideAction(String rideId, String action, [Map<String, dynamic>? body]) async =>
      MotariState.fromJson(
          await _send('POST', '/api/rides/driver/$rideId/$action', body: body)
              as Map<String, dynamic>);

  Future<MotariState> accept(String rideId) => _rideAction(rideId, 'accept');
  Future<MotariState> decline(String rideId) => _rideAction(rideId, 'decline');
  Future<MotariState> arrived(String rideId) => _rideAction(rideId, 'arrived');

  /// The parcel is in the motari's hands: for a courier job this stands in for
  /// both arriving and starting.
  Future<MotariState> parcelReceived(String rideId) =>
      _rideAction(rideId, 'parcel-received');

  /// The motari saying the parcel was delivered. The owner has a say after this.
  Future<MotariState> parcelDelivered(String rideId) =>
      _rideAction(rideId, 'parcel-delivered');
  Future<MotariState> start(String rideId) => _rideAction(rideId, 'start');
  Future<MotariState> complete(String rideId) => _rideAction(rideId, 'complete');
  Future<MotariState> paid(String rideId, String method) =>
      _rideAction(rideId, 'paid', {'method': method});
  Future<MotariState> handBack(String rideId) => _rideAction(rideId, 'cancel');

  /// The motari rating the passenger, once the ride is done.
  Future<MotariState> ratePassenger(String rideId, int stars) =>
      _rideAction(rideId, 'rate', {'stars': stars});

  /// The motari saying a declared cash payment never arrived.
  Future<MotariState> denyCash(String rideId) => _rideAction(rideId, 'not-paid');

  /// Pay the outstanding daily fee; a mobile money prompt follows on the phone.
  Future<MotariState> payFees({String? phone}) async => MotariState.fromJson(
      await _send('POST', '/api/rides/driver/fees/pay', body: {'phone': phone})
          as Map<String, dynamic>);

  /// Anything a motari needs to tell support: a complaint, or a number change.
  Future<void> contactSupport({
    required String name,
    required String email,
    required String subject,
    required String message,
  }) =>
      _send('POST', '/api/contact',
          body: {'name': name, 'email': email, 'subject': subject, 'message': message});
}
