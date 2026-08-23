import 'package:flutter/material.dart';

import '../i18n.dart';
import '../permissions.dart';
import '../theme.dart';
import '../widgets/language_button.dart';

/// The first thing a motari sees. Location is not negotiable: a moto the
/// platform cannot place is a moto no passenger can reach, so the way through
/// this screen is to allow it. Notifications and sound are asked for in the
/// same breath but never block the door.
///
/// It re-checks itself whenever the app comes back from the system settings,
/// so a motari who leaves to switch something on finds the screen already
/// caught up when they return.
class PermissionGate extends StatefulWidget {
  final VoidCallback onReady;
  const PermissionGate({super.key, required this.onReady});

  @override
  State<PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<PermissionGate>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  Access _location = Access.ask;
  Access _notifications = Access.ask;
  bool _checking = true;
  bool _asking = false;

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check(thenAsk: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulse.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the settings app: whatever they changed there is the truth now.
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check({bool thenAsk = false}) async {
    final location = await Permissions.locationStatus();
    final notifications = await Permissions.notificationStatus();
    if (!mounted) return;
    setState(() {
      _location = location;
      _notifications = notifications;
      _checking = false;
    });
    // Everything already in place: no reason to make them read this screen.
    if (location.ok) {
      widget.onReady();
      return;
    }
    // First run: put the system dialogs up straight away rather than making
    // them tap a button to be shown a button.
    if (thenAsk && location == Access.ask) _askAll();
  }

  Future<void> _askAll() async {
    if (_asking) return;
    setState(() => _asking = true);

    final location = await Permissions.requestLocation();
    if (mounted) setState(() => _location = location);

    if (_notifications == Access.ask) {
      final notifications = await Permissions.requestNotifications();
      if (mounted) setState(() => _notifications = notifications);
    }

    if (!mounted) return;
    setState(() => _asking = false);
    if (location.ok) widget.onReady();
  }

  Future<void> _fixLocation() async {
    switch (_location) {
      case Access.serviceOff:
        await Permissions.openLocationSettings();
      case Access.blocked:
        await openPhoneSettings();
      case _:
        await _askAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Brand.orange),
              const SizedBox(height: 14),
              Text(t("gate.checking"), style: Brand.micro),
            ],
          ),
        ),
      );
    }

    final ready = _location.ok;

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            const Positioned(top: 6, right: 10, child: LanguageButton()),
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 40, 22, 22),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 430),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _mark(),
                      const SizedBox(height: 22),
                      Text(
                        t('gate.title'),
                        style: const TextStyle(
                          color: Brand.text,
                          fontSize: 21,
                          fontWeight: FontWeight.w900,
                          height: 1.15,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        t('gate.subtitle'),
                        style: const TextStyle(color: Brand.muted, fontSize: 12.5, height: 1.4),
                      ),
                      const SizedBox(height: 20),

                      _row(
                        icon: Icons.my_location,
                        title: t('gate.location'),
                        why: t('gate.location.why'),
                        access: _location,
                        required: true,
                      ),
                      const SizedBox(height: 8),
                      _row(
                        icon: Icons.notifications_active_outlined,
                        title: t('gate.notifications'),
                        why: t('gate.notifications.why'),
                        access: _notifications,
                        required: false,
                        onFix: _notifications == Access.blocked
                            ? openPhoneSettings
                            : () async {
                                final next = await Permissions.requestNotifications();
                                if (mounted) setState(() => _notifications = next);
                              },
                      ),
                      const SizedBox(height: 8),
                      _row(
                        icon: Icons.volume_up_outlined,
                        title: t('gate.sound'),
                        why: t('gate.sound.why'),
                        access: Access.granted,
                        required: false,
                        note: t('gate.sound_note'),
                      ),

                      const SizedBox(height: 18),

                      if (!ready) ...[
                        Text(
                          switch (_location) {
                            Access.serviceOff => t('gate.location_service_off'),
                            Access.blocked => t('gate.location_blocked'),
                            _ => t('gate.location_needed'),
                          },
                          style: const TextStyle(color: Brand.amber, fontSize: 11.5, height: 1.45),
                        ),
                        const SizedBox(height: 12),
                      ],

                      PrimaryButton(
                        label: ready
                            ? t('gate.start')
                            : _location == Access.serviceOff
                                ? t('gate.turn_on')
                                : _location == Access.blocked
                                    ? t('gate.open_settings')
                                    : t('gate.allow_all'),
                        icon: ready ? Icons.two_wheeler : Icons.lock_open,
                        onPressed: _asking ? null : (ready ? widget.onReady : _fixLocation),
                      ),

                      if (!ready) ...[
                        const SizedBox(height: 6),
                        TextButton(
                          onPressed: _asking ? null : () => _check(),
                          child: Text(
                            t('gate.check_again'),
                            style: const TextStyle(
                              color: Brand.muted,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The badge at the top: a moto inside a ring that breathes while the phone
  /// is still deciding, so the screen never looks frozen.
  Widget _mark() => Center(
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (context, child) {
            final glow = 12 + _pulse.value * 16;
            return Container(
              width: 74,
              height: 74,
              decoration: BoxDecoration(
                color: Brand.orange,
                borderRadius: BorderRadius.circular(22),
                boxShadow: [
                  BoxShadow(
                    color: Brand.orange.withValues(alpha: 0.16 + _pulse.value * 0.16),
                    blurRadius: glow,
                    spreadRadius: _pulse.value * 3,
                  ),
                ],
              ),
              child: child,
            );
          },
          child: const Icon(Icons.two_wheeler, color: Colors.black, size: 38),
        ),
      );

  Widget _row({
    required IconData icon,
    required String title,
    required String why,
    required Access access,
    required bool required,
    String? note,
    Future<void> Function()? onFix,
  }) {
    final ok = access.ok;
    return Panel(
      borderColor: ok
          ? const Color(0xFF14532D)
          : required
              ? const Color(0xFF7C3A10)
              : Brand.line,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: ok ? const Color(0xFF0B2B18) : const Color(0xFF141414),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 15, color: ok ? Brand.green : Brand.orange),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Brand.text,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      required ? t('gate.required') : t('gate.optional'),
                      style: TextStyle(
                        color: required ? Brand.orange : Brand.dim,
                        fontSize: 8,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
                      ),
                    ),
                    const Spacer(),
                    if (ok)
                      const Icon(Icons.check_circle, size: 15, color: Brand.green)
                    else
                      Text(
                        access.label,
                        style: const TextStyle(
                          color: Brand.amber,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  note ?? why,
                  style: const TextStyle(color: Brand.muted, fontSize: 11, height: 1.4),
                ),
                if (!ok && onFix != null) ...[
                  const SizedBox(height: 6),
                  GestureDetector(
                    onTap: onFix,
                    child: Text(
                      access == Access.blocked ? t('gate.open_settings') : t('gate.allow'),
                      style: const TextStyle(
                        color: Brand.orange,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.9,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
