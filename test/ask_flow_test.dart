import 'package:flutter_test/flutter_test.dart';
import 'package:motari/i18n.dart';

/// The order the sheet asks in, checked as rules rather than as pixels.
///
/// The flow is: the two tabs and both places are on screen from the start; the
/// money appears once there is somewhere to go; everything folds once the money
/// is agreed; the passenger's details come next; and the find button only when
/// those are valid. These are the conditions that drive it.
void main() {
  bool placesDone(bool from, bool to) => from && to;
  bool fareDone(int? named, int min) => named != null && named >= min;
  bool whoDone(String name, String phone) =>
      name.trim().length >= 2 && RegExp(r'^07\d{8}$').hasMatch(phone.trim());

  group('what the sheet shows, and when', () {
    test('the money waits for both places', () {
      expect(placesDone(false, false), isFalse);
      expect(placesDone(true, false), isFalse, reason: 'a pickup alone prices nothing');
      expect(placesDone(false, true), isFalse);
      expect(placesDone(true, true), isTrue);
    });

    test('the floor is enforced, not merely suggested', () {
      expect(fareDone(null, 500), isFalse);
      expect(fareDone(300, 500), isFalse, reason: 'below the floor is not an answer');
      expect(fareDone(500, 500), isTrue);
      expect(fareDone(2000, 500), isTrue);
    });

    test('the find button waits for a real name and a real number', () {
      expect(whoDone('', ''), isFalse);
      expect(whoDone('A', '0788123456'), isFalse, reason: 'one letter is not a name');
      expect(whoDone('Ada', '078812345'), isFalse, reason: 'nine digits is not a phone');
      expect(whoDone('Ada', '0888123456'), isFalse, reason: 'must start 07');
      expect(whoDone('Ada', '0788123456'), isTrue);
    });
  });

  group('the words it uses', () {
    tearDown(() => appLanguage.value = Lang.initial);

    test('the second tab says delivery, not parcel, in every language', () {
      const expected = {
        'en': 'Delivery', 'fr': 'Livraison', 'kinyy': 'Kohereza', 'sw': 'Kutuma',
      };
      for (final entry in expected.entries) {
        appLanguage.value = entry.key;
        expect(t('ask.courier'), entry.value);
      }
    });

    test('every string the redesigned sheet needs exists in all four', () {
      const needed = [
        'ask.ride', 'ask.courier', 'ask.from', 'ask.to_label', 'ask.to_label_parcel',
        'ask.approx_amount', 'ask.approx_hint', 'ask.fare_label', 'ask.you_label',
        'ask.done', 'ask.find', 'ask.find_delivery', 'ask.use_my_location',
        'ask.tap_map_hint', 'ask.at_least', 'ask.too_little',
      ];
      for (final code in Lang.codes) {
        appLanguage.value = code;
        for (final key in needed) {
          expect(t(key), isNot(key), reason: '$code is missing $key');
        }
      }
    });
  });
}
