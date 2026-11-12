import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../i18n.dart';
import '../models.dart';
import '../permissions.dart';
import '../theme.dart';
import '../updater.dart';
import '../widgets/language_button.dart';

/// Instant payout, parcels, and the two things only support can do: change the
/// account number, and hear a complaint.
class SettingsScreen extends StatefulWidget {
  final Api api;
  final MotariProfile? profile;
  final VoidCallback onSignedOut;
  final VoidCallback? onSwitchToPassenger;

  const SettingsScreen({
    super.key,
    required this.api,
    required this.profile,
    required this.onSignedOut,
    this.onSwitchToPassenger,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
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
    _loadReferral();
  }

  @override
  void dispose() {
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
          if (phone != null) _notice = t('settings.payout_saved');
        });
      });

  Future<void> _requestNumberChange() => _run(() async {
        await widget.api.contactSupport(
          name: widget.api.userName ?? t('settings.unnamed'),
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
          name: widget.api.userName ?? t('settings.unnamed'),
          email: widget.api.userEmail ?? '',
          subject: t('settings.complaint_subject'),
          message: _complaint.text.trim(),
        );
        setState(() {
          _complaint.clear();
          _notice = t('settings.complaint_sent');
        });
      });

  /// The invite code, once the server has been asked for it.
  ///
  /// Asked for quietly and drawn only when it arrives: settings is a screen
  /// people open to change one thing, and it should not sit empty waiting on a
  /// network call to show them a box.
  String? _referralCode;

  Future<void> _loadReferral() async {
    try {
      final data = await widget.api.rewards();
      final referral = data['referral'] as Map?;
      final code = (referral?['code'] ?? '').toString();
      if (mounted && code.isNotEmpty) setState(() => _referralCode = code);
    } catch (_) {
      // No code on screen is the right failure: the money screen has the whole
      // picture, and settings is not the place to explain a network problem.
    }
  }

  /// Bring somebody in, from the screen a motari already knows how to find.
  ///
  /// The full picture lives under Money, with what it has paid and who is
  /// riding. This is the code itself, because that is the part somebody opens
  /// settings looking for, and a code two taps away is a code nobody shares.
  Widget _referralPanel() {
    final code = _referralCode;
    if (code == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.card_giftcard, size: 15, color: Brand.orange),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(t('rewards.bring_someone'), style: Brand.micro),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(t('rewards.referral_how'),
                  style: const TextStyle(color: Brand.muted, fontSize: 11.5, height: 1.5)),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
                      decoration: BoxDecoration(
                        color: Brand.black,
                        border: Border.all(color: Brand.orange),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        code,
                        style: const TextStyle(
                            color: Brand.text,
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 2.5),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _codeButton(Icons.copy, t('rewards.copy'), () {
                    Clipboard.setData(ClipboardData(text: code));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(t('rewards.copied'))),
                    );
                  }),
                  const SizedBox(width: 6),
                  _codeButton(Icons.share, t('rewards.share'), () => _shareCode(code)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
      ],
    );
  }

  Widget _codeButton(IconData icon, String label, VoidCallback onTap) => Semantics(
        button: true,
        label: label,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: Brand.line),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 16, color: Brand.muted),
          ),
        ),
      );

  /// The same WhatsApp hand-off the rewards screen uses, for the same reason.
  Future<void> _shareCode(String code) async {
    final text = Uri.encodeComponent(t('rewards.share_text', {'code': code}));
    try {
      await launchUrl(Uri.parse('https://wa.me/?text=$text'),
          mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t('rewards.share_failed'))),
        );
      }
    }
  }

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

          _referralPanel(),

          const Panel(child: LanguageButton(inline: true)),
          const SizedBox(height: 10),
          if (widget.onSwitchToPassenger != null) ...[
            Panel(
              child: GestureDetector(
                onTap: () {
                  Navigator.of(context).popUntil((route) => route.isFirst);
                  widget.onSwitchToPassenger!();
                },
                behavior: HitTestBehavior.opaque,
                child: Row(
                  children: [
                    const Icon(Icons.two_wheeler, size: 15, color: Brand.orange),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        t('common.nav.passenger'),
                        style: const TextStyle(
                          color: Brand.text,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const Icon(Icons.chevron_right, size: 16, color: Brand.dim),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
          Panel(
            child: ValueListenableBuilder<UpdateStatus>(
              valueListenable: AppUpdater.status,
              builder: (context, s, _) => GestureDetector(
                onTap: () async {
                  final found = await AppUpdater.checkAndAutoUpdate(silent: false);
                  if (!found && context.mounted) {
                    setState(() {
                      _notice = t('update.up_to_date', {'version': s.currentVersion});
                    });
                  }
                },
                behavior: HitTestBehavior.opaque,
                child: Row(
                  children: [
                    const Icon(Icons.system_update_alt, size: 15, color: Brand.orange),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t('update.check'),
                            style: const TextStyle(
                              color: Brand.text,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text('v${s.currentVersion}', style: Brand.micro),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right, size: 16, color: Brand.dim),
                  ],
                ),
              ),
            ),
          ),
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
                  // Where it goes, said rather than asked.
                  //
                  // Switching this on used to open a network picker and a
                  // phone box: the same number the motari registered with,
                  // asked for a second time, and the network they are already
                  // on offered as a choice. Two chances to get wrong what the
                  // account already knows, and a mistyped payout number sends
                  // real money to a stranger. The registered number is used,
                  // and 078 and 079 are MTN while 072 and 073 are Airtel,
                  // which the number itself says.
                  if (p.instantPayout) ...[
                    const SizedBox(height: 8),
                    Text(
                      t('settings.payout_to', {
                        'phone': p.payoutPhone ?? '',
                        'operator': p.payoutOperator ?? '',
                      }),
                      style: Brand.micro,
                    ),
                    const SizedBox(height: 2),
                    Text(t('settings.payout_change'), style: Brand.micro),
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
