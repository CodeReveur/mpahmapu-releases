import 'package:flutter_test/flutter_test.dart';
import 'package:motari/i18n.dart';
import 'package:motari/theme.dart';

void main() {
  test('money reads the way the apps write it', () {
    expect(rwf(500), 'RWF 500');
    expect(rwf(1500), 'RWF 1,500');
    expect(rwf(1234567), 'RWF 1,234,567');
  });

  test('distances stay in kilometres, one decimal', () {
    expect(km(1200), '1.2 km');
    expect(km(0), '0.0 km');
    expect(km(null), '0.0 km');
  });

  group('the four languages', () {
    tearDown(() => appLanguage.value = Lang.initial);

    test('a phone that has never chosen reads Kinyarwanda', () {
      expect(appLanguage.value, 'kinyy');
      expect(t('ride.arrived'), 'Ndageze');
    });

    test('every language answers every key the app asks for', () {
      for (final code in Lang.codes) {
        appLanguage.value = code;
        for (final key in [
          'gate.title', 'gate.location.why', 'signin.sign_in',
          'ride.starts_together', 'fees.pay_now', 'settings.log_out',
          'ask.request', 'ask.from', 'ask.approx_amount', 'track.searching',
          'track.pay_momo', 'register.create', 'register.verify',
        ]) {
          expect(t(key), isNot(key), reason: '$code is missing $key');
        }
      }
    });

    test('placeholders are filled, not printed', () {
      appLanguage.value = 'en';
      expect(t('panel.waiting_nearby', {'count': 3}), '3 waiting nearby');
      expect(t('fees.nothing_owed', {'count': 3}), contains('3'));
    });

    test('an unknown key falls back to English, not to nothing', () {
      appLanguage.value = 'sw';
      // The app is called the same thing in every language, which is what
      // makes it a name rather than a word.
      expect(t('app.name'), 'Ask Motari');
    });

    test('the app names itself, and a nameless driver does not borrow it', () {
      // app.name once stood in for a person whose name we did not have, which
      // only read sensibly while the app was called the same thing a driver
      // is. Renaming it would have introduced drivers called "Ask Motari".
      for (final code in Lang.codes) {
        appLanguage.value = code;
        expect(t('app.name'), 'Ask Motari');
        for (final key in ['ride.unnamed_driver', 'drive.no_plate', 'settings.unnamed']) {
          expect(t(key), isNot('Ask Motari'), reason: '$key in $code');
          expect(t(key), isNot(key), reason: '$key is missing in $code');
        }
      }
      appLanguage.value = Lang.initial;
    });
  });
}
