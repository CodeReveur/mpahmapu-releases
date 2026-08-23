import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../i18n.dart';
import '../theme.dart';

/// The first seconds of the app, told as the thing the app is for: someone
/// waiting at the roadside, a moto that comes for them, and the moment it pulls
/// up alongside.
///
/// The road only runs past by as far as the moto actually travels, and stops
/// when it stops — that is what makes it an arrival rather than a loop that
/// happens to end. Everything is drawn except the MpahMapu mark at the foot, so
/// it stays sharp on any screen and adds nothing to the download.
class SplashScreen extends StatefulWidget {
  final VoidCallback onDone;
  const SplashScreen({super.key, required this.onDone});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

/// Where the moto starts, off to the left of everything.
const double _kRideInFrom = 260;

const double _kMotoSize = 62;
const double _kPersonSize = 40;

/// Measured off the font: the moto's wheels sit at 0.73 of its box and the
/// passenger's feet at 0.77 of theirs, so both boxes ride high for what they
/// stand on to meet the road.
const double _kMotoFeet = 0.73;
const double _kPersonFeet = 0.77;

/// The road, from the middle of the scene.
const double _kRoadY = 14;

const double _kMotoCentreY = _kRoadY - (_kMotoFeet - 0.5) * _kMotoSize;
const double _kPersonCentreY = _kRoadY - (_kPersonFeet - 0.5) * _kPersonSize;

/// Where the two of them end up: the moto pulled in just short of the passenger.
const double _kMotoRestX = -22;
const double _kPersonX = 46;

const double _kMotoHalf = _kMotoSize / 2;

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  /// The ride: coming in at speed and braking to a stop beside them. The long
  /// interval and the gentle curve are what make it a journey to watch rather
  /// than a jump that happens to have frames in it.
  late final Animation<double> _ride = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.00, 0.46, curve: Curves.decelerate),
  );

  /// The ride in plain time rather than eased distance. Waiting fades with the
  /// clock, not with the brakes, or it would be gone before the moto is close.
  double get _approach => (_c.value / 0.46).clamp(0.0, 1.0);

  /// The passenger noticing they have been found.
  late final Animation<double> _greet = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.43, 0.56, curve: Curves.easeOut),
  );

  late final Animation<double> _name = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.44, 0.58, curve: Curves.easeOut),
  );

  /// Whose platform this is, signed at the foot.
  late final Animation<double> _from = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.56, 0.70, curve: Curves.easeOut),
  );

  /// The scene stepping aside. The moto stops at 1104ms and the app opens at
  /// 2400ms, so the arrival is held for about the second it deserves: the name
  /// and the mark land into that pause rather than racing the brakes.
  late final Animation<double> _leave = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.87, 1.00, curve: Curves.easeIn),
  );

  @override
  void initState() {
    super.initState();
    _c.forward().whenComplete(widget.onDone);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Brand.black,
      body: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          return Opacity(
            opacity: 1 - _leave.value,
            child: Center(
              child: SizedBox(
                height: 260,
                width: double.infinity,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _RoadPainter(
                          t: _c.value,
                          arrival: _ride.value,
                          approach: _approach,
                        ),
                      ),
                    ),
                    _passenger(),
                    _moto(),
                    _wordmark(),
                    _poweredBy(),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Someone at the roadside, waiting. They stand still; the ring going out
  /// around them is the painter's, and it is what says they are asking.
  Widget _passenger() {
    // A small hop the moment the moto pulls up: they have been found.
    final hop = math.sin(_greet.value * math.pi);
    return Transform.translate(
      offset: Offset(_kPersonX, _kPersonCentreY - hop * 5),
      child: Transform.scale(
        scale: 1 + hop * 0.09,
        child: const Icon(Icons.person, size: _kPersonSize, color: Brand.text),
      ),
    );
  }

  /// The moto: in from off-screen left, easing to a stop beside them, idling
  /// there afterwards rather than freezing mid-frame.
  Widget _moto() {
    final arrived = _ride.value;
    final x = _kMotoRestX - _kRideInFrom * (1 - arrived);

    // Rough while it is moving; once stopped it settles to an idle.
    final rough = 1 - arrived;
    final lift = (math.sin(_c.value * math.pi * 2 * 3.4) + 1) / 2 * 2.2 * rough;
    final idle = (math.sin(_c.value * math.pi * 2 * 1.3) + 1) / 2 * 0.8 * arrived;
    final tilt = math.sin(_c.value * math.pi * 2 * 2.1) * 0.012 * rough;

    return Transform.translate(
      offset: Offset(x, _kMotoCentreY - lift - idle),
      child: Transform.rotate(
        angle: tilt,
        child: const Icon(Icons.two_wheeler, size: _kMotoSize, color: Brand.orange),
      ),
    );
  }

  Widget _wordmark() => Transform.translate(
        offset: Offset(0, 64 + (1 - _name.value) * 10),
        child: Opacity(
          opacity: _name.value,
          child: const Text(
            'MOTARI',
            style: TextStyle(
              color: Brand.text,
              fontSize: 19,
              fontWeight: FontWeight.w900,
              letterSpacing: 7,
            ),
          ),
        ),
      );

  /// MpahMapu's own mark, in its own gold. The logo carries the platform; the
  /// app above it carries one part of it.
  Widget _poweredBy() => Transform.translate(
        offset: Offset(0, 106 + (1 - _from.value) * 6),
        child: Opacity(
          opacity: _from.value,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                t('splash.powered_by'),
                style: const TextStyle(
                  color: Brand.dim,
                  fontSize: 8,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2.4,
                ),
              ),
              const SizedBox(height: 7),
              Image.asset(
                'assets/brand/mpahmapu.png',
                // 480x105 in the original, so this is about 100 wide: enough
                // for the wordmark beside the monogram to still be read.
                height: 22,
                filterQuality: FilterQuality.high,
                // An asset that fails to decode should cost the splash nothing.
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      );
}

/// The road: tarmac, the markings running past, the lines the moto drags behind
/// it, the light it throws ahead, and the ring around someone waiting.
class _RoadPainter extends CustomPainter {
  /// The whole animation, 0 to 1.
  final double t;

  /// How much of the ride is done as distance, 0 to 1.
  final double arrival;

  /// How much of the ride is done as time, 0 to 1. The waiting fades on this,
  /// so it lasts until the moto is genuinely there.
  final double approach;

  _RoadPainter({required this.t, required this.arrival, required this.approach});

  @override
  void paint(Canvas canvas, Size size) {
    final roadY = size.height / 2 + _kRoadY;
    final centre = size.width / 2;
    final motoX = centre + _kMotoRestX - _kRideInFrom * (1 - arrival);
    final personX = centre + _kPersonX;

    // The tarmac, fading out at both ends so the road has no edges to notice.
    canvas.drawLine(
      Offset(0, roadY),
      Offset(size.width, roadY),
      Paint()
        ..shader = const LinearGradient(
          colors: [Colors.transparent, Brand.line, Brand.line, Colors.transparent],
          stops: [0.0, 0.18, 0.82, 1.0],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
        ..strokeWidth = 2,
    );

    // Markings run past by exactly as far as the moto travels, and stop dead
    // when it does. A road that kept scrolling would say it never arrived.
    const dash = 26.0, gap = 22.0;
    const period = dash + gap;
    final shift = (arrival * _kRideInFrom) % period;
    for (var x = -period - shift; x < size.width + period; x += period) {
      final mid = x + dash / 2;
      final edge = (mid / size.width - 0.5).abs() * 2;
      final fade = (1 - edge * edge).clamp(0.0, 1.0);
      if (fade <= 0.02) continue;
      canvas.drawLine(
        Offset(x, roadY + 9),
        Offset(x + dash, roadY + 9),
        Paint()
          ..color = Brand.orange.withValues(alpha: 0.8 * fade)
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }

    // Speed lines behind the moto, thinning as it slows and gone once stopped.
    final speed = (1 - arrival).clamp(0.0, 1.0);
    if (speed > 0.02) {
      for (var i = 0; i < 3; i++) {
        final phase = (t * 2.4 + i * 0.33) % 1.0;
        final len = 26.0 + i * 14 + math.sin(phase * math.pi) * 16;
        final y = roadY - 34 - i * 11.0;
        final startX = motoX - _kMotoHalf - 6 - phase * 30;
        canvas.drawLine(
          Offset(startX - len, y),
          Offset(startX, y),
          Paint()
            ..color = Brand.orange.withValues(alpha: (0.32 - i * 0.08) * speed)
            ..strokeWidth = 2.4
            ..strokeCap = StrokeCap.round,
        );
      }
    }

    // Someone waiting is asking to be seen: rings going out from them, which
    // stop once the moto has pulled up and there is nothing left to ask.
    final waiting = (1 - approach).clamp(0.0, 1.0);
    if (waiting > 0.02) {
      for (var i = 0; i < 2; i++) {
        final phase = ((t * 1.9) + i * 0.5) % 1.0;
        canvas.drawCircle(
          Offset(personX, roadY - 16),
          11 + phase * 30,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..color = Brand.orange.withValues(alpha: (1 - phase) * 0.34 * waiting),
        );
      }
    }

    // The headlight, thrown down the road towards the person it is going to.
    final nose = motoX + _kMotoHalf - 4;
    canvas.drawPath(
      Path()
        ..moveTo(nose, roadY - 16)
        ..lineTo(nose + 120, roadY - 30)
        ..lineTo(nose + 120, roadY + 3)
        ..close(),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            Brand.orange.withValues(alpha: 0.24),
            Brand.orange.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromLTWH(nose, roadY - 30, 120, 34)),
    );
  }

  @override
  bool shouldRepaint(_RoadPainter old) =>
      old.t != t || old.arrival != arrival || old.approach != approach;
}
