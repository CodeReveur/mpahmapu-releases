import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:latlong2/latlong.dart';

import 'i18n.dart';
import 'routing.dart';

/// The manoeuvre coming up, and how far off it is.
class NextTurn {
  final RouteStep step;
  final double metresAway;
  const NextTurn(this.step, this.metresAway);
}

/// Speaking the turns.
///
/// A motari is riding. They cannot read a screen, and a phone that shows the
/// next turn without saying it is a phone they will look at anyway, which is
/// the thing worth avoiding. So the route is spoken, and only when it is worth
/// hearing: once on the approach to a turn, once again at it, and never twice
/// for the same manoeuvre.
class TurnByTurn {
  /// Far enough out to act on, close enough to be about this turn.
  static const double _warnMetres = 180;

  /// At the manoeuvre itself.
  static const double _atMetres = 45;

  /// The voice for each language the app speaks.
  ///
  /// Kinyarwanda is not on the list because Android has no Kinyarwanda voice.
  /// A motari reading Kinyarwanda hears English, which is worse than hearing
  /// their own language and far better than hearing nothing at a junction.
  static const _voices = {
    'en': ['en-US', 'en-GB'],
    'fr': ['fr-FR', 'fr-CA'],
    'sw': ['sw-KE', 'sw-TZ'],
    'kinyy': ['rw-RW'],
  };

  final FlutterTts _tts = FlutterTts();
  bool _ready = false;

  /// The language actually being spoken, which is not always the one on screen.
  String _voiceLang = Lang.fallback;

  /// Manoeuvres already announced, by their index in the route.
  final Set<int> _warned = {};
  final Set<int> _said = {};

  /// Whether the motari wants to hear anything at all.
  bool muted = false;

  /// What the screen should show. Kept here rather than recomputed by the
  /// screen so the banner and the voice can never disagree about which turn
  /// is next.
  NextTurn? next;

  Future<void> _prepare() async {
    if (_ready) return;
    try {
      _voiceLang = await _pickVoice();
      await _tts.setLanguage(_voices[_voiceLang]?.first ?? 'en-US');
      // A little slower than default: an instruction misheard at speed is worse
      // than one that takes half a second longer.
      await _tts.setSpeechRate(0.46);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      _ready = true;
    } catch (e) {
      debugPrint('[motari] speech unavailable: $e');
    }
  }

  /// The nearest language this phone can actually pronounce: the one on screen
  /// if a voice exists for it, English otherwise.
  Future<String> _pickVoice() async {
    final wanted = appLanguage.value;
    for (final code in _voices[wanted] ?? const <String>[]) {
      try {
        if (await _tts.isLanguageAvailable(code) == true) return wanted;
      } catch (_) {
        // An engine that will not answer is an engine we do not trust here.
      }
    }
    return Lang.fallback;
  }

  /// The language on screen changed, so the voice may have to change with it.
  /// Cheap to call: the next instruction re-picks and re-configures.
  void relearnVoice() => _ready = false;

  /// Where the ride is now, and the road it is following. Says whatever this
  /// position has earned and nothing it has not.
  Future<void> update(Route? route, LatLng at) async {
    if (route == null || route.steps.isEmpty) {
      next = null;
      return;
    }

    for (var i = 0; i < route.steps.length; i++) {
      final step = route.steps[i];
      if (!step.worthSaying || _said.contains(i)) continue;

      final away = metresBetween(at, step.at);

      // The first manoeuvre still ahead is the one to show, however far off it
      // is. The screen says it early; the voice waits until it is useful.
      next = NextTurn(step, away);

      // Too far to be about this turn yet; and since steps run in order,
      // nothing after it can be either.
      if (away > _warnMetres) return;

      if (muted) return;

      if (away <= _atMetres) {
        _said.add(i);
        _warned.add(i);
        await _prepare();
        await say(step.spokenIn(_voiceLang));
        return;
      }

      if (!_warned.contains(i)) {
        _warned.add(i);
        await _prepare();
        // "In 200 metres" rounds the real distance, because a motari hearing
        // "in 173 metres" learns nothing they did not already know.
        final rounded = (away / 50).round() * 50;
        await say(tIn(_voiceLang, 'nav.in_metres', {
          'm': rounded,
          'what': _lowerFirst(step.spokenIn(_voiceLang)),
        }));
        return;
      }
      return;
    }

    // Every manoeuvre is behind us.
    next = null;
  }

  String _lowerFirst(String s) => s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

  Future<void> say(String words) async {
    if (muted) return;
    await _prepare();
    if (!_ready) return;
    try {
      await _tts.stop();
      await _tts.speak(words);
    } catch (e) {
      debugPrint('[motari] could not speak: $e');
    }
  }

  /// A new route, or a new ride: forget what was already said.
  void reset() {
    _warned.clear();
    _said.clear();
    next = null;
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {
      // Nothing to stop.
    }
  }
}
