import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'i18n.dart';

/// Turn by turn routing, the same way the website does it.
///
/// The road geometry comes from the public OSRM service, along with the
/// manoeuvres along it. Nothing here throws: a motari whose route lookup failed
/// still has a map, a pin and their own eyes, and an exception in the middle of
/// a ride would take all three away.
class Routing {
  static const _host = 'router.project-osrm.org';

  /// The road between two points, or null if it could not be found.
  static Future<Route?> between(LatLng from, LatLng to) async {
    final coords = '${from.longitude},${from.latitude};${to.longitude},${to.latitude}';
    final uri = Uri.https(_host, '/route/v1/driving/$coords', {
      'overview': 'full',
      'geometries': 'geojson',
      'steps': 'true',
    });
    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode >= 400) return null;
      final body = jsonDecode(res.body);
      if (body is! Map || body['routes'] is! List || (body['routes'] as List).isEmpty) {
        return null;
      }
      return Route.fromJson((body['routes'] as List).first as Map<String, dynamic>);
    } catch (_) {
      // No route is a missing convenience, not a failed ride.
      return null;
    }
  }
}

/// A road, and the manoeuvres along it.
class Route {
  final double distanceM;
  final double durationS;

  /// The line to draw on the map.
  final List<LatLng> line;

  final List<RouteStep> steps;

  const Route({
    required this.distanceM,
    required this.durationS,
    required this.line,
    required this.steps,
  });

  factory Route.fromJson(Map<String, dynamic> j) {
    final coords = (j['geometry']?['coordinates'] as List?) ?? const [];
    final line = coords
        .whereType<List>()
        .where((c) => c.length >= 2)
        .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
        .toList();

    final steps = <RouteStep>[];
    for (final leg in (j['legs'] as List?) ?? const []) {
      for (final s in (leg['steps'] as List?) ?? const []) {
        final m = s['maneuver'] as Map<String, dynamic>?;
        final at = (m?['location'] as List?) ?? const [];
        if (at.length < 2) continue;
        steps.add(RouteStep(
          type: m?['type'] as String? ?? '',
          modifier: m?['modifier'] as String? ?? '',
          road: s['name'] as String? ?? '',
          distanceM: ((s['distance'] as num?) ?? 0).toDouble(),
          at: LatLng((at[1] as num).toDouble(), (at[0] as num).toDouble()),
        ));
      }
    }

    return Route(
      distanceM: ((j['distance'] as num?) ?? 0).toDouble(),
      durationS: ((j['duration'] as num?) ?? 0).toDouble(),
      line: line,
      steps: steps,
    );
  }
}

/// One manoeuvre, and the words for it.
class RouteStep {
  final String type;
  final String modifier;
  final String road;
  final double distanceM;
  final LatLng at;

  const RouteStep({
    required this.type,
    required this.modifier,
    required this.road,
    required this.distanceM,
    required this.at,
  });

  /// What to say, in a named language.
  ///
  /// OSRM names the manoeuvre in its own vocabulary; the catalogue supplies the
  /// words. The language is passed in rather than read from the screen because
  /// the voice may not be able to pronounce what the reader chose: a phone with
  /// no Kinyarwanda voice still has to say something out loud.
  String spokenIn(String lang) {
    String say(String key, [Map<String, Object?>? vars]) => tIn(lang, key, vars);

    final named = road.trim();
    final onto = named.isEmpty ? '' : say('nav.onto', {'road': named});
    final mod = modifier.toLowerCase();

    String dir() {
      if (mod.contains('left')) {
        if (mod.contains('slight')) return say('nav.slight_left');
        if (mod.contains('sharp')) return say('nav.sharp_left');
        return say('nav.turn_left');
      }
      if (mod.contains('right')) {
        if (mod.contains('slight')) return say('nav.slight_right');
        if (mod.contains('sharp')) return say('nav.sharp_right');
        return say('nav.turn_right');
      }
      if (mod.contains('uturn')) return say('nav.uturn');
      if (mod.contains('straight')) return say('nav.straight');
      return say('nav.go_on');
    }

    switch (type) {
      case 'depart':
        return named.isEmpty ? say('nav.depart') : say('nav.depart_on', {'road': named});
      case 'arrive':
        return say('nav.arrive');
      case 'roundabout':
      case 'rotary':
        return say('nav.roundabout', {'onto': onto});
      case 'merge':
        return say('nav.merge', {'onto': onto});
      case 'fork':
        final key = mod.contains('left')
            ? 'nav.keep_left'
            : mod.contains('right')
                ? 'nav.keep_right'
                : 'nav.keep_straight';
        return say(key, {'onto': onto});
      case 'on ramp':
        return say('nav.ramp', {'onto': onto});
      case 'off ramp':
        return say('nav.exit_ramp', {'onto': onto});
      case 'new name':
        return named.isEmpty
            ? say('nav.continue_plain', {'onto': ''})
            : say('nav.continue_onto', {'road': named});
      case 'continue':
        return say('nav.continue_plain', {'onto': onto});
      default:
        return '${capitalised(dir())}$onto';
    }
  }

  /// The same, in the language on screen. What the banner shows.
  String get spoken => spokenIn(appLanguage.value);

  /// Whether this is worth saying at all. A step of a few metres between two
  /// others is noise on a moto, not guidance.
  bool get worthSaying => type == 'arrive' || distanceM >= 20;
}

/// A leading capital, for a phrase that starts a sentence.
String capitalised(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Metres between two points, good enough for deciding when to speak.
double metresBetween(LatLng a, LatLng b) {
  const r = 6371000.0;
  final dLat = (b.latitude - a.latitude) * math.pi / 180;
  final dLng = (b.longitude - a.longitude) * math.pi / 180;
  final s = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(a.latitude * math.pi / 180) *
          math.cos(b.latitude * math.pi / 180) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return r * 2 * math.atan2(math.sqrt(s), math.sqrt(1 - s));
}
