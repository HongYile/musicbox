import 'dart:async';

import 'package:desktop_webview_window/desktop_webview_window.dart';

import '../sources/qqmusic/api/qq_client.dart';

/// QQ 音乐内嵌网页登录。
///
/// 打开 y.qq.com 让用户自行登录（QQ/微信扫码），轮询 WebView cookie
/// 检测登录成功（出现 qqmusic_key/qm_keyst + uin/wxuin），抓回客户端。
class QqAuthService {
  QqAuthService(this._client);

  final QqClient _client;

  bool _logging = false;

  /// 已登录（jar 中有有效票据）。
  Future<bool> isLoggedIn() => _client.hasCredential();

  /// 当前 QQ 号（未登录 '0'）。
  Future<String> uin() => _client.uin();

  /// 内嵌网页登录。返回 true=抓到凭证；false=用户取消/超时。
  Future<bool> loginViaWebView() async {
    if (_logging) return false;
    _logging = true;
    try {
      final webview = await WebviewWindow.create(
        configuration: const CreateConfiguration(
          title: '登录 QQ 音乐',
          windowWidth: 1000,
          windowHeight: 720,
        ),
      );
      var closed = false;
      webview.onClose.then((_) => closed = true);
      webview.launch('https://y.qq.com');

      final deadline = DateTime.now().add(const Duration(minutes: 5));
      while (DateTime.now().isBefore(deadline)) {
        if (closed) return false; // 用户直接关了登录窗
        await Future<void>.delayed(const Duration(seconds: 2));
        Map<String, String> cookies;
        try {
          final raw = await webview.getAllCookies();
          cookies = {
            for (final c in raw)
              if (c.domain.contains('qq.com')) c.name: c.value,
          };
        } catch (_) {
          return false; // WebView 被关闭
        }
        final key = cookies['qqmusic_key'] ?? cookies['qm_keyst'];
        final uin = cookies['uin'] ?? cookies['wxuin'];
        if (key != null &&
            key.isNotEmpty &&
            uin != null &&
            uin.replaceAll(RegExp(r'\D'), '').isNotEmpty) {
          final cookieString =
              cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
          await _client.importCookieString(cookieString);
          await _closeQuietly(webview);
          return true;
        }
      }
      await _closeQuietly(webview);
      return false; // 超时
    } finally {
      _logging = false;
    }
  }

  Future<void> _closeQuietly(Webview webview) async {
    try {
      webview.close();
    } catch (_) {}
  }

  /// 退出登录。
  Future<void> logout() => _client.clearCredential();
}
