/// 网易云音乐加密通道纯 Dart 移植。
///
/// 蓝本：NeteaseCloudMusicApiEnhanced `util/crypto.js`（MIT）。
/// 实现 weapi（双层 AES-CBC + 无填充 RSA）、eapi（AES-ECB + MD5）、
/// xeapi（AES-ECB 套娃 + X25519 ECIES 信封 + AES-128-GCM）三种加密，
/// 以及 xeapi 握手签名 / 响应解密 / 公钥解密。
///
/// X25519 在 pointycastle 4.0 中缺失，此处按 RFC 7748 用 BigInt
/// 实现 Montgomery ladder（仅供本文件内部使用）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

// ---------------------------------------------------------------------------
// 常量（与蓝本 crypto.js 一致）
// ---------------------------------------------------------------------------

final Uint8List _iv = Uint8List.fromList(utf8.encode('0102030405060708'));
final Uint8List _presetKey = Uint8List.fromList(utf8.encode('0CoJUm6Qyw8W8jud'));
final Uint8List _eapiKey = Uint8List.fromList(utf8.encode('e82ckenh8dichen8'));
final Uint8List _xeapiStaticKey = Uint8List.fromList(<int>[
  0xab, 0x1d, 0x5a, 0x43, 0x0f, 0x6b, 0xb0, 0x4a, //
  0x3f, 0x01, 0xe8, 0x1d, 0xdd, 0x72, 0xbd, 0x91, //
  0x6d, 0x5c, 0xe5, 0x91, 0x24, 0x8a, 0xc1, 0x28, //
  0x71, 0x48, 0x06, 0xd7, 0xf8, 0xfb, 0x1b, 0x84, //
]);

/// xeapi 握手/公钥请求签名 key（按 UTF8 字面量作 HMAC key，与蓝本一致）。
const String xeapiSignKey =
    'mUHCwVNWJbunMqAHf5MImuirT6plvs6VSFW62MGHstFQxhBGdEoIhLItH3djc4+FB/OKty3+lL2rGeoFBpVe5g==';

/// weapi RSA-1024 公钥模数（从蓝本 PEM 提取）。
final BigInt _weapiRsaN = BigInt.parse(
  'e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3'
  'ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda925'
  '57c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe487'
  '5d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7',
  radix: 16,
);
final BigInt _weapiRsaE = BigInt.from(65537);

const String _base62 =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

// ---------------------------------------------------------------------------
// 随机源抽象：默认安全随机，测试可注入固定字节流与 Node 对拍。
// ---------------------------------------------------------------------------

abstract class NcmRandom {
  Uint8List bytes(int n);
}

class SecureNcmRandom implements NcmRandom {
  SecureNcmRandom() : _r = Random.secure();
  final Random _r;

  @override
  Uint8List bytes(int n) =>
      Uint8List.fromList(List.generate(n, (_) => _r.nextInt(256)));
}

/// 测试用固定随机源：按顺序消费字节池。
class FixedNcmRandom implements NcmRandom {
  FixedNcmRandom(List<int> pool) : _pool = List.of(pool);
  final List<int> _pool;

  @override
  Uint8List bytes(int n) {
    if (_pool.length < n) {
      throw StateError('FixedNcmRandom 池耗尽（还需 $n 字节）');
    }
    final out = Uint8List.fromList(_pool.sublist(0, n));
    _pool.removeRange(0, n);
    return out;
  }
}

// ---------------------------------------------------------------------------
// AES 原语（pointycastle，PKCS7）
// ---------------------------------------------------------------------------

Uint8List _aesEcbEncrypt(Uint8List key, List<int> plaintext) {
  final c = PaddedBlockCipherImpl(PKCS7Padding(), ECBBlockCipher(AESEngine()))
    ..init(true, PaddedBlockCipherParameters(KeyParameter(key), null));
  return c.process(Uint8List.fromList(plaintext));
}

Uint8List _aesEcbDecrypt(Uint8List key, List<int> ciphertext) {
  final c = PaddedBlockCipherImpl(PKCS7Padding(), ECBBlockCipher(AESEngine()))
    ..init(false, PaddedBlockCipherParameters(KeyParameter(key), null));
  return c.process(Uint8List.fromList(ciphertext));
}

Uint8List _aesCbcEncrypt(Uint8List key, Uint8List iv, List<int> plaintext) {
  final c = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
    ..init(
      true,
      PaddedBlockCipherParameters(
        ParametersWithIV(KeyParameter(key), iv),
        null,
      ),
    );
  return c.process(Uint8List.fromList(plaintext));
}

