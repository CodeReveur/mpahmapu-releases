/// The shapes the ride API speaks in. Only the fields the app actually uses are
/// parsed; anything else the server sends is ignored on purpose, so a backend
/// addition never breaks a released app.
library;

class MotariProfile {
  final String plateNumber;
  final String? brandModel;
  final bool verified;
  final bool online;
  final bool courier;
  final bool instantPayout;
  final String payoutMethod;
  final String? payoutPhone;

  /// "MTN MoMo" or "Airtel Money", worked out by the server from the number.
  final String? payoutOperator;

  /// What one withdrawal costs, and how much of the balance is bonus money
  /// that comes out without paying it.
  final int withdrawFeeRwf;
  final int bonusFreeRwf;
  final int totalRides;

  const MotariProfile({
    required this.plateNumber,
    this.brandModel,
    required this.verified,
    required this.online,
    required this.courier,
    required this.instantPayout,
    required this.payoutMethod,
    this.payoutPhone,
    this.payoutOperator,
    this.withdrawFeeRwf = 0,
    this.bonusFreeRwf = 0,
    required this.totalRides,
  });

  factory MotariProfile.fromJson(Map<String, dynamic> j) => MotariProfile(
        plateNumber: j['plateNumber'] as String? ?? '',
        brandModel: j['brandModel'] as String?,
        verified: j['verified'] as bool? ?? false,
        online: j['online'] as bool? ?? false,
        courier: j['courier'] as bool? ?? true,
        instantPayout: j['instantPayout'] as bool? ?? false,
        payoutMethod: j['payoutMethod'] as String? ?? 'MTN_MOMO',
        payoutPhone: j['payoutPhone'] as String?,
        payoutOperator: j['payoutOperator'] as String?,
        withdrawFeeRwf: (j['withdrawFeeRwf'] as num?)?.toInt() ?? 0,
        bonusFreeRwf: (j['bonusFreeRwf'] as num?)?.toInt() ?? 0,
        totalRides: (j['totalRides'] as num?)?.toInt() ?? 0,
      );
}

/// A ride the motari is running, as the driver sees it.
class Ride {
  final String id;
  final String status;
  final String kind;
  final String fareMode;
  final String? parcelNote;
  final String passengerName;
  final String? passengerPhone;
  final double pickupLat;
  final double pickupLng;
  final String? pickupName;
  final double? destLat;
  final double? destLng;
  final String? destName;
  final int baseFareRwf;
  final int perKmRwf;
  final int? quotedFareRwf;
  final int? offeredFareRwf;
  final int? finalFareRwf;
  final double riddenDistanceM;
  final String? paymentStatus;
  final String? paymentMethod;
  final bool payViaPlatform;
  final int? rating;
  /// This motari's own rating of the passenger, once given.
  /// A parcel: when the motari took it, said they delivered it, and it was agreed.
  final DateTime? pickedUpAt;
  final DateTime? deliveredAt;
  final DateTime? deliveryConfirmedAt;
  final DateTime? deliveryDisputedAt;
  final int? passengerRating;
  /// Set once the passenger has been asked to pay, near the destination.
  final bool payDue;
  /// When the passenger said they paid cash; the grace period runs from here.
  final DateTime? cashDeclaredAt;
  final DateTime? requestedAt;

  const Ride({
    required this.id,
    required this.status,
    required this.kind,
    required this.fareMode,
    this.parcelNote,
    required this.passengerName,
    this.passengerPhone,
    required this.pickupLat,
    required this.pickupLng,
    this.pickupName,
    this.destLat,
    this.destLng,
    this.destName,
    required this.baseFareRwf,
    required this.perKmRwf,
    this.quotedFareRwf,
    this.offeredFareRwf,
    this.finalFareRwf,
    required this.riddenDistanceM,
    this.paymentStatus,
    this.paymentMethod,
    required this.payViaPlatform,
    this.rating,
    this.pickedUpAt,
    this.deliveredAt,
    this.deliveryConfirmedAt,
    this.deliveryDisputedAt,
    this.passengerRating,
    this.payDue = false,
    this.cashDeclaredAt,
    this.requestedAt,
  });

