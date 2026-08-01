import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 带文件兜底的密钥存储。
///
/// 首选 flutter_secure_storage（macOS Keychain / iOS Keychain / Android KeyStore）。
/// macOS 沙盒下若 Keychain entitlement 未生效（errSecMissingEntitlement -34018），
/// 自动降级为写入应用支持目录下的本地文件（个人自用场景可接受），
/// 保证登录态持久化不中断。
class TokenStore {
  TokenStore({this.fallbackDir, FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  final String? fallbackDir;

  /// 一旦安全存储抛错即视为不可用，后续全部走文件，避免每次重试 Keychain。
  bool _secureBroken = false;

  String _fallbackPath(String key) {
    assert(fallbackDir != null, 'TokenStore: fallbackDir 未配置');
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    return '${fallbackDir!}/secure_store/$safe';
  }

  Future<String?> _readFallback(String key) async {
    if (fallbackDir == null) return null;
    try {
      final f = File(_fallbackPath(key));
      return await f.exists() ? f.readAsString() : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeFallback(String key, String value) async {
    if (fallbackDir == null) return;
    try {
      final f = File(_fallbackPath(key));
      await f.parent.create(recursive: true);
      await f.writeAsString(value, flush: true);
      // 尽力收紧权限（桌面 POSIX 系统有效；失败忽略）。
      if (!Platform.isWindows) {
        await Process.run('chmod', ['600', f.path]);
      }
    } catch (_) {
      // 兜底失败也吞掉：最多表现为重启后需重新登录。
    }
  }

  Future<void> _deleteFallback(String key) async {
    if (fallbackDir == null) return;
    try {
      final f = File(_fallbackPath(key));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<String?> read({required String key}) async {
    if (!_secureBroken) {
      try {
        return await _storage.read(key: key);
      } on PlatformException {
        _secureBroken = true;
      } catch (_) {
        _secureBroken = true;
      }
    }
    return _readFallback(key);
  }

  Future<void> write({required String key, required String value}) async {
    if (!_secureBroken) {
      try {
        await _storage.write(key: key, value: value);
        return;
      } on PlatformException {
        _secureBroken = true;
      } catch (_) {
        _secureBroken = true;
      }
    }
    await _writeFallback(key, value);
  }

  Future<void> delete({required String key}) async {
    if (!_secureBroken) {
      try {
        await _storage.delete(key: key);
      } catch (_) {
        _secureBroken = true;
      }
    }
    await _deleteFallback(key);
  }
}