Uint8List _aesGcmEncrypt(
  Uint8List key,
  Uint8List iv,
  List<int> plaintext,
) {
  final c = GCMBlockCipher(AESEngine())
    ..init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
  return c.process(Uint8List.fromList(plaintext)); // ct || tag
}

String _hexUpper(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

String _hexLower(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

// ---------------------------------------------------------------------------
// X25519（RFC 7748，纯 BigInt Montgomery ladder）
// ---------------------------------------------------------------------------

final BigInt _p =
    BigInt.parse('7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed', radix: 16);
final BigInt _a24 = BigInt.from(121665);

BigInt _decodeLe(List<int> bytes) {
  var v = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    v = (v << 8) | BigInt.from(bytes[i]);
  }
  return v;
}

Uint8List _encodeLe(BigInt v, int length) {
  final out = Uint8List(length);
  var x = v;
  for (var i = 0; i < length; i++) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x >>= 8;
  }
  return out;
}

BigInt _x25519ScalarMult(BigInt k, BigInt u) {
  var x1 = u;
  var x2 = BigInt.one;
  var z2 = BigInt.zero;
  var x3 = u;
  var z3 = BigInt.one;
  var swap = BigInt.zero;
  for (var t = 254; t >= 0; t--) {
    final kt = (k >> t) & BigInt.one;
    swap ^= kt;
    if (swap != BigInt.zero) {
      final tx = x2;
      x2 = x3;
      x3 = tx;
      final tz = z2;
      z2 = z3;
      z3 = tz;
    }
    swap = kt;
    final a = (x2 + z2) % _p;
    final aa = (a * a) % _p;
    final b = (x2 - z2) % _p;
    final bb = (b * b) % _p;
    final e = (aa - bb) % _p;
    final c = (x3 + z3) % _p;
    final d = (x3 - z3) % _p;
    final da = (d * a) % _p;
    final cb = (c * b) % _p;
    x3 = ((da + cb) * (da + cb)) % _p;
    z3 = (x1 * ((da - cb) * (da - cb) % _p)) % _p;
    x2 = (aa * bb) % _p;
    z2 = (e * (aa + _a24 * e)) % _p;
  }
  if (swap != BigInt.zero) {
    final tx = x2;
    x2 = x3;
    x3 = tx;
    final tz = z2;
    z2 = z3;
    z3 = tz;
  }
  return (x2 * z2.modPow(_p - BigInt.two, _p)) % _p;
}

BigInt _clampScalar(List<int> scalar32) {
  final k = List<int>.of(scalar32);
  k[0] &= 248;
  k[31] &= 127;
  k[31] |= 64;
  return _decodeLe(k);
}

/// X25519 公钥：scalar × basepoint(9)。
Uint8List x25519PublicKey(List<int> privateKey32) {
  final k = _clampScalar(privateKey32);
  return _encodeLe(_x25519ScalarMult(k, BigInt.from(9)), 32);
}

/// X25519 DH：scalar × 对端公钥（u 坐标最高 bit 按规范忽略）。
Uint8List x25519Agreement(List<int> privateKey32, List<int> peerPublic32) {
  final k = _clampScalar(privateKey32);
  final u = List<int>.of(peerPublic32);
  u[31] &= 0x7f;
  return _encodeLe(_x25519ScalarMult(k, _decodeLe(u)), 32);
}

// ---------------------------------------------------------------------------
// HKDF（Extract + 单块 Expand，与蓝本 deriveX25519AesKey 一致）
// ---------------------------------------------------------------------------

Uint8List _hmacSha256(List<int> key, List<int> data) =>
    Uint8List.fromList(Hmac(sha256, key).convert(data).bytes);

Uint8List _deriveX25519AesKey(Uint8List sharedSecret, Uint8List ephemeralRaw) {
  final secret = sharedSecret.isEmpty ? Uint8List(32) : sharedSecret;
  final prk = _hmacSha256(Uint8List(32), secret);
  return _hmacSha256(prk, Uint8List.fromList([...ephemeralRaw, 1]))
      .sublist(0, 16);
}

// ---------------------------------------------------------------------------
// weapi / eapi
// ---------------------------------------------------------------------------

/// 无填充 RSA（等价 node-forge `encrypt(str, 'NONE')`）：明文左补零到 128 字节。
String _rsaNoPadHex(String text) {
  final m = _decodeLe(utf8.encode(text).reversed.toList()); // bytes as BE int
  final c = m.modPow(_weapiRsaE, _weapiRsaN);
  final out = _encodeBe128(c);
  return _hexLower(out);
}

Uint8List _encodeBe128(BigInt v) {
  final out = Uint8List(128);
  var x = v;
  for (var i = 127; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x >>= 8;
  }
  return out;
}

