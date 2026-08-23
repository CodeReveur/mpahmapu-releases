import 'package:flutter_test/flutter_test.dart';
import 'package:motari/i18n.dart';

void main() {
  tearDown(() => appLanguage.value = Lang.initial);

  test('every language names all twelve months', () {
    for (final code in Lang.codes) {
      appLanguage.value = code;
      final seen = <String>{};
      for (var m = 1; m <= 12; m++) {
        final name = monthShort(m);
        expect(name, isNotEmpty, reason: '$code has no name for month $m');
        seen.add(name);
      }
      expect(seen.length, 12, reason: '$code repeats a month name');
    }
  });

  test('a month out of range does not crash the trips list', () {
    appLanguage.value = 'en';
    expect(monthShort(0), 'Jan');
    expect(monthShort(13), 'Dec');
  });
}
