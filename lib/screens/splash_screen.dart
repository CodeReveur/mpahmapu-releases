import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// The first two seconds of the app: a moto riding in along a road.
///
/// It is the brand mark in motion rather than a logo sitting still. The road
/// scrolls beneath, the moto rides in from the left and settles, its headlight
/// throws light down the tarmac, and the name arrives under it. Everything is
/// drawn — no images — so it stays sharp on any screen and costs nothing to
/// ship.
class SplashScreen extends StatefulWidget {
  final VoidCallback onDone;
  const SplashScreen({super.key, required this.onDone});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

/// How far off-screen left the moto starts.
const double _kRideInFrom = 180;

const double _kMotoSize = 62;

/// The moto glyph's wheels sit at 0.73 of its box, measured off the font, so
/// the box has to ride high for the wheels to meet the road.
const double _kWheelsInBox = 0.73;

/// Where the road is drawn, from the middle of the scene.
const double _kRoadY = 12;

/// The moto's box centre, placed so its wheels land on the road.
const double _kMotoCentreY = _kRoadY - (_kWheelsInBox - 0.5) * _kMotoSize;

/// Half the moto, for putting the headlight at the front and the speed lines
/// behind the back wheel.
const double _kMotoHalf = _kMotoSize / 2;

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  /// How far the moto has ridden in, easing to a stop at the centre.
  late final Animation<double> _rideIn = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.00, 0.42, curve: Curves.easeOutCubic),
  );

  /// The name, arriving once the moto has somewhere to be.
  late final Animation<double> _name = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.34, 0.62, curve: Curves.easeOut),
  );

  /// The whole scene stepping aside for the app.
  late final Animation<double> _leave = CurvedAnimation(
    parent: _c,
    curve: const Interval(0.86, 1.00, curve: Curves.easeIn),
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
          final t = _c.value;
          return Opacity(
            opacity: 1 - _leave.value,
            child: Center(
              child: SizedBox(
                height: 190,
                width: double.infinity,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Road, speed lines and headlight, all one painting so they
                    // share a clock and cannot drift apart.
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _RoadPainter(
                          t: t,
                          arrival: _rideIn.value,
                        ),
                      ),
                    ),
                    _moto(t),
                    _wordmark(),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// The moto itself: rides in from off-screen left, then bobs over the road
  /// the way a small bike does on Kigali tarmac.
  Widget _moto(double t) {
    final arrived = _rideIn.value;
    // Starts off-screen left and eases to a stop at the centre.
    final x = -_kRideInFrom + arrived * _kRideInFrom;
    // Only ever lifts. A bob that swung both ways would put the wheels through
    // the tarmac half the time.
    final lift = (math.sin(t * math.pi * 2 * 3.4) + 1) / 2 * 2.2 * arrived;
    final tilt = math.sin(t * math.pi * 2 * 2.1) * 0.012 * arrived;

    return Transform.translate(
      offset: Offset(x, _kMotoCentreY - lift),
      child: Transform.rotate(
        angle: tilt,
        child: const Icon(Icons.two_wheeler, size: _kMotoSize, color: Brand.orange),
      ),
    );
  }

  Widget _wordmark() => Transform.translate(
        offset: Offset(0, 46 + (1 - _name.value) * 10),
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
}

/// The road under the moto: tarmac, lane markings running past, the speed lines
/// it drags behind it, and the light its headlight throws forward.
class _RoadPainter extends CustomPainter {
  /// The whole animation, 0 to 1.
  final double t;

  /// How far the moto has ridden in, 0 to 1. The road only lives once it moves.
  final double arrival;

  _RoadPainter({required this.t, required this.arrival});

  @override
  void paint(Canvas canvas, Size size) {
    final roadY = size.height / 2 + _kRoadY;
    // Where the moto comes to rest, which is what the light and the speed lines
    // have to line up with.
    final centre = size.width / 2;

    // The tarmac: a thin line that fades out at both ends, so the road has no
    // edges to notice.
    final road = Paint()
      ..shader = const LinearGradient(
        colors: [Colors.transparent, Brand.line, Brand.line, Colors.transparent],
        stops: [0.0, 0.18, 0.82, 1.0],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..strokeWidth = 2;
    canvas.drawLine(Offset(0, roadY), Offset(size.width, roadY), road);

    // Lane markings, running right to left. They keep moving after the moto has
    // settled, which is what says the moto is the thing standing still.
    const dash = 26.0, gap = 22.0;
    final period = dash + gap;
    final shift = (t * 1400) % period;
    final marking = Paint()
      ..color = Brand.orange.withValues(alpha: 0.85)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (var x = -period - shift; x < size.width + period; x += period) {
      final a = x, b = x + dash;
      // Fade the markings out towards both edges, with the road.
      final mid = (a + b) / 2;
      final edge = (mid / size.width - 0.5).abs() * 2;
      final fade = (1 - edge * edge).clamp(0.0, 1.0);
      if (fade <= 0.02) continue;
      canvas.drawLine(
        Offset(a, roadY + 9),
        Offset(b, roadY + 9),
        Paint()
          ..color = marking.color.withValues(alpha: 0.85 * fade * arrival)
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }

    // Speed lines trailing the moto: three, at different heights and lengths,
    // breathing so the bike reads as moving rather than parked.
    for (var i = 0; i < 3; i++) {
      final phase = (t * 2.4 + i * 0.33) % 1.0;
      final len = 26.0 + i * 14 + math.sin(phase * math.pi) * 16;
      final y = roadY - 34 - i * 11.0;
      final startX = centre - _kMotoHalf - 6 - phase * 30;
      canvas.drawLine(
        Offset(startX - len, y),
        Offset(startX, y),
        Paint()
          ..color = Brand.orange.withValues(alpha: (0.30 - i * 0.07) * arrival)
          ..strokeWidth = 2.4
          ..strokeCap = StrokeCap.round,
      );
    }

    // The headlight: a wedge of light thrown down the road ahead, brightening
    // as the moto arrives.
    final nose = centre + _kMotoHalf - 4;
    final beam = Path()
      ..moveTo(nose, roadY - 16)
      ..lineTo(nose + 130, roadY - 32)
      ..lineTo(nose + 130, roadY + 3)
      ..close();
    canvas.drawPath(
      beam,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            Brand.orange.withValues(alpha: 0.24 * arrival),
            Brand.orange.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromLTWH(nose, roadY - 32, 130, 36)),
    );
  }

  @override
  bool shouldRepaint(_RoadPainter old) => old.t != t || old.arrival != arrival;
}
