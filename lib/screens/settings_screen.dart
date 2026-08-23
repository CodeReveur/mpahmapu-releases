import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../i18n.dart';
import '../models.dart';
import '../permissions.dart';
import '../theme.dart';
import '../widgets/language_button.dart';

/// Instant payout, parcels, and the two things only support can do: change the
/// account number, and hear a complaint.
class SettingsScreen extends StatefulWidget {
  final Api api;
  final MotariProfile? profile;
  final VoidCallback onSignedOut;

  const SettingsScreen({
    super.key,
    required this.api,
    required this.profile,
    required this.onSignedOut,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _payoutPhone = TextEditingController();
  final _newPhone = TextEditingController();
  final _complaint = TextEditingController();

  MotariProfile? _profile;
  bool _busy = false;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _profile = widget.profile;
  }

  @override
  void dispose() {
    _payoutPhone.dispose();
    _newPhone.dispose();
    _complaint.dispose();
    super.dispose();
  }

  /// Rwandan mobile numbers: digits only, ten of them, starting 07.
  bool _validPhone(String s) => RegExp(r'^07\d{8}$').hasMatch(s);

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await action();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = t('common.error'));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _savePayout({bool? instant, String? method, String? phone}) => _run(() async {
        final next = await widget.api
            .setPayout(instantPayout: instant, payoutMethod: method, payoutPhone: phone);
        setState(() {
          _profile = next.profile;
          if (phone != null) {
            _payoutPhone.clear();
            _notice = t('settings.payout_saved');
          }
        });
      });

  Future<void> _requestNumberChange() => _run(() async {
        await widget.api.contactSupport(
          name: widget.api.userName ?? t('app.name'),
          // The server threads support by email and refuses a blank one, which
          // is why every message sent from here used to come back an error.
          email: widget.api.userEmail ?? '',
          subject: t('settings.number_change_subject'),
          message: t('settings.number_change_body', {
            'phone': _newPhone.text.trim(),
            'plate': _profile?.plateNumber ?? t('settings.unknown_plate'),
          }),
        );
        setState(() {
          _newPhone.clear();
          _notice = t('settings.change_sent');
        });
      });

  Future<void> _sendComplaint() => _run(() async {
        await widget.api.contactSupport(
          name: widget.api.userName ?? t('app.name'),
          email: widget.api.userEmail ?? '',
          subject: t('settings.complaint_subject'),
          message: _complaint.text.trim(),
        );
        setState(() {
          _complaint.clear();
          _notice = t('settings.complaint_sent');
        });
      });

