import 'package:flutter_test/flutter_test.dart';
import 'package:unison/services/sources/bilibili/api/wbi_sign.dart';

void main() {
  group('WbiSign', () {
    // 样例来自 tmp/verify_bili_wbi.py（算法正确性基准）
    const imgKey = '7cd084941338484aae1ad9425b84077c';
    const subKey = '4932caff0ff746eab6f01bf08b70ac45';

    test('mixinKey 重排正确', () {
      expect(
        WbiSign.mixinKey(imgKey, subKey),
        'ea1db124af3c7062474693fa704f4ff8',
      );
    });

    test('sign 生成正确 w_rid', () {
      final signed = WbiSign.sign(
        {'bar': 514, 'foo': 114, 'zab': 1919810},
        WbiSign.mixinKey(imgKey, subKey),
        wts: 1702204169,
      );
      expect(signed['w_rid'], '8f6f2b5b3d485fe1886cec6a0be8c5d4');
      expect(signed['wts'], 1702204169);
    });

    test("过滤 value 中的 !'()* 字符", () {
      final signed = WbiSign.sign(
        {'foo': "a!b'c(d)e*f"},
        WbiSign.mixinKey(imgKey, subKey),
        wts: 1702204169,
      );
      // 与不过滤时签名不同即证明过滤生效
      final unfiltered = WbiSign.sign(
        {'foo': 'abcdef'},
        WbiSign.mixinKey(imgKey, subKey),
        wts: 1702204169,
      );
      expect(signed['w_rid'], unfiltered['w_rid']);
    });

    test('空格编码为 %20 而非 +', () {
      // 直接验证编码器
      expect(WbiSign.encodeComponent('a b'), 'a%20b');
      expect(WbiSign.encodeComponent('周杰伦'), '%E5%91%A8%E6%9D%B0%E4%BC%A6');
    });

    test('keyFromUrl 提取文件名', () {
      expect(
        WbiSign.keyFromUrl('https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png'),
        '7cd084941338484aae1ad9425b84077c',
      );
    });
  });
}