/// weapi：输出 `{params: base64, encSecKey: hex}`。
Map<String, String> ncmWeapi(
  Map<String, dynamic> object, {
  String? secretKey,
  NcmRandom? random,
}) {
  final r = random ?? SecureNcmRandom();
  final key = secretKey ??
      List.generate(16, (_) => _base62[r.bytes(1)[0] % 62]).join();
  final text = jsonEncode(object);
  final first = base64Encode(_aesCbcEncrypt(_presetKey, _iv, utf8.encode(text)));
  final params =
      base64Encode(_aesCbcEncrypt(Uint8List.fromList(utf8.encode(key)), _iv, utf8.encode(first)));
  return {'params': params, 'encSecKey': _rsaNoPadHex(key.split('').reversed.join())};
}

/// eapi：输出 `params`（大写 hex）。
String ncmEapiParams(String url, Map<String, dynamic> object) {
  final text = jsonEncode(object);
  final message = 'nobody${url}use${text}md5forencrypt';
  final digest = md5.convert(utf8.encode(message)).toString();
  final data = '$url-36cd479b6b5-$text-36cd479b6b5-$digest';
  return _hexUpper(_aesEcbEncrypt(_eapiKey, utf8.encode(data)));
}

/// eapi 响应解密（hex 密文 → JSON）。
Map<String, dynamic> ncmEapiResDecrypt(String encryptedHex) {
  final bytes = <int>[];
  for (var i = 0; i < encryptedHex.length; i += 2) {
    bytes.add(int.parse(encryptedHex.substring(i, i + 2), radix: 16));
  }
  final plain = _aesEcbDecrypt(_eapiKey, bytes);
  return (jsonDecode(utf8.decode(plain)) as Map).cast<String, dynamic>();
}

// ---------------------------------------------------------------------------
// xeapi
// ---------------------------------------------------------------------------

/// 服务端公钥状态（握手接口返回）。
class XeapiPublicKeyState {
  const XeapiPublicKeyState({
    required this.publicKey,
    required this.sk,
    required this.version,
  });

  /// base64 编码的 32 字节 X25519 原始公钥。
  final String publicKey;
  final String sk;
  final String version;

  factory XeapiPublicKeyState.fromJson(Map<String, dynamic> json) =>
      XeapiPublicKeyState(
        publicKey: (json['publicKey'] ?? '') as String,
        sk: (json['sk'] ?? '') as String,
        version: '${json['version'] ?? ''}',
      );

  Map<String, dynamic> toJson() =>
      {'publicKey': publicKey, 'sk': sk, 'version': version};
}

/// xeapi 握手/公钥请求签名：HMAC-SHA256(xeapiSignKey, "$timestamp$nonce") → base64。
String ncmXeapiSign(int timestamp, String nonce) => base64Encode(
    _hmacSha256(utf8.encode(xeapiSignKey), utf8.encode('$timestamp$nonce')));

/// JS `URLSearchParams` 的 form-urlencoded 序列化（空格 `+`，保留 `*-._`）。
String _urlSearchParams(Map<String, dynamic> data) {
  String enc(Object v) {
    final s = '$v';
    final buf = StringBuffer();
    for (final b in utf8.encode(s)) {
      final ch = String.fromCharCode(b);
      final ok = (b >= 0x30 && b <= 0x39) || // 0-9
          (b >= 0x41 && b <= 0x5a) || // A-Z
          (b >= 0x61 && b <= 0x7a) || // a-z
          ch == '*' || ch == '-' || ch == '.' || ch == '_';
      if (ok) {
        buf.write(ch);
      } else if (b == 0x20) {
        buf.write('+');
      } else {
        buf.write('%');
        buf.write(b.toRadixString(16).padLeft(2, '0').toUpperCase());
      }
    }
    return buf.toString();
  }

  return data.entries.map((e) => '${enc(e.key)}=${enc(e.value)}').join('&');
}

/// 构造 xeapi 明文 JSON（字段顺序与蓝本 buildXeapiPlaintext 严格一致）。
String ncmBuildXeapiPlaintext(String uri, Map<String, dynamic>? data) {
  final fields = <String, dynamic>{};
  final parsed = Uri.parse(uri);
  final hasQuery = parsed.hasQuery;
  if (hasQuery) fields['queryString'] = parsed.query;
  if (data != null) {
    final bodyData = Map<String, dynamic>.of(data)..remove('e_r');
    fields['body'] = base64Encode(utf8.encode(_urlSearchParams(bodyData)));
  }
  if (hasQuery) {
    fields['queryString'] = '${fields['queryString']}&e_r=true';
  } else {
    fields['queryString'] = 'e_r=true';
  }
  return jsonEncode(fields);
}

