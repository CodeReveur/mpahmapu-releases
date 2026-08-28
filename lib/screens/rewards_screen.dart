import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../i18n.dart';
import '../theme.dart';

/// What a motari has earned, and what they are close to earning.
///
/// A bonus nobody can see does not motivate anybody, and a milestone without a
/// number attached is a poster rather than an incentive: "50 rides" means
/// nothing without "you have done 31". So every offer here carries its own
/// progress, and the money waiting to be claimed sits at the top where it
/// cannot be missed.
class RewardsScreen extends StatefulWidget {
  final Api api;
  const RewardsScreen({super.key, required this.api});

  @override
  State<RewardsScreen> createState() => _RewardsScreenState();
}

class _RewardsScreenState extends State<RewardsScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await widget.api.rewards();
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.message; });
    } catch (_) {
      if (mounted) setState(() { _loading = false; _error = t('common.error'); });
    }
  }

  Future<void> _claim() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.api.claimBonuses();
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t('rewards.claimed'))),
        );
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = t('common.error'));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final claimable = (_data?['claimableRwf'] as num?)?.toInt() ?? 0;
    final offers = (_data?['offers'] as List?) ?? const [];
    final referral = (_data?['referral'] as Map?) ?? const {};

    return Scaffold(
      backgroundColor: Brand.black,
      appBar: AppBar(
        backgroundColor: Brand.black,
        elevation: 0,
        title: Text(t('rewards.title'),
            style: const TextStyle(color: Brand.text, fontSize: 15, fontWeight: FontWeight.w900)),
        iconTheme: const IconThemeData(color: Brand.text),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Brand.orange))
          : RefreshIndicator(
              onRefresh: _load,
              color: Brand.orange,
              backgroundColor: Brand.surface,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 28),
                children: [
                  if (_error != null) ...[
                    Text(_error!, style: const TextStyle(color: Color(0xFFF87171), fontSize: 12.5)),
                    const SizedBox(height: 12),
                  ],

                  _waiting(claimable),
                  const SizedBox(height: 18),

                  if (offers.isNotEmpty) ...[
                    Text(t('rewards.what_you_can_earn'), style: Brand.micro),
                    const SizedBox(height: 8),
                    ...offers.map((o) => _offer(o as Map)),
                    const SizedBox(height: 18),
                  ],

                  Text(t('rewards.bring_someone'), style: Brand.micro),
                  const SizedBox(height: 8),
                  _referral(referral),
                ],
              ),
            ),
    );
  }

  /// The money already earned. Nothing else on this screen is money yet.
  Widget _waiting(int claimable) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Brand.surface,
          border: Border.all(color: claimable > 0 ? Brand.orange : Brand.line),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t('rewards.waiting'), style: Brand.micro),
            const SizedBox(height: 6),
            Text(
              'RWF ${claimable.toString()}',
              style: const TextStyle(
                  color: Brand.text, fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: -0.6),
            ),
            const SizedBox(height: 10),
            if (claimable > 0)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _busy ? null : _claim,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Brand.orange,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
                  ),
                  child: Text(_busy ? t('rewards.claiming') : t('rewards.claim'),
                      style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                ),
              )
            else
              Text(t('rewards.nothing_waiting'),
                  style: const TextStyle(color: Brand.muted, fontSize: 12, height: 1.5)),
          ],
        ),
      );

  /// One offer, with how far along it is.
  Widget _offer(Map o) {
    final earned = o['earned'] == true;
    final target = (o['target'] as num?)?.toInt() ?? 0;
    final done = (o['done'] as num?)?.toInt() ?? 0;
    final amount = (o['amountRwf'] as num?)?.toInt() ?? 0;
    final progress = target > 0 ? (done / target).clamp(0.0, 1.0) : (earned ? 1.0 : 0.0);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Brand.surface,
        border: Border.all(color: earned ? const Color(0xFF14532D) : Brand.line),
        borderRadius: BorderRadius.circular(13),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  (o['title'] ?? '').toString(),
                  style: const TextStyle(
                      color: Brand.text, fontSize: 13.5, fontWeight: FontWeight.w800),
                ),
              ),
              Text(
                'RWF $amount',
                style: TextStyle(
                    color: earned ? Brand.green : Brand.orange,
                    fontSize: 13,
                    fontWeight: FontWeight.w900),
              ),
            ],
          ),
          if ((o['description'] ?? '').toString().isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(o['description'].toString(),
                style: const TextStyle(color: Brand.muted, fontSize: 11.5, height: 1.45)),
          ],
          const SizedBox(height: 10),

          if (earned)
            Text(t('rewards.earned'),
                style: const TextStyle(
                    color: Brand.green, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 0.6))
          else ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor: const Color(0xFF1A1A1A),
                valueColor: const AlwaysStoppedAnimation(Brand.orange),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              target > 0
                  ? '$done / $target${o['note'] != null ? ' · ${o['note']}' : ''}'
                  : (o['note']?.toString() ?? ''),
              style: const TextStyle(color: Brand.dim, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  /// The code, and what it has been worth.
  Widget _referral(Map r) {
    final code = (r['code'] ?? '').toString();
    final invited = (r['invited'] as num?)?.toInt() ?? 0;
    final riding = (r['riding'] as num?)?.toInt() ?? 0;
    final waiting = (r['waiting'] as num?)?.toInt() ?? 0;
    final earned = (r['earnedRwf'] as num?)?.toInt() ?? 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Brand.surface,
        border: Border.all(color: Brand.line),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t('rewards.referral_how'),
              style: const TextStyle(color: Brand.muted, fontSize: 12, height: 1.55)),
          const SizedBox(height: 14),

          // The code itself, big enough to read out over a phone call, which is
          // how most of these will actually be shared.
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: Brand.black,
                    border: Border.all(color: Brand.orange),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Text(
                    code,
                    style: const TextStyle(
                        color: Brand.text,
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 3),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _iconButton(Icons.copy, t('rewards.copy'), () {
                Clipboard.setData(ClipboardData(text: code));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(t('rewards.copied'))),
                );
              }),
              const SizedBox(width: 6),
              _iconButton(Icons.share, t('rewards.share'), () => _share(code)),
            ],
          ),

          const SizedBox(height: 14),
          Row(
            children: [
              _tally(invited.toString(), t('rewards.invited')),
              _tally(riding.toString(), t('rewards.riding')),
              _tally('RWF $earned', t('rewards.earned_from')),
            ],
          ),

          // The gap between inviting and earning is the thing people write in
          // to ask about, so it is said before they have to.
          if (waiting > 0) ...[
            const SizedBox(height: 12),
            Text(t('rewards.waiting_on_first_ride', {'count': waiting}),
                style: const TextStyle(color: Brand.dim, fontSize: 11.5, height: 1.5)),
          ],
        ],
      ),
    );
  }

  /// Hand the code to WhatsApp, which is where it will actually travel.
  ///
  /// wa.me opens the app's own share sheet with the message ready, and falls
  /// back to the browser on a phone without WhatsApp. If neither opens, the
  /// copy button beside this one still works, which is why this fails quietly.
  Future<void> _share(String code) async {
    final text = Uri.encodeComponent(t('rewards.share_text', {'code': code}));
    final uri = Uri.parse('https://wa.me/?text=$text');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t('rewards.share_failed'))),
        );
      }
    }
  }

  Widget _iconButton(IconData icon, String label, VoidCallback onTap) => Semantics(
        button: true,
        label: label,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(11),
          child: Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              border: Border.all(color: Brand.line),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, size: 17, color: Brand.muted),
          ),
        ),
      );

  Widget _tally(String value, String label) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value,
                style: const TextStyle(
                    color: Brand.text, fontSize: 15, fontWeight: FontWeight.w900)),
            const SizedBox(height: 2),
            Text(label, style: Brand.micro),
          ],
        ),
      );
}
