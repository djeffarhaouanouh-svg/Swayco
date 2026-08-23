import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_translate/widgets/glass_nav_bar.dart';

void main() {
  group('navBarUnreadLabel', () {
    test('a single arrival is a dot — no label', () {
      expect(navBarUnreadLabel(0), isNull);
      expect(navBarUnreadLabel(1), isNull);
    });

    test('several arrivals show +N', () {
      expect(navBarUnreadLabel(2), '+2');
      expect(navBarUnreadLabel(12), '+12');
      expect(navBarUnreadLabel(99), '+99');
    });

    test('caps at +99', () {
      expect(navBarUnreadLabel(100), '+99');
      expect(navBarUnreadLabel(999), '+99');
    });
  });
}