  bool get isCourier => kind == 'COURIER';

  /// What this ride is worth right now: the settled fare, else the price the
  /// passenger named, else the quote.
  int? get fareRwf => finalFareRwf ?? offeredFareRwf ?? quotedFareRwf;

  factory Ride.fromJson(Map<String, dynamic> j) => Ride(
        id: j['id'] as String,
        status: j['status'] as String? ?? 'SEARCHING',
        kind: j['kind'] as String? ?? 'RIDE',
        fareMode: j['fareMode'] as String? ?? 'METERED',
        parcelNote: j['parcelNote'] as String?,
        passengerName: j['passengerName'] as String? ?? '',
        passengerPhone: j['passengerPhone'] as String?,
        pickupLat: (j['pickupLat'] as num).toDouble(),
        pickupLng: (j['pickupLng'] as num).toDouble(),
        pickupName: j['pickupName'] as String?,
        destLat: (j['destLat'] as num?)?.toDouble(),
        destLng: (j['destLng'] as num?)?.toDouble(),
        destName: j['destName'] as String?,
        baseFareRwf: (j['baseFareRwf'] as num?)?.toInt() ?? 0,
        perKmRwf: (j['perKmRwf'] as num?)?.toInt() ?? 0,
        quotedFareRwf: (j['quotedFareRwf'] as num?)?.toInt(),
        offeredFareRwf: (j['offeredFareRwf'] as num?)?.toInt(),
        finalFareRwf: (j['finalFareRwf'] as num?)?.toInt(),
        riddenDistanceM: (j['riddenDistanceM'] as num?)?.toDouble() ?? 0,
        paymentStatus: j['paymentStatus'] as String?,
        paymentMethod: j['paymentMethod'] as String?,
        payViaPlatform: j['payViaPlatform'] as bool? ?? false,
        rating: (j['rating'] as num?)?.toInt(),
        pickedUpAt: DateTime.tryParse(j['pickedUpAt'] as String? ?? ''),
        deliveredAt: DateTime.tryParse(j['deliveredAt'] as String? ?? ''),
        deliveryConfirmedAt: DateTime.tryParse(j['deliveryConfirmedAt'] as String? ?? ''),
        deliveryDisputedAt: DateTime.tryParse(j['deliveryDisputedAt'] as String? ?? ''),
        passengerRating: (j['passengerRating'] as num?)?.toInt(),
        payDue: j['payDue'] as bool? ?? false,
        cashDeclaredAt: DateTime.tryParse(j['cashDeclaredAt'] as String? ?? ''),
        requestedAt: DateTime.tryParse(j['requestedAt'] as String? ?? ''),
      );
}

/// A dispatch offer held by this motari alone, until its window closes.
class Offer {
  final String rideId;
  final String passengerName;
  final String kind;
  final String? parcelNote;
  final double pickupLat;
  final double pickupLng;
  final String? pickupName;
  final String? destName;
  /// Null when the destination is only a name, with no place on the map.
  final double? destLat;
  final double? destLng;
  final int? quotedFareRwf;
  final int? offeredFareRwf;
  final double distanceToPickupM;
  final int expiresInSeconds;

  const Offer({
    required this.rideId,
    required this.passengerName,
    required this.kind,
    this.parcelNote,
    required this.pickupLat,
    required this.pickupLng,
    this.pickupName,
    this.destName,
    this.destLat,
    this.destLng,
    this.quotedFareRwf,
    this.offeredFareRwf,
    required this.distanceToPickupM,
    required this.expiresInSeconds,
  });

  bool get isCourier => kind == 'COURIER';
  int? get fareRwf => offeredFareRwf ?? quotedFareRwf;

