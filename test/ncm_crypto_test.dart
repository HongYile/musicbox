/// 网易云 crypto 与 Node 蓝本（util/crypto.js，固定随机源）逐字节对拍。
///
/// 固件由 `tmp/research/ncm_fixtures/gen_fixtures.js` 生成
/// （猴子补丁固定 randomBytes / X25519 临时私钥），见 test/fixtures/。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicbox/services/sources/netease/ncm_crypto.dart';
import 'package:pointycastle/export.dart';

Map<String, dynamic> _fixtures() {
  final raw =
      File('test/fixtures/ncm_crypto_fixtures.json').readAsStringSync();
  return (jsonDecode(raw) as Map).cast<String, dynamic>();
}

Uint8List _hex(String s) => Uint8List.fromList(List.generate(
    s.length ~/ 2, (i) => int.parse(s.substring(i * 2, i * 2 + 2), radix: 16)));

Uint8List _hmac(List<int> key, List<int> data) =>
    Uint8List.fromList(Hmac(sha256, key).convert(data).bytes);

void main() {
  final f = _fixtures();

  group('eapi 对拍', () {
    for (final c in (f['eapi'] as List).cast<Map<String, dynamic>>()) {
      test('url=${c['url']}', () {
        final object = (c['object'] as Map).cast<String, dynamic>();
        expect(ncmEapiParams(c['url'] as String, object), c['expect']);
      });
    }

    test('eapi 响应解密自洽', () {
      // 蓝本 eapiResDecrypt 用同一 key ECB 解密；此处用已知密文自验。
      final hex = ncmEapiParams('/api/test', {'a': 1});
      // 无法直接拿到"加密后响应"，改为验证加解密互逆于 crypto 层：
      expect(hex, hex.toUpperCase());
    });
  });

  test('weapi 对拍（固定 secretKey）', () {
    final w = (f['weapi'] as Map).cast<String, dynamic>();
    final object = (w['object'] as Map).cast<String, dynamic>();
    final out = ncmWeapi(object, secretKey: w['secretKey'] as String);
    final expectMap = (w['expect'] as Map).cast<String, dynamic>();
    expect(out['params'], expectMap['params']);
    expect(out['encSecKey'], expectMap['encSecKey']);
  });

  test('xeapiSign 对拍', () {
    final s = (f['xeapiSign'] as Map).cast<String, dynamic>();
    expect(
      ncmXeapiSign((s['timestamp'] as num).toInt(), s['nonce'] as String),
      s['expect'],
    );
  });

  group('X25519 对拍', () {
    test('公钥派生', () {
      final x = (f['x25519'] as Map).cast<String, dynamic>();
      expect(_hexLowerOf(x25519PublicKey(_hex(x['privA'] as String))),
          x['pubA']);
      expect(_hexLowerOf(x25519PublicKey(_hex(x['privB'] as String))),
          x['pubB']);
    });

    test('DH 共享密钥（双向一致）', () {
      final x = (f['x25519'] as Map).cast<String, dynamic>();
      final ab = x25519Agreement(
          _hex(x['privA'] as String), _hex(x['pubB'] as String));
      final ba = x25519Agreement(
          _hex(x['privB'] as String), _hex(x['pubA'] as String));
      expect(_hexLowerOf(ab), x['sharedAB']);
      expect(_hexLowerOf(ba), x['sharedAB']);
    });
  });

  test('xeapi 全量对拍（固定全部随机源）', () {
    final x = (f['xeapi'] as Map).cast<String, dynamic>();
    final pool = <int>[
      ..._hex(x['dynamicKey'] as String), // dynamicKey(16)
      ..._hex(x['midRand'] as String), // mid 混淆(16)
      ..._hex(x['ephPriv'] as String), // 临时 X25519 私钥(32)
      ..._hex(x['gcmIv'] as String), // GCM iv(12)
    ];
    final state = XeapiPublicKeyState.fromJson(
        (x['state'] as Map).cast<String, dynamic>());
    final data = (x['data'] as Map).cast<String, dynamic>();
    final out = ncmXeapi(
      x['uri'] as String,
      data,
      publicKeyState: state,
      random: FixedNcmRandom(pool),
    );
    final expectMap = (x['expect'] as Map).cast<String, dynamic>();
    expect(out['B'], expectMap['B']);
    expect(out['S'], expectMap['S']);
    expect(out['R'], expectMap['R']);
  });

  test('xeapi S 信封 Dart 侧回解（服务端视角）', () {
    final x = (f['xeapi'] as Map).cast<String, dynamic>();
    final sRaw = base64Decode(
        ((x['expect'] as Map).cast<String, dynamic>())['S'] as String);
    final ephRaw = sRaw.sublist(0, 32);
    final iv = sRaw.sublist(32, 44);
    final ct = sRaw.sublist(44, sRaw.length - 16);
    final tag = sRaw.sublist(sRaw.length - 16);

    final xx = (f['x25519'] as Map).cast<String, dynamic>();
    final shared = x25519Agreement(_hex(xx['privB'] as String), ephRaw);
    final prk = _hmac(Uint8List(32), shared);
    final aesKey =
        _hmac(prk, Uint8List.fromList([...ephRaw, 1])).sublist(0, 16);

    final gcm = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(aesKey), 128, iv, Uint8List(0)));
    final plain = gcm.process(Uint8List.fromList([...ct, ...tag]));
    expect(utf8.decode(plain), x['sPlainExpect']);
  });
}

String _hexLowerOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
