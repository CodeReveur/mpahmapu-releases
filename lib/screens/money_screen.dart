import 'package:flutter/material.dart';

import '../api.dart';
import '../i18n.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/fee_banner.dart';

/// What the day earned, where it went, and what is owed. The daily fee lives
/// here around the clock, so it is always findable even outside the hours it
/// takes over the map.
class MoneyScreen extends StatefulWidget {
  final Api api;
  final Fees? fees;
  const MoneyScreen({super.key, required this.api, this.fees});

  @override
  State<MoneyScreen> createState() => _MoneyScreenState();
}

class _MoneyScreenState extends State<MoneyScreen> {
  MotariHistory? _history;
  Fees? _fees;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fees = widget.fees;
    _load();
  }

  Future<void> _load() async {
    try {
      final history = await widget.api.history();
      if (mounted) setState(() => _history = history);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      // Keep whatever is on screen; the pull-to-refresh can try again.
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _payFees() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final next = await widget.api.payFees();
      if (mounted) setState(() => _fees = next.fees);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final h = _history;
    final fees = _fees;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Brand.black,
        surfaceTintColor: Brand.black,
        title: Text(t('money.title'),
            style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.w900, color: Brand.text)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Brand.orange))
          : RefreshIndicator(
              color: Brand.orange,
              backgroundColor: Brand.surface,
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
                children: [
                  if (fees != null) ...[
                    FeeBanner(fees: fees, busy: _busy, onPay: _payFees),
                    if (fees.dueAmountRwf == 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          t('fees.nothing_owed', {'count': fees.minRides}),
                          style: Brand.micro,
                        ),
                      ),
                    const SizedBox(height: 12),
                  ],
                  if (_error != null) ...[
                    Text(_error!, style: const TextStyle(color: Brand.red, fontSize: 12)),
                    const SizedBox(height: 10),
                  ],
                  if (h != null) ...[
                    Row(
                      children: [
                        Expanded(
                            child: _stat(t('money.wallet'), rwf(h.walletBalanceRwf), Brand.orange)),
                        const SizedBox(width: 8),
                        Expanded(
                            child: _stat(t('money.collected'), rwf(h.totalCollectedRwf), Brand.text)),
                        const SizedBox(width: 8),
                        Expanded(child: _stat(t('money.rides'), '${h.totalRides}', Brand.text)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _stat(t('money.paid_out'), rwf(h.totalPaidOutRwf), Brand.text),
                    const SizedBox(height: 16),
                    if (h.payouts.isNotEmpty) ...[
                      Text(t('money.payouts'), style: Brand.micro),
                      const SizedBox(height: 8),
                      ...h.payouts.map(_payoutRow),
                      const SizedBox(height: 16),
                    ],
                    Text(t('money.trips'), style: Brand.micro),
                    const SizedBox(height: 8),
                    if (h.rides.isEmpty)
                      Text(t('money.no_trips'),
                          style: const TextStyle(color: Brand.dim, fontSize: 12))
                    else
                      ...h.rides.map(_rideRow),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _stat(String label, String value, Color color) => Panel(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label.toUpperCase(), style: Brand.micro),
            const SizedBox(height: 3),
            Text(value,
                style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w900)),
          ],
        ),
      );

  Widget _payoutRow(Payout p) {
    final color = switch (p.status.toUpperCase()) {
      'SUCCESS' => Brand.green,
      'FAILED' => Brand.red,
      _ => Brand.amber,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Panel(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(rwf(p.amountRwf),
                      style: const TextStyle(
                          color: Brand.text, fontSize: 12.5, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(
                    '${p.method == 'MTN_MOMO' ? t('money.mtn') : t('money.airtel')} · ${p.phone}',
                    style: Brand.micro,
                  ),
                ],
              ),
            ),
            Text(p.status.toUpperCase(),
                style: TextStyle(
                    color: color, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 0.8)),
          ],
        ),
      ),
    );
  }

  Widget _rideRow(Ride r) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Panel(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(r.passengerName,
                              style: const TextStyle(
                                  color: Brand.text, fontSize: 12.5, fontWeight: FontWeight.w700)),
                        ),
                        if (r.rating != null)
                          Text('${r.rating}★',
                              style: const TextStyle(color: Brand.amber, fontSize: 11)),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${r.pickupName ?? t('money.pickup')}'
                      '${r.destName != null ? ' → ${r.destName}' : ''}',
                      style: const TextStyle(color: Brand.muted, fontSize: 10.5, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(r.finalFareRwf != null ? rwf(r.finalFareRwf) : '—',
                      style: TextStyle(
                          color: r.status == 'CLOSED' ? Brand.orange : Brand.dim,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w900)),
                  const SizedBox(height: 2),
                  Text(r.status,
                      style: TextStyle(
                        color: r.status == 'CLOSED' ? Brand.green : Brand.dim,
                        fontSize: 8.5,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.8,
                      )),
                ],
              ),
            ],
          ),
        ),
      );
}