  factory Offer.fromJson(Map<String, dynamic> j) => Offer(
        rideId: j['rideId'] as String,
        passengerName: j['passengerName'] as String? ?? '',
        kind: j['kind'] as String? ?? 'RIDE',
        parcelNote: j['parcelNote'] as String?,
        pickupLat: (j['pickupLat'] as num).toDouble(),
        pickupLng: (j['pickupLng'] as num).toDouble(),
        pickupName: j['pickupName'] as String?,
        destName: j['destName'] as String?,
        destLat: (j['destLat'] as num?)?.toDouble(),
        destLng: (j['destLng'] as num?)?.toDouble(),
        quotedFareRwf: (j['quotedFareRwf'] as num?)?.toInt(),
        offeredFareRwf: (j['offeredFareRwf'] as num?)?.toInt(),
        distanceToPickupM: (j['distanceToPickupM'] as num?)?.toDouble() ?? 0,
        expiresInSeconds: (j['expiresInSeconds'] as num?)?.toInt() ?? 0,
      );
}

/// A SEARCHING ride within reach, listed for the taking.
class NearbyRide {
  final String id;
  final String kind;
  final String? parcelNote;
  final double pickupLat;
  final double pickupLng;
  final String? pickupName;
  final String? destName;
  /// Null when the destination is only a name, with no place on the map.
  final double? destLat;
  final double? destLng;
  final int? quotedFareRwf;
  final int? offeredFareRwf;
  final double distanceToPickupM;

  const NearbyRide({
    required this.id,
    required this.kind,
    this.parcelNote,
    required this.pickupLat,
    required this.pickupLng,
    this.pickupName,
    this.destName,
    this.destLat,
    this.destLng,
    this.quotedFareRwf,
    this.offeredFareRwf,
    required this.distanceToPickupM,
  });

  bool get isCourier => kind == 'COURIER';
  int? get fareRwf => offeredFareRwf ?? quotedFareRwf;

  factory NearbyRide.fromJson(Map<String, dynamic> j) => NearbyRide(
        id: j['id'] as String,
        kind: j['kind'] as String? ?? 'RIDE',
        parcelNote: j['parcelNote'] as String?,
        pickupLat: (j['pickupLat'] as num).toDouble(),
        pickupLng: (j['pickupLng'] as num).toDouble(),
        pickupName: j['pickupName'] as String?,
        destName: j['destName'] as String?,
        destLat: (j['destLat'] as num?)?.toDouble(),
        destLng: (j['destLng'] as num?)?.toDouble(),
        quotedFareRwf: (j['quotedFareRwf'] as num?)?.toInt(),
        offeredFareRwf: (j['offeredFareRwf'] as num?)?.toInt(),
        distanceToPickupM: (j['distanceToPickupM'] as num?)?.toDouble() ?? 0,
      );
}

/// The daily platform fee: what is owed, and whether it has paused the account.
class Fees {
  final int dueDays;
  final int dueAmountRwf;
  final bool paused;
  final bool paymentPending;
  final int todayRides;
  final int minRides;
  final int dailyFeeRwf;
  final int maxDueDays;

  const Fees({
    required this.dueDays,
    required this.dueAmountRwf,
    required this.paused,
    required this.paymentPending,
    required this.todayRides,
    required this.minRides,
    required this.dailyFeeRwf,
    required this.maxDueDays,
  });

  factory Fees.fromJson(Map<String, dynamic> j) => Fees(
        dueDays: (j['dueDays'] as num?)?.toInt() ?? 0,
        dueAmountRwf: (j['dueAmountRwf'] as num?)?.toInt() ?? 0,
        paused: j['paused'] as bool? ?? false,
        paymentPending: j['paymentPending'] as bool? ?? false,
        todayRides: (j['todayRides'] as num?)?.toInt() ?? 0,
        minRides: (j['minRides'] as num?)?.toInt() ?? 3,
        dailyFeeRwf: (j['dailyFeeRwf'] as num?)?.toInt() ?? 500,
        maxDueDays: (j['maxDueDays'] as num?)?.toInt() ?? 3,
      );
}

/// Everything the working screen needs in one poll.
class MotariState {
  final MotariProfile? profile;
  final Ride? activeRide;
  final Offer? offer;
  final List<NearbyRide> nearby;
  final Fees? fees;

