import 'package:flutter/material.dart';

import '../i18n.dart';
import '../models.dart';
import '../theme.dart';

/// The sheet in front of the map: register the moto, wait for work, or run the
/// ride in hand. It shows one thing at a time, because a motari reading it is
/// usually stopped at the roadside with the engine running.
class RidePanel extends StatefulWidget {
  final MotariState? state;
  final bool busy;
  final String? error;
  final void Function(String rideId) onAccept;
  final void Function(String rideId) onArrived;
  final void Function(String rideId) onComplete;
  final void Function(String rideId) onParcelReceived;
  final void Function(String rideId) onParcelDelivered;
  final void Function(String rideId) onConfirmCash;
  final void Function(String rideId) onDenyCash;
  final void Function(String rideId) onRingPassenger;
  final void Function(String rideId, int stars) onRate;
  final void Function(String rideId) onHandBack;
  final VoidCallback onGoOnline;
  final void Function(String phone) onCall;
  final void Function(String plate, String? brand, String? legalName) onSaveProfile;
  final VoidCallback onOpenMoney;
  final VoidCallback? onOpenTrips;
  final VoidCallback onOpenSettings;

  const RidePanel({
    super.key,
    required this.state,
    required this.busy,
    required this.error,
    required this.onAccept,
    required this.onArrived,
    required this.onComplete,
    required this.onParcelReceived,
    required this.onParcelDelivered,
    required this.onConfirmCash,
    required this.onDenyCash,
    required this.onRingPassenger,
    required this.onRate,
    required this.onHandBack,
    required this.onGoOnline,
    required this.onCall,
    required this.onSaveProfile,
    required this.onOpenMoney,
    this.onOpenTrips,
    required this.onOpenSettings,
  });

  @override
  State<RidePanel> createState() => _RidePanelState();
}

class _RidePanelState extends State<RidePanel> {
  final _plate = TextEditingController();
  final _brand = TextEditingController();
  final _legalName = TextEditingController();
  bool _collapsed = false;
  String _currentTab = 'rides';

  @override
  void dispose() {
    _plate.dispose();
    _brand.dispose();
    _legalName.dispose();
    super.dispose();
  }

