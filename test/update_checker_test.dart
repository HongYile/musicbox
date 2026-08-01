import 'package:flutter_test/flutter_test.dart';
import 'package:musicbox/services/update/update_checker.dart';

void main() {
  group('UpdateChecker.isNewer', () {
    test('基本比较', () {
      expect(UpdateChecker.isNewer('v0.1.2', '0.1.1'), isTrue);
      expect(UpdateChecker.isNewer('0.1.1', '0.1.1'), isFalse);
      expect(UpdateChecker.isNewer('v0.1.0', '0.1.1'), isFalse);
    });

    test('大版本与补齐', () {
      expect(UpdateChecker.isNewer('v1.0.0', '0.9.9'), isTrue);
      expect(UpdateChecker.isNewer('v0.2', '0.1.9'), isTrue);
      expect(UpdateChecker.isNewer('v0.10.0', '0.9.9'), isTrue);
    });

    test('带构建号/后缀', () {
      expect(UpdateChecker.isNewer('v0.1.1+2', '0.1.1'), isFalse);
      expect(UpdateChecker.isNewer('v0.1.2-beta', '0.1.1'), isTrue);
    });
  });
}
