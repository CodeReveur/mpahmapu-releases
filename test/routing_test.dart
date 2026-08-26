import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:motari/i18n.dart';
import 'package:motari/routing.dart';

/// One OSRM answer, trimmed to the shape the app actually reads: a line to
/// draw and the manoeuvres along it. Kept here rather than fetched so the test
/// says something about our parsing rather than about the internet.
final _osrm = jsonEncode({
  'routes': [
    {
      'distance': 1400.0,
      'duration': 220.0,
      'geometry': {
        'coordinates': [
          [30.0619, -1.9441],
          [30.0630, -1.9450],
          [30.0641, -1.9462],
        ],
      },
      'legs': [
        {
          'steps': [
            {
              'name': 'KN 3 Ave',
              'distance': 400.0,
              'maneuver': {'type': 'depart', 'modifier': '', 'location': [30.0619, -1.9441]},
            },
            {
              'name': 'KN 5 Rd',
              'distance': 600.0,
              'maneuver': {'type': 'turn', 'modifier': 'left', 'location': [30.0630, -1.9450]},
            },
            {
              // Under twenty metres: real in the data, noise on a moto.
              'name': '',
              'distance': 8.0,
              'maneuver': {'type': 'turn', 'modifier': 'right', 'location': [30.0635, -1.9455]},
            },
            {
              'name': '',
              'distance': 0.0,
              'maneuver': {'type': 'arrive', 'modifier': '', 'location': [30.0641, -1.9462]},
            },
          ],
        },
      ],
    },
  ],
});

Route _parsed() =>
    Route.fromJson((jsonDecode(_osrm)['routes'] as List).first as Map<String, dynamic>);

void main() {
  test('an OSRM answer becomes a line and its manoeuvres', () {
    final route = _parsed();
    expect(route.line.length, 3);
    expect(route.line.first, LatLng(-1.9441, 30.0619));
    expect(route.steps.length, 4);
    expect(route.distanceM, 1400.0);
  });

  test('a step of a few metres is not worth saying, an arrival always is', () {
    final steps = _parsed().steps;
    expect(steps[0].worthSaying, isTrue);
    expect(steps[1].worthSaying, isTrue);
    expect(steps[2].worthSaying, isFalse, reason: 'eight metres is noise');
    expect(steps[3].worthSaying, isTrue, reason: 'arriving is always worth saying');
  });

  test('every language has words for a turn, and they are its own', () {
    final turn = _parsed().steps[1];
    final said = {for (final code in Lang.codes) code: turn.spokenIn(code)};

    for (final entry in said.entries) {
      expect(entry.value, isNotEmpty);
      // A missing key falls through to the key itself; that must never ship.
      expect(entry.value, isNot(contains('nav.')), reason: '${entry.key} has a gap');
      expect(entry.value, contains('KN 5 Rd'), reason: '${entry.key} drops the road name');
    }

    expect(said['en'], 'Turn left onto KN 5 Rd');
    expect(said['kinyy'], startsWith('Kata ibumoso'));
    expect(said['fr'], startsWith('Tournez à gauche'));
    expect(said['sw'], startsWith('Geuka kushoto'));
  });

  test('a road with no name is not announced as an empty one', () {
    final step = RouteStep(
      type: 'turn',
      modifier: 'right',
      road: '   ',
      distanceM: 90,
      at: LatLng(-1.94, 30.06),
    );
    for (final code in Lang.codes) {
      expect(step.spokenIn(code).trim(), step.spokenIn(code));
      expect(step.spokenIn(code), isNot(contains('{road}')));
    }
  });

  test('arriving says so rather than describing a turn', () {
    for (final code in Lang.codes) {
      final words = _parsed().steps[3].spokenIn(code);
      expect(words, isNot(contains('{')));
      expect(words, isNotEmpty);
    }
    expect(_parsed().steps[3].spokenIn('en'), 'You have arrived');
  });

  test('metres between two points are the metres on the ground', () {
    // Roughly a kilometre apart in Kigali, checked against the real distance.
    final a = LatLng(-1.9441, 30.0619);
    final b = LatLng(-1.9531, 30.0619);
    expect(metresBetween(a, b), closeTo(1000, 20));
    expect(metresBetween(a, a), closeTo(0, 0.001));
  });
}