  MotariProfile? get _profile => widget.state?.profile;
  Ride? get _ride => widget.state?.activeRide;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.62),
      decoration: BoxDecoration(
        color: Brand.black.withValues(alpha: 0.96),
        border: const Border(top: BorderSide(color: Brand.line)),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: () => setState(() => _collapsed = !_collapsed),
                behavior: HitTestBehavior.opaque,
                child: Column(
                  children: [
                    Container(
                      width: 34,
                      height: 3,
                      decoration: BoxDecoration(
                        color: const Color(0xFF333333),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    Icon(
                      _collapsed ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                      size: 16,
                      color: Brand.dim,
                    ),
                  ],
                ),
              ),
              if (_collapsed) _summary() else ..._body(),
              if (widget.error != null) ...[
                const SizedBox(height: 10),
                Text(widget.error!, style: const TextStyle(color: Brand.red, fontSize: 11.5)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  bool get _isMandatoryOnline {
    final now = DateTime.now().toUtc();
    final kigaliHour = (now.hour + 2) % 24;
    return kigaliHour >= 5 && kigaliHour < 21;
  }

  Widget _tabBar() => Container(
        margin: const EdgeInsets.only(top: 4, bottom: 12),
        child: Row(
          children: [
            _tabButton('rides', t('panel.tab_rides')),
            const SizedBox(width: 6),
            _tabButton('money', t('panel.tab_money')),
            const SizedBox(width: 6),
            _tabButton('trips', t('panel.tab_trips')),
            const SizedBox(width: 6),
            _tabButton('settings', t('panel.tab_settings')),
          ],
        ),
      );

  Widget _tabButton(String key, String label) {
    final active = _currentTab == key;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          if (key == 'money') {
            widget.onOpenMoney();
          } else if (key == 'trips') {
            (widget.onOpenTrips ?? widget.onOpenMoney)();
          } else if (key == 'settings') {
            widget.onOpenSettings();
          } else {
            setState(() => _currentTab = key);
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
          decoration: BoxDecoration(
            color: active ? Brand.orange : const Color(0xFF141414),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active ? Brand.orange : const Color(0xFF2E2E2E),
            ),
          ),
          child: Center(
            child: Text(
              label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: active ? Colors.black : const Color(0xFF888888),
                fontSize: 9.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _summary() {
    final ride = _ride;
    final nearby = widget.state?.nearby.length ?? 0;
    final online = _isMandatoryOnline || (_profile?.online ?? false);
    final text = ride != null
        ? t('panel.on_ride')
        : online
            ? t('panel.waiting_nearby', {'count': nearby})
            : t('panel.offline');
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        text,
        style: const TextStyle(color: Brand.text, fontSize: 12, fontWeight: FontWeight.w800),
      ),
    );
  }

  List<Widget> _body() {
    return [
      _tabBar(),
      if (_profile == null)
        ..._registerMoto()
      else if (_ride != null)
        ..._activeRide(_ride!)
      else
        ..._waiting(),
    ];
  }

  /* ── no moto yet ──────────────────────────────────────────────────────── */

  List<Widget> _registerMoto() => [
        const SizedBox(height: 4),
        Text(t('panel.register_moto'),
            style: const TextStyle(color: Brand.muted, fontSize: 12)),
        const SizedBox(height: 10),
        TextField(
          controller: _legalName,
          style: const TextStyle(color: Brand.text, fontSize: 13),
          decoration: InputDecoration(hintText: t('panel.legal_name')),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _plate,
          textCapitalization: TextCapitalization.characters,
          style: const TextStyle(color: Brand.text, fontSize: 13),
          decoration: InputDecoration(hintText: t('panel.plate')),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _brand,
          style: const TextStyle(color: Brand.text, fontSize: 13),
          decoration: InputDecoration(hintText: t('panel.brand')),
        ),
        const SizedBox(height: 10),
        PrimaryButton(
          label: t('panel.save_moto'),
          onPressed: widget.busy || _plate.text.trim().length < 4
              ? null
              : () => widget.onSaveProfile(
                    _plate.text.trim(),
                    _brand.text.trim().isEmpty ? null : _brand.text.trim(),
                    _legalName.text.trim().isEmpty ? null : _legalName.text.trim(),
                  ),
        ),
      ];

  /* ── waiting for work ─────────────────────────────────────────────────── */

  List<Widget> _waiting() {
    final online = _isMandatoryOnline || (_profile?.online ?? false);
    final nearby = widget.state?.nearby ?? const <NearbyRide>[];

    if (!online && !_isMandatoryOnline) {
      return [
        const SizedBox(height: 6),
        PrimaryButton(
          label: t('panel.go_online'),
          icon: Icons.power_settings_new,
          onPressed: widget.busy ? null : widget.onGoOnline,
        ),
      ];
    }

    return [
      const SizedBox(height: 4),
      Text(t('panel.waiting_caps', {'count': nearby.length}), style: Brand.micro),
      const SizedBox(height: 8),
      if (nearby.isEmpty)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          decoration: BoxDecoration(
            color: const Color(0xFF141414),
            border: Border.all(color: const Color(0xFF2C2C2C)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Color(0xFF4ADE80),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    'Active On Road · Radar Active',
                    style: TextStyle(
                      color: Color(0xFF4ADE80),
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                t('panel.no_requests'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF888888), fontSize: 11.5, height: 1.4),
              ),
            ],
          ),
        )
      else
        ...nearby.map(_nearbyRow),
    ];
  }

  Widget _nearbyRow(NearbyRide n) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Panel(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (n.isCourier) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: Brand.orange,
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              t('panel.courier'),
                              style: const TextStyle(
                                color: Colors.black,
                                fontSize: 8,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(
                            n.pickupName ?? t('panel.pinned_pickup'),
                            style: const TextStyle(
                              color: Brand.text,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${t('panel.away', {'distance': km(n.distanceToPickupM)})}'
                      ' · ${n.destName ?? t('panel.open_ride')}'
                      '${n.fareRwf != null ? ' · ${rwf(n.fareRwf)}' : ''}',
                      style: const TextStyle(color: Brand.muted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: widget.busy ? null : () => widget.onAccept(n.id),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Brand.orange,
                  foregroundColor: Colors.black,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                ),
                child: Text(
                  t('panel.accept'),
                  style: const TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 0.8),
                ),
              ),
            ],
          ),
        ),
      );

  /* ── the ride in hand ─────────────────────────────────────────────────── */

  List<Widget> _activeRide(Ride ride) {
    final canFinish = ride.canFinish;
    final title = switch (ride.status) {
      'ASSIGNED' || 'ARRIVED' =>
        canFinish ? t('ride.in_progress') : t('ride.waiting_to_start'),
      'IN_RIDE' => t('ride.in_progress'),
      'COMPLETED' || 'CLOSED' => t('ride.finished'),
      _ => t('ride.ride'),
    };

    return [
      const SizedBox(height: 4),
      Row(
        children: [
          Expanded(
            child: Text(title,
                style: const TextStyle(
                    color: Brand.text, fontSize: 14, fontWeight: FontWeight.w900)),
          ),
          if (ride.isCourier)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Brand.orange,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(t('panel.courier'),
                  style: const TextStyle(
                      color: Colors.black,
                      fontSize: 8.5,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.8)),
            ),
        ],
      ),
      const SizedBox(height: 8),
      Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(ride.passengerName,
                      style: const TextStyle(
                          color: Brand.text, fontSize: 13, fontWeight: FontWeight.w800)),
                ),
                // Bell icon to ring the passenger's device
                if (ride.status != 'CLOSED') ...[
                  GestureDetector(
                    onTap: widget.busy ? null : () => widget.onRingPassenger(ride.id),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: const Color(0xFF261C10),
                        shape: BoxShape.circle,
                        border: Border.all(color: Brand.orange, width: 1.5),
                      ),
                      child: const Icon(Icons.notifications_active,
                          size: 16, color: Brand.orange),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                if (ride.passengerPhone != null)
                  GestureDetector(
                    onTap: () => widget.onCall(ride.passengerPhone!),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: const BoxDecoration(color: Brand.orange, shape: BoxShape.circle),
                      child: const Icon(Icons.call, size: 16, color: Colors.black),
                    ),
                  ),
              ],
            ),
            if (ride.parcelNote != null && ride.parcelNote!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(ride.parcelNote!, style: const TextStyle(color: Brand.orange, fontSize: 11.5)),
            ],
            const SizedBox(height: 6),
            Text('● ${ride.pickupName ?? t('ride.pinned_pickup')}',
                style: const TextStyle(color: Brand.muted, fontSize: 11.5)),
            Text('● ${ride.destName ?? t('ride.meter_note')}',
                style: const TextStyle(color: Brand.muted, fontSize: 11.5)),
            if (ride.destName != null && ride.destLat == null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(t('ride.not_on_map'), style: Brand.micro),
              ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  ride.fareRwf != null
                      ? '${rwf(ride.fareRwf)}${ride.offeredFareRwf != null ? ' · ${t('ride.their_price')}' : ''}'
                      : '${km(ride.riddenDistanceM)} · ${rwf(ride.baseFareRwf)} + ${rwf(ride.perKmRwf)}/km',
                  style: const TextStyle(
                      color: Brand.text, fontSize: 13, fontWeight: FontWeight.w900),
                ),
                if (ride.cashDeclaredAt != null && ride.paymentStatus != 'PAID')
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF281D0B),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Brand.amber),
                    ),
                    child: const Text(
                      'CASH DECLARED',
                      style: TextStyle(
                        color: Brand.amber,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                      ),
                    ),
                  )
                else if (ride.paymentStatus == 'PAID')
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0E2918),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Brand.green),
                    ),
                    child: const Text(
                      'PAID',
                      style: TextStyle(
                        color: Brand.green,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
              ],
            ),
            if (ride.status == 'ASSIGNED' || ride.status == 'ARRIVED' || ride.status == 'IN_RIDE') ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: canFinish ? Brand.green : Brand.amber,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      canFinish ? t('ride.in_progress') : t('ride.waiting_to_start'),
                      style: TextStyle(
                        color: canFinish ? Brand.green : Brand.amber,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 10),
      ..._rideActions(ride),
    ];
  }

  Future<void> _onFinishPressed(Ride ride) async {
    if (ride.cashDeclaredAt != null && ride.paymentStatus != 'PAID') {
      final decision = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF141414),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0xFF2E2E2E)),
          ),
          title: Text(
            t('ride.cash_confirm_title'),
            style: const TextStyle(
                color: Colors.white, fontSize: 15, fontWeight: FontWeight.w900),
          ),
          content: Text(
            t('ride.cash_confirm_body'),
            style: const TextStyle(color: Color(0xFFCCCCCC), fontSize: 13, height: 1.4),
          ),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              style: OutlinedButton.styleFrom(
                foregroundColor: Brand.red,
                side: const BorderSide(color: Color(0xFF5A1E1E)),
              ),
              child: Text(
                t('ride.decline_cash_btn'),
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800),
              ),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Brand.green,
                foregroundColor: Colors.black,
              ),
              child: Text(
                t('ride.confirm_cash_btn'),
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w900),
              ),
            ),
          ],
        ),
      );
      if (decision == true) {
        widget.onConfirmCash(ride.id);
      } else if (decision == false) {
        widget.onDenyCash(ride.id);
      }
      return;
    }

    if (ride.isCourier) {
      widget.onParcelDelivered(ride.id);
    } else {
      widget.onComplete(ride.id);
    }
  }

  List<Widget> _rideActions(Ride ride) {
    final canFinish = ride.canFinish;

    switch (ride.status) {
      case 'ASSIGNED':
      case 'ARRIVED':
      case 'IN_RIDE':
        return [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: widget.busy ? null : () => widget.onRingPassenger(ride.id),
                  icon: const Icon(Icons.notifications_active, size: 15, color: Brand.orange),
                  label: Text(
                    t('ride.ring_passenger'),
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w800, color: Brand.text),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Brand.orange),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              if (canFinish) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: PrimaryButton(
                    label: ride.isCourier ? t('ride.finish_delivery') : t('ride.finish_ride'),
                    icon: Icons.check_circle_outline,
                    onPressed: widget.busy ? null : () => _onFinishPressed(ride),
                  ),
                ),
              ],
            ],
          ),
          if (!canFinish) ...[
            const SizedBox(height: 8),
            _handBack(ride),
          ],
        ];

      case 'COMPLETED':
      case 'CLOSED':
        return _paymentState(ride);

      default:
        return const [];
    }
  }

  /// Where the fare stands, which reads the same whether it was a parcel or a
  /// passenger.
  List<Widget> _paymentState(Ride ride) {
    if (ride.paymentStatus == 'PAID') {
      return [
        Text(
          ride.paymentMethod == 'CASH' ? t('ride.paid_cash') : t('ride.paid_platform'),
          style: const TextStyle(color: Brand.green, fontSize: 12, fontWeight: FontWeight.w800),
        ),
        ..._ratePassenger(ride),
      ];
    }
    if (ride.cashDeclaredAt != null) {
      return [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF1E170C),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Brand.amber),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                t('ride.cash_confirm_body'),
                style: const TextStyle(
                    color: Brand.text, fontSize: 12, fontWeight: FontWeight.w700, height: 1.35),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: widget.busy ? null : () => widget.onConfirmCash(ride.id),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Brand.green,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      child: Text(
                        t('ride.confirm_cash_btn'),
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: widget.busy ? null : () => widget.onDenyCash(ride.id),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Brand.red,
                        side: const BorderSide(color: Color(0xFF6B2121)),
                        padding: const EdgeInsets.symmetric(vertical: 11),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      child: Text(
                        t('ride.decline_cash_btn'),
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        ..._ratePassenger(ride),
      ];
    }
    return [
      _note(t('ride.awaiting_payment'), Brand.amber),
      ..._ratePassenger(ride),
    ];
  }

  Widget _note(String text, Color color) => Text(
        text,
        style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w700),
      );

  /// Mandatory rating of the passenger by the motari after every ride.
  List<Widget> _ratePassenger(Ride ride) {
    if (ride.passengerRating != null) return const [];
    return [
      const SizedBox(height: 10),
      Text(t('ride.must_rate'),
          style: const TextStyle(
              color: Brand.orange, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.4)),
      const SizedBox(height: 4),
      Row(
        children: [
          for (var n = 1; n <= 5; n++)
            IconButton(
              padding: const EdgeInsets.only(right: 4),
              constraints: const BoxConstraints(),
              onPressed: widget.busy ? null : () => widget.onRate(ride.id, n),
              icon: const Icon(Icons.star_border, size: 28, color: Brand.amber),
            ),
        ],
      ),
    ];
  }

  Widget _handBack(Ride ride) => OutlinedButton(
        onPressed: widget.busy ? null : () => widget.onHandBack(ride.id),
        style: OutlinedButton.styleFrom(
          foregroundColor: Brand.red,
          side: const BorderSide(color: Color(0xFF451A1A)),
          padding: const EdgeInsets.symmetric(vertical: 11),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: Text(t('ride.hand_back'),
            style: const TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
      );
}