Uint8List _xeapiMidTransform(Uint8List ciphertext, NcmRandom random) {
  final rand = random.bytes(16);
  final xored = Uint8List(ciphertext.length);
  for (var i = 0; i < ciphertext.length; i++) {
    xored[i] = ciphertext[i] ^ rand[i & 0x0f];
  }
  final b64 = utf8.encode(base64Encode(xored));
  final rot = b64.isEmpty ? 0 : (rand[0] & 0x0f) % b64.length;
  return Uint8List.fromList([...rand, ...b64.sublist(rot), ...b64.sublist(0, rot)]);
}

Uint8List _xeapiEncryptS(
  Uint8List dynamicKey,
  XeapiPublicKeyState state,
  String os,
  NcmRandom random,
) {
  final peerRaw = base64Decode(state.publicKey);
  final ephPriv = random.bytes(32);
  final ephRaw = x25519PublicKey(ephPriv);
  final shared = x25519Agreement(ephPriv, peerRaw);
  final aesKey = _deriveX25519AesKey(shared, ephRaw);
  final iv = random.bytes(12);
  final ct = _aesGcmEncrypt(
    aesKey,
    iv,
    utf8.encode('${base64Encode(dynamicKey)}|$os|${state.sk}'),
  );
  return Uint8List.fromList([...ephRaw, ...iv, ...ct]);
}

/// xeapi：输出 `{B, S, R}` 三段 base64，POST 体即 `B=..&S=..&R=..`。
///
/// [random] 消费顺序与蓝本一致：dynamicKey(16) → mid 混淆(16) →
/// 临时 X25519 私钥(32) → GCM iv(12)。
Map<String, String> ncmXeapi(
  String uri,
  Map<String, dynamic>? data, {
  required XeapiPublicKeyState publicKeyState,
  String os = 'android',
  NcmRandom? random,
}) {
  final r = random ?? SecureNcmRandom();
  final dynamicKey = r.bytes(16);
  final plaintext = utf8.encode(ncmBuildXeapiPlaintext(uri, data));
  final c1 = _aesEcbEncrypt(_xeapiStaticKey, plaintext);
  final mid = _xeapiMidTransform(c1, r);
  final b = base64Encode(_aesEcbEncrypt(dynamicKey, mid));
  final s = base64Encode(_xeapiEncryptS(dynamicKey, publicKeyState, os, r));
  final rr = base64Encode(
      _aesEcbEncrypt(_xeapiStaticKey, utf8.encode('${publicKeyState.version}|')));
  return {'B': b, 'S': s, 'R': rr};
}

/// xeapi 响应解密：AES-128-ECB(eapiKey) → 可选 gunzip → JSON。
Map<String, dynamic> ncmXeapiResDecrypt(List<int> body) {
  final plain = _aesEcbDecrypt(_eapiKey, body);
  final bytes = (plain.length >= 2 && plain[0] == 0x1f && plain[1] == 0x8b)
      ? Uint8List.fromList(gzip.decode(plain))
      : plain;
  return (jsonDecode(utf8.decode(bytes)) as Map).cast<String, dynamic>();
}

/// xeapi 公钥密文解密：AES-256-ECB(staticKey, base64(encryptedData)) → JSON。
XeapiPublicKeyState ncmXeapiDecryptPublicKey(String encryptedData) {
  final plain = _aesEcbDecrypt(_xeapiStaticKey, base64Decode(encryptedData));
  return XeapiPublicKeyState.fromJson(
      (jsonDecode(utf8.decode(plain)) as Map).cast<String, dynamic>());
}

// ---------------------------------------------------------------------------
// 匿名 token（MUSIC_A）请求用户名构造（register_anonimous 蓝本 15 行）。
// ---------------------------------------------------------------------------

/// 生成 deviceId（52 位大写 hex）。
String ncmGenerateDeviceId(NcmRandom random) =>
    _hexUpper(random.bytes(26));

/// 由 deviceId 构造 `/api/register/anonimous` 的 username。
String ncmAnonymousUsername(String deviceId) {
  const key = '3go8&\$8*3*3h0k(2)2';
  final ids = utf8.encode(deviceId);
  final kb = utf8.encode(key);
  final xored =
      Uint8List.fromList(List.generate(ids.length, (i) => ids[i] ^ kb[i % kb.length]));
  final digest = md5.convert(xored).bytes;
  return base64Encode(utf8.encode('$deviceId ${base64Encode(digest)}'));
}