  @override
  Widget build(BuildContext context) {
    final p = _profile;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Brand.black,
        surfaceTintColor: Brand.black,
        title: Text(t('settings.title'),
            style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.w900, color: Brand.text)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
        children: [
          if (_notice != null) ...[
            Text(_notice!, style: const TextStyle(color: Brand.green, fontSize: 12)),
            const SizedBox(height: 10),
          ],
          if (_error != null) ...[
            Text(_error!, style: const TextStyle(color: Brand.red, fontSize: 12)),
            const SizedBox(height: 10),
          ],

          const Panel(child: LanguageButton(inline: true)),
          const SizedBox(height: 10),
          Panel(
            child: GestureDetector(
              onTap: openPhoneSettings,
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  const Icon(Icons.tune, size: 15, color: Brand.orange),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t('settings.permissions'),
                            style: const TextStyle(
                                color: Brand.text,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w800)),
                        const SizedBox(height: 2),
                        Text(t('settings.permissions_hint'), style: Brand.micro),
                      ],
                    ),
                  ),
                  Text(t('settings.review'),
                      style: const TextStyle(
                          color: Brand.orange,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.9)),
                  const Icon(Icons.chevron_right, size: 16, color: Brand.dim),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),

          if (p != null) ...[
            // Instant payout, and where it goes.
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _toggleRow(
                    title: t('settings.instant_payout'),
                    hint: t('settings.instant_payout_hint'),
                    value: p.instantPayout,
                    onChanged: (v) => _savePayout(instant: v),
                  ),
                  if (p.instantPayout) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(child: _methodButton(p, 'MTN_MOMO', t('money.mtn'))),
                        const SizedBox(width: 6),
                        Expanded(child: _methodButton(p, 'AIRTEL_MONEY', t('money.airtel'))),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _payoutPhone,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(10),
                            ],
                            style: const TextStyle(color: Brand.text, fontSize: 13),
                            decoration: InputDecoration(
                              hintText: p.payoutPhone ?? '07xxxxxxxx',
                              contentPadding:
                                  const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        const SizedBox(width: 6),
                        _smallButton(
                          t('common.save'),
                          enabled: !_busy && _validPhone(_payoutPhone.text),
                          onTap: () => _savePayout(phone: _payoutPhone.text.trim()),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),

            // Parcels.
            Panel(
              child: _toggleRow(
                title: t('settings.carry_parcels'),
                hint: t('settings.carry_parcels_hint'),
                value: p.courier,
                onChanged: (v) => _run(() async {
                  final next = await widget.api.setCourier(v);
                  setState(() => _profile = next.profile);
                }),
              ),
            ),
            const SizedBox(height: 10),

            // The account number is an identity fact: support changes it.
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t('settings.change_number'),
                      style: const TextStyle(
                          color: Brand.text, fontSize: 12.5, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _newPhone,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(10),
                          ],
                          style: const TextStyle(color: Brand.text, fontSize: 13),
                          decoration: const InputDecoration(
                            hintText: '07xxxxxxxx',
                            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _smallButton(
                        t('common.request'),
                        enabled: !_busy && _validPhone(_newPhone.text),
                        onTap: _requestNumberChange,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],

          // A complaint.
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t('settings.raise_complaint'),
                    style: const TextStyle(
                        color: Brand.text, fontSize: 12.5, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                TextField(
                  controller: _complaint,
                  maxLines: 3,
                  maxLength: 2000,
                  style: const TextStyle(color: Brand.text, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: t('settings.complaint_hint'),
                    counterText: '',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                PrimaryButton(
                  label: t('settings.send_complaint'),
                  onPressed:
                      _busy || _complaint.text.trim().length < 10 ? null : _sendComplaint,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          TextButton.icon(
            onPressed: () async {
              await widget.api.signOut();
              if (!context.mounted) return;
              // Swapping the app's home is not enough on its own: Settings and
              // the working screen are still pushed above it, so a motari who
              // logs out would keep looking at Settings. Clear the stack first,
              // and the app comes back to where it opens for everyone.
              Navigator.of(context).popUntil((route) => route.isFirst);
              widget.onSignedOut();
            },
            icon: const Icon(Icons.logout, size: 15, color: Brand.red),
            label: Text(t('settings.log_out'),
                style: const TextStyle(
                    color: Brand.red, fontSize: 12, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }

  Widget _toggleRow({
    required String title,
    required String hint,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) =>
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: Brand.text, fontSize: 12.5, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(hint, style: Brand.micro),
              ],
            ),
          ),
          Switch(
            value: value,
            activeThumbColor: Colors.black,
            activeTrackColor: Brand.orange,
            inactiveThumbColor: Brand.muted,
            inactiveTrackColor: Brand.surface,
            onChanged: _busy ? null : onChanged,
          ),
        ],
      );

  Widget _methodButton(MotariProfile p, String method, String label) {
    final selected = p.payoutMethod == method;
    return GestureDetector(
      onTap: _busy ? null : () => _savePayout(method: method),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? Brand.orange : Brand.surface,
          border: Border.all(color: selected ? Brand.orange : Brand.line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.black : Brand.muted,
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }

  Widget _smallButton(String label, {required bool enabled, required VoidCallback onTap}) =>
      GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: enabled ? Brand.orange : const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label.toUpperCase(),
            style: TextStyle(
              color: enabled ? Colors.black : Brand.dim,
              fontSize: 9.5,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.8,
            ),
          ),
        ),
      );
}
