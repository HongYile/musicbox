/// 同步载荷的敏感字段加密：AES-256-CBC + 随机 IV，
/// 密钥由坚果云应用密码 SHA-256 派生——只有持有同一坚果云账号的
/// 设备才能解开，云端/仓库里都是密文。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

Uint8List _deriveKey(String password) =>
    Uint8List.fromList(sha256.convert(utf8.encode(password)).bytes);

/// 加密：输出 base64(iv[16] + ciphertext)。
String encryptWithPassword(String plaintext, String password) {
  final iv = Uint8List.fromList(
      List.generate(16, (_) => Random.secure().nextInt(256)));
  final c = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
    ..init(
        true,
        PaddedBlockCipherParameters(
            ParametersWithIV(KeyParameter(_deriveKey(password)), iv), null));
  final cipher = c.process(Uint8List.fromList(utf8.encode(plaintext)));
  return base64.encode(Uint8List.fromList([...iv, ...cipher]));
}

/// 解密 [encryptWithPassword] 的产物；密文损坏/密码不符抛异常。
String decryptWithPassword(String encoded, String password) {
  final raw = base64.decode(encoded);
  if (raw.length < 17) throw ArgumentError('密文太短');
  final iv = Uint8List.fromList(raw.sublist(0, 16));
  final cipher = Uint8List.fromList(raw.sublist(16));
  final c = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
    ..init(
        false,
        PaddedBlockCipherParameters(
            ParametersWithIV(KeyParameter(_deriveKey(password)), iv), null));
  return utf8.decode(c.process(cipher));
}