  const MotariState({
    this.profile,
    this.activeRide,
    this.offer,
    this.nearby = const [],
    this.fees,
  });

  factory MotariState.fromJson(Map<String, dynamic> j) => MotariState(
        profile: j['profile'] == null
            ? null
            : MotariProfile.fromJson(j['profile'] as Map<String, dynamic>),
        activeRide: j['activeRide'] == null
            ? null
            : Ride.fromJson(j['activeRide'] as Map<String, dynamic>),
        offer: j['offer'] == null ? null : Offer.fromJson(j['offer'] as Map<String, dynamic>),
        nearby: ((j['nearby'] as List<dynamic>?) ?? const [])
            .map((e) => NearbyRide.fromJson(e as Map<String, dynamic>))
            .toList(),
        fees: j['fees'] == null ? null : Fees.fromJson(j['fees'] as Map<String, dynamic>),
      );
}

/// One movement of money out of the wallet.
class Payout {
  final String id;
  final int amountRwf;
  final String method;
  final String phone;
  final String status;
  final DateTime? createdAt;

  const Payout({
    required this.id,
    required this.amountRwf,
    required this.method,
    required this.phone,
    required this.status,
    this.createdAt,
  });

  factory Payout.fromJson(Map<String, dynamic> j) => Payout(
        id: j['id'] as String,
        amountRwf: (j['amountRwf'] as num?)?.toInt() ?? 0,
        method: j['method'] as String? ?? 'MTN_MOMO',
        phone: j['phone'] as String? ?? '',
        status: j['status'] as String? ?? 'PENDING',
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? ''),
      );
}

/// Earnings and history for the money screen.
class MotariHistory {
  final int totalCollectedRwf;
  final int totalRides;
  final int walletBalanceRwf;
  final int totalPaidOutRwf;
  final List<Ride> rides;
  final List<Payout> payouts;

  const MotariHistory({
    required this.totalCollectedRwf,
    required this.totalRides,
    required this.walletBalanceRwf,
    required this.totalPaidOutRwf,
    required this.rides,
    required this.payouts,
  });

