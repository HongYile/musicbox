import 'package:unison/services/ai/ai_title_service.dart';
import 'package:unison/services/sync/sync_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sync_crypto', () {
    test('加密→解密往返', () {
      final enc = encryptWithPassword('sk-test-key-123', '坚果云应用密码');
      expect(enc == 'sk-test-key-123', isFalse); // 密文不含明文
      expect(decryptWithPassword(enc, '坚果云应用密码'), 'sk-test-key-123');
    });

    test('密码错误解密失败', () {
      final enc = encryptWithPassword('secret', 'right');
      expect(() => decryptWithPassword(enc, 'wrong'), throwsA(anything));
    });

    test('两次加密密文不同（随机 IV）', () {
      final a = encryptWithPassword('same', 'pwd');
      final b = encryptWithPassword('same', 'pwd');
      expect(a == b, isFalse);
      expect(decryptWithPassword(a, 'pwd'), 'same');
      expect(decryptWithPassword(b, 'pwd'), 'same');
    });
  });

  group('parseAiSongJson', () {
    test('标准 JSON', () {
      final r = parseAiSongJson('{"title":"咏春","artist":"七朵组合"}');
      expect(r!.title, '咏春');
      expect(r.artist, '七朵组合');
      expect(r.keyword, '咏春 七朵组合');
    });

    test('容忍 markdown 包裹与多余文字', () {
      final r = parseAiSongJson(
          '提取结果：```json\n{"title":"夜に駆ける","artist":""}\n```');
      expect(r!.title, '夜に駆ける');
      expect(r.artist, '');
      expect(r.keyword, '夜に駆ける');
    });

    test('垃圾输入返回 null', () {
      expect(parseAiSongJson('无法识别'), isNull);
      expect(parseAiSongJson('{"title":""}'), isNull);
    });
  });
}
