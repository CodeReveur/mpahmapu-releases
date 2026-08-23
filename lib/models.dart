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
