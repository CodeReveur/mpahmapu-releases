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
          'ask.request', 'ask.q_from', 'ask.q_fare', 'track.searching',
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
      expect(t('app.name'), 'Motari');
    });
  });
}