  factory MotariHistory.fromJson(Map<String, dynamic> j) => MotariHistory(
        totalCollectedRwf: (j['totalCollectedRwf'] as num?)?.toInt() ?? 0,
        totalRides: (j['totalRides'] as num?)?.toInt() ?? 0,
        walletBalanceRwf: (j['walletBalanceRwf'] as num?)?.toInt() ?? 0,
        totalPaidOutRwf: (j['totalPaidOutRwf'] as num?)?.toInt() ?? 0,
        rides: ((j['rides'] as List<dynamic>?) ?? const [])
            .map((e) => Ride.fromJson(e as Map<String, dynamic>))
            .toList(),
        payouts: ((j['payouts'] as List<dynamic>?) ?? const [])
            .map((e) => Payout.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}


/* ── the passenger's side ─────────────────────────────────────────────────── */

/// A place the passenger picked, or typed and we found.
class Place {
  final double latitude;
  final double longitude;
  final String label;
  final String fullName;

  const Place({
    required this.latitude,
    required this.longitude,
    required this.label,
    required this.fullName,
  });

  /// Null when the row has no usable coordinates or no name to show.
  static Place? fromNominatim(Map<String, dynamic> j) {
    final lat = double.tryParse('${j['lat']}');
    final lng = double.tryParse('${j['lon']}');
    final full = (j['display_name'] as String?)?.trim() ?? '';
    if (lat == null || lng == null || full.isEmpty) return null;
    // The first two parts are the name and its neighbourhood, which is what a
    // passenger recognises. The rest is district, province, country.
    final label = full.split(',').take(2).join(',').trim();
    if (label.isEmpty) return null;
    return Place(latitude: lat, longitude: lng, label: label, fullName: full);
  }
}

/// What a ride would cost, before asking for one.
class Quote {
  final String fareMode;
  final String kind;
  final int baseFareRwf;
  final int perKmRwf;
  final int minFareRwf;
  /// Null on a metered ride: without a destination there is no price to quote.
  final int? quotedFareRwf;
  final double? distanceM;

  const Quote({
    required this.fareMode,
    required this.kind,
    required this.baseFareRwf,
    required this.perKmRwf,
    required this.minFareRwf,
    this.quotedFareRwf,
    this.distanceM,
  });

  factory Quote.fromJson(Map<String, dynamic> j) => Quote(
        fareMode: j['fareMode'] as String? ?? 'METERED',
        kind: j['kind'] as String? ?? 'RIDE',
        baseFareRwf: (j['baseFareRwf'] as num?)?.toInt() ?? 0,
        perKmRwf: (j['perKmRwf'] as num?)?.toInt() ?? 0,
        minFareRwf: (j['minFareRwf'] as num?)?.toInt() ?? 0,
        quotedFareRwf: (j['quotedFareRwf'] as num?)?.toInt(),
        distanceM: (j['distanceM'] as num?)?.toDouble(),
      );
}

/// How much moto there is around the passenger right now.
class Supply {
  final String kind;
  final int active;
  final double? nearestM;
  final int minFareRwf;

  const Supply({
    required this.kind,
    required this.active,
    this.nearestM,
    required this.minFareRwf,
  });

  factory Supply.fromJson(Map<String, dynamic> j) => Supply(
        kind: j['kind'] as String? ?? 'RIDE',
        active: (j['active'] as num?)?.toInt() ?? 0,
        nearestM: (j['nearestM'] as num?)?.toDouble(),
        minFareRwf: (j['minFareRwf'] as num?)?.toInt() ?? 0,
      );
}

/// The motari who took the ride, as the passenger sees them.
class RideDriver {
  final String? name;
  final String? phone;
  final String? plateNumber;
  final String? brandModel;
  final double? rating;
  final double? latitude;
  final double? longitude;

  const RideDriver({
    this.name,
    this.phone,
    this.plateNumber,
    this.brandModel,
    this.rating,
    this.latitude,
    this.longitude,
  });

  factory RideDriver.fromJson(Map<String, dynamic> j) => RideDriver(
        name: j['name'] as String?,
        phone: j['phone'] as String?,
        plateNumber: j['plateNumber'] as String?,
        brandModel: j['brandModel'] as String?,
        rating: (j['rating'] as num?)?.toDouble(),
        latitude: (j['latitude'] as num?)?.toDouble(),
        longitude: (j['longitude'] as num?)?.toDouble(),
      );
}

/// The ride as the passenger sees it. Their copy carries the token, which is
/// the only thing that proves this phone owns the ride.
class PassengerRide {
  final String id;
  final String? token;
  final String status;
  final String kind;
  final String fareMode;

  final double pickupLat;
  final double pickupLng;
  final String? pickupName;
  final double? destLat;
  final double? destLng;
  final String? destName;

  final int baseFareRwf;
  final int perKmRwf;
  final int? quotedFareRwf;
  final int? offeredFareRwf;
  final int? finalFareRwf;
  final double? quotedDistanceM;
  final double riddenDistanceM;

  final String? paymentMethod;
  final String? paymentStatus;
  final bool payDue;
  final DateTime? cashDeclaredAt;
  /// A parcel: when the motari took it, said they delivered it, and it was agreed.
  final DateTime? pickedUpAt;
  final DateTime? deliveredAt;
  final DateTime? deliveryConfirmedAt;
  final DateTime? deliveryDisputedAt;

  final int? rating;

  /// How wide the search has grown while nobody has taken it yet.
  final int? searchRadiusKm;
  final int? searchSecondsLeft;
  final String? cancelledBy;
  final String? cancelReason;

  final RideDriver? driver;

  const PassengerRide({
    required this.id,
    this.token,
    required this.status,
    required this.kind,
    required this.fareMode,
    required this.pickupLat,
    required this.pickupLng,
    this.pickupName,
    this.destLat,
    this.destLng,
    this.destName,
    required this.baseFareRwf,
    required this.perKmRwf,
    this.quotedFareRwf,
    this.offeredFareRwf,
    this.finalFareRwf,
    this.quotedDistanceM,
    required this.riddenDistanceM,
    this.paymentMethod,
    this.paymentStatus,
    this.payDue = false,
    this.cashDeclaredAt,
    this.pickedUpAt,
    this.deliveredAt,
    this.deliveryConfirmedAt,
    this.deliveryDisputedAt,
    this.rating,
    this.searchRadiusKm,
    this.searchSecondsLeft,
    this.cancelledBy,
    this.cancelReason,
    this.driver,
  });

  bool get isCourier => kind == 'COURIER';

  /// Still looking for a motari to take it.
  bool get searching => status == 'SEARCHING';

  /// A motari is on it, or on the way.
  bool get live => const ['ASSIGNED', 'ARRIVED', 'IN_RIDE'].contains(status);

  /// Over, one way or another.
  /// NO_MATCH is the platform's name for a request nobody took. Waiting for an
  /// EXPIRED that is never sent left those rides looking live forever.
  bool get done => const ['CLOSED', 'CANCELLED', 'NO_MATCH'].contains(status);

  /// The fare the passenger actually owes: their own price if they named one.
  int? get fareRwf => finalFareRwf ?? offeredFareRwf ?? quotedFareRwf;

  factory PassengerRide.fromJson(Map<String, dynamic> j) => PassengerRide(
        id: j['id'] as String? ?? '',
        token: j['token'] as String?,
        status: j['status'] as String? ?? 'SEARCHING',
        kind: j['kind'] as String? ?? 'RIDE',
        fareMode: j['fareMode'] as String? ?? 'METERED',
        pickupLat: (j['pickupLat'] as num?)?.toDouble() ?? 0,
        pickupLng: (j['pickupLng'] as num?)?.toDouble() ?? 0,
        pickupName: j['pickupName'] as String?,
        destLat: (j['destLat'] as num?)?.toDouble(),
        destLng: (j['destLng'] as num?)?.toDouble(),
        destName: j['destName'] as String?,
        baseFareRwf: (j['baseFareRwf'] as num?)?.toInt() ?? 0,
        perKmRwf: (j['perKmRwf'] as num?)?.toInt() ?? 0,
        quotedFareRwf: (j['quotedFareRwf'] as num?)?.toInt(),
        offeredFareRwf: (j['offeredFareRwf'] as num?)?.toInt(),
        finalFareRwf: (j['finalFareRwf'] as num?)?.toInt(),
        quotedDistanceM: (j['quotedDistanceM'] as num?)?.toDouble(),
        riddenDistanceM: (j['riddenDistanceM'] as num?)?.toDouble() ?? 0,
        paymentMethod: j['paymentMethod'] as String?,
        paymentStatus: j['paymentStatus'] as String?,
        payDue: j['payDue'] as bool? ?? false,
        cashDeclaredAt: DateTime.tryParse(j['cashDeclaredAt'] as String? ?? ''),
        pickedUpAt: DateTime.tryParse(j['pickedUpAt'] as String? ?? ''),
        deliveredAt: DateTime.tryParse(j['deliveredAt'] as String? ?? ''),
        deliveryConfirmedAt: DateTime.tryParse(j['deliveryConfirmedAt'] as String? ?? ''),
        deliveryDisputedAt: DateTime.tryParse(j['deliveryDisputedAt'] as String? ?? ''),
        rating: (j['rating'] as num?)?.toInt(),
        searchRadiusKm: (j['searchRadiusKm'] as num?)?.toInt(),
        searchSecondsLeft: (j['searchSecondsLeft'] as num?)?.toInt(),
        cancelledBy: j['cancelledBy'] as String?,
        cancelReason: j['cancelReason'] as String?,
        driver: j['driver'] == null
            ? null
            : RideDriver.fromJson(j['driver'] as Map<String, dynamic>),
      );
}
