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
  final void Function(String rideId) onDenyCash;
  final void Function(String rideId, int stars) onRate;
  final void Function(String rideId) onHandBack;
  final VoidCallback onGoOnline;
  final void Function(String phone) onCall;
  final void Function(String plate, String? brand, String? legalName) onSaveProfile;
  final VoidCallback onOpenMoney;
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
    required this.onDenyCash,
    required this.onRate,
    required this.onHandBack,
    required this.onGoOnline,
    required this.onCall,
    required this.onSaveProfile,
    required this.onOpenMoney,
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
    final h = DateTime.now().hour;
    return h >= 5 && h < 21;
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
    if (_profile == null) return _registerMoto();
    final ride = _ride;
    if (ride != null) return _activeRide(ride);
    return _waiting();
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
        const SizedBox(height: 8),
        _footer(),
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
        const SizedBox(height: 10),
        _footer(),
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
      const SizedBox(height: 10),
      _footer(),
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
    final title = ride.isCourier
        ? switch (ride.status) {
            'ASSIGNED' || 'ARRIVED' => t('parcel.go_collect'),
            'IN_RIDE' => t('parcel.carrying'),
            'COMPLETED' => ride.deliveredAt == null
                ? t('parcel.at_destination')
                : t('parcel.awaiting_owner'),
            _ => t('parcel.parcel'),
          }
        : switch (ride.status) {
            'ASSIGNED' => t('ride.head_to_pickup'),
            'ARRIVED' => t('ride.waiting_passenger'),
            'IN_RIDE' => t('ride.in_progress'),
            'COMPLETED' => t('ride.finished'),
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
            Text(t('panel.courier'),
                style: const TextStyle(
                    color: Brand.orange,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1)),
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
            Text(
              ride.fareRwf != null
                  ? '${rwf(ride.fareRwf)}${ride.offeredFareRwf != null ? ' · ${t('ride.their_price')}' : ''}'
                  : '${km(ride.riddenDistanceM)} · ${rwf(ride.baseFareRwf)} + ${rwf(ride.perKmRwf)}/km',
              style: const TextStyle(
                  color: Brand.text, fontSize: 13, fontWeight: FontWeight.w900),
            ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      ..._rideActions(ride),
      const SizedBox(height: 8),
      _footer(),
    ];
  }

  List<Widget> _rideActions(Ride ride) {
    // A parcel is handed over rather than sensed, so it has its own sequence:
    // collect it, carry it, say it was delivered, and wait on the owner.
    if (ride.isCourier) return _parcelActions(ride);
    switch (ride.status) {
      case 'ASSIGNED':
        return [
          PrimaryButton(
            label: t('ride.arrived'),
            onPressed: widget.busy ? null : () => widget.onArrived(ride.id),
          ),
          const SizedBox(height: 8),
          _handBack(ride),
        ];
      // The ride starts itself once the two of them pull away together.
      case 'ARRIVED':
        return [
          _note(t('ride.starts_together'), Brand.amber),
          const SizedBox(height: 8),
          _handBack(ride),
        ];
      case 'IN_RIDE':
        // A destination the map never had cannot be sensed: that is the one
        // ride still needing a tap.
        if (ride.destLat != null) {
          return [_note(t('ride.auto_complete'), Brand.muted)];
        }
        return [
          PrimaryButton(
            label: t('ride.complete'),
            icon: Icons.check_circle_outline,
            onPressed: widget.busy ? null : () => widget.onComplete(ride.id),
          ),
        ];
      // However the passenger paid, the platform already knows. The motari
      // only speaks up when the cash never came.
      case 'COMPLETED':
        if (ride.paymentStatus == 'PAID') {
          return [
            Text(
              ride.paymentMethod == 'CASH'
                  ? t('ride.paid_cash')
                  : t('ride.paid_platform'),
              style: const TextStyle(color: Brand.green, fontSize: 12, fontWeight: FontWeight.w800),
            ),
            ..._ratePassenger(ride),
          ];
        }
        if (ride.cashDeclaredAt != null) {
          return [
            _note(t('ride.cash_declared'), Brand.amber),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: widget.busy ? null : () => widget.onDenyCash(ride.id),
              style: OutlinedButton.styleFrom(
                foregroundColor: Brand.red,
                side: const BorderSide(color: Color(0xFF451A1A)),
                padding: const EdgeInsets.symmetric(vertical: 11),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: Text(t('ride.not_paid'),
                  style: const TextStyle(
                      fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
            ),
            ..._ratePassenger(ride),
          ];
        }
        return [
          _note(t('ride.awaiting_payment'), Brand.amber),
          ..._ratePassenger(ride),
        ];
      default:
        return const [];
    }
  }

  /// What a motari carrying a parcel is asked to do, one thing at a time.
  List<Widget> _parcelActions(Ride ride) {
    switch (ride.status) {
      case 'ASSIGNED':
      case 'ARRIVED':
        return [
          PrimaryButton(
            label: t('parcel.received'),
            icon: Icons.inventory_2,
            onPressed: widget.busy ? null : () => widget.onParcelReceived(ride.id),
          ),
          const SizedBox(height: 8),
          _handBack(ride),
        ];

      case 'IN_RIDE':
        return [
          PrimaryButton(
            label: t('parcel.delivered'),
            icon: Icons.check_circle_outline,
            onPressed: widget.busy ? null : () => widget.onParcelDelivered(ride.id),
          ),
        ];

      case 'COMPLETED':
        // Said delivered, and now it is the owner's word that settles it. The
        // button stays until they agree or the grace period runs out, because
        // a motari who taps it twice has still only delivered once.
        if (ride.deliveredAt != null) {
          return [
            _note(
              ride.deliveryDisputedAt != null
                  ? t('parcel.owner_disputed')
                  : t('parcel.waiting_owner'),
              ride.deliveryDisputedAt != null ? Brand.red : Brand.amber,
            ),
            const SizedBox(height: 8),
            ..._paymentState(ride),
          ];
        }
        return [
          PrimaryButton(
            label: t('parcel.delivered'),
            icon: Icons.check_circle_outline,
            onPressed: widget.busy ? null : () => widget.onParcelDelivered(ride.id),
          ),
          const SizedBox(height: 8),
          ..._paymentState(ride),
        ];

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
        _note(t('ride.cash_declared'), Brand.amber),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: widget.busy ? null : () => widget.onDenyCash(ride.id),
          style: OutlinedButton.styleFrom(
            foregroundColor: Brand.red,
            side: const BorderSide(color: Color(0xFF451A1A)),
            padding: const EdgeInsets.symmetric(vertical: 11),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: Text(t('ride.not_paid'),
              style: const TextStyle(
                  fontSize: 10.5, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
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

  /// The passenger, as the motari found them.
  List<Widget> _ratePassenger(Ride ride) {
    if (ride.passengerRating != null) return const [];
    return [
      const SizedBox(height: 10),
      Text(t('ride.rate_passenger'),
          style: const TextStyle(
              color: Brand.muted, fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
      const SizedBox(height: 4),
      Row(
        children: [
          for (var n = 1; n <= 5; n++)
            IconButton(
              padding: const EdgeInsets.only(right: 2),
              constraints: const BoxConstraints(),
              onPressed: widget.busy ? null : () => widget.onRate(ride.id, n),
              icon: const Icon(Icons.star_border, size: 24, color: Brand.amber),
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

  /* ── the two other screens ────────────────────────────────────────────── */

  Widget _footer() => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          TextButton.icon(
            onPressed: widget.onOpenMoney,
            icon: const Icon(Icons.account_balance_wallet_outlined, size: 14, color: Brand.orange),
            label: Text(t('panel.money'),
                style: const TextStyle(
                    color: Brand.muted, fontSize: 11.5, fontWeight: FontWeight.w700)),
          ),
          TextButton.icon(
            onPressed: widget.onOpenSettings,
            icon: const Icon(Icons.settings_outlined, size: 14, color: Brand.orange),
            label: Text(t('panel.settings'),
                style: const TextStyle(
                    color: Brand.muted, fontSize: 11.5, fontWeight: FontWeight.w700)),
          ),
        ],
      );
}
