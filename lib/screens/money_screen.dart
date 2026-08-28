import 'package:flutter/material.dart';

import '../api.dart';
import '../i18n.dart';
import '../models.dart';
import '../theme.dart';
import 'rewards_screen.dart';
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
        actions: [
          // Money earned and money that could be earned belong next to each
          // other: somebody looking at what they made is the person most
          // interested in how to make more.
          TextButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => RewardsScreen(api: widget.api),
            )),
            icon: const Icon(Icons.card_giftcard, size: 15, color: Brand.orange),
            label: Text(t('rewards.title'),
                style: const TextStyle(
                    color: Brand.orange, fontSize: 12, fontWeight: FontWeight.w800)),
          ),
        ],
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
                      ..._groupedTrips(h.rides),
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

  /// Trips under the period they happened in. A motari reading this wants
  /// today first and last year last, and wants to find a particular trip by
  /// remembering roughly when it was.
  List<Widget> _groupedTrips(List<Ride> rides) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    // The week runs from Monday, which is how a working week is counted here.
    final weekStart = today.subtract(Duration(days: today.weekday - 1));
    final monthStart = DateTime(now.year, now.month);
    final lastMonthStart = DateTime(now.year, now.month - 1);
    final yearStart = DateTime(now.year);
    final lastYearStart = DateTime(now.year - 1);

    // Ordered, so a trip always lands in the first bucket it fits and the
    // sections read from most recent to least.
    final buckets = <String, List<Ride>>{
      'money.today': [],
      'money.yesterday': [],
      'money.this_week': [],
      'money.this_month': [],
      'money.last_month': [],
      'money.this_year': [],
      'money.last_year': [],
      'money.earlier': [],
    };

    for (final r in rides) {
      final at = r.requestedAt?.toLocal();
      // A trip with no time still belongs somewhere it can be found.
      if (at == null) {
        buckets['money.earlier']!.add(r);
        continue;
      }
      final day = DateTime(at.year, at.month, at.day);
      final key = !day.isBefore(today)
          ? 'money.today'
          : !day.isBefore(yesterday)
              ? 'money.yesterday'
              : !day.isBefore(weekStart)
                  ? 'money.this_week'
                  : !day.isBefore(monthStart)
                      ? 'money.this_month'
                      : !day.isBefore(lastMonthStart)
                          ? 'money.last_month'
                          : !day.isBefore(yearStart)
                              ? 'money.this_year'
                              : !day.isBefore(lastYearStart)
                                  ? 'money.last_year'
                                  : 'money.earlier';
      buckets[key]!.add(r);
    }

    final out = <Widget>[];
    for (final entry in buckets.entries) {
      if (entry.value.isEmpty) continue;
      out.add(Padding(
        padding: EdgeInsets.only(top: out.isEmpty ? 0 : 6, bottom: 7),
        child: Row(
          children: [
            Text(t(entry.key).toUpperCase(), style: Brand.micro),
            const SizedBox(width: 8),
            const Expanded(child: Divider(color: Brand.line, height: 1)),
            const SizedBox(width: 8),
            Text('${entry.value.length}', style: Brand.micro),
          ],
        ),
      ));
      out.addAll(entry.value.map(_rideRow));
    }
    return out;
  }

  /// When a trip was, written the way someone would say it. Today and yesterday
  /// have their own heading above, so those rows only need the time.
  String _when(DateTime? at) {
    if (at == null) return '';
    final local = at.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(local.year, local.month, local.day);
    final time =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';

    if (!day.isBefore(today.subtract(const Duration(days: 1)))) return time;
    final date = '${local.day} ${monthShort(local.month)}';
    // The year only earns its place once it stops being this one.
    return local.year == now.year ? '$date, $time' : '$date ${local.year}, $time';
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
                    if (r.requestedAt != null) ...[
                      const SizedBox(height: 3),
                      Text(_when(r.requestedAt), style: Brand.micro),
                    ],
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
