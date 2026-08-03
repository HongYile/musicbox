import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 内嵌官方网页登录结果。
class WebLoginResult {
  const WebLoginResult({required this.success, required this.cookieString});

  final bool success;
  final String cookieString;
}

/// 内嵌官方网页登录页（同设备完成，无需第二部手机扫码）。
///
/// 打开官方登录页（B站 passport / y.qq.com），用户在本机登录后，
/// 轮询 WebView cookie（含 HttpOnly）检测登录成功并抓回整串 Cookie。
class WebLoginPage extends StatefulWidget {
  const WebLoginPage({
    super.key,
    required this.loginUrl,
    required this.cookieDomain,
    required this.successKey,
    required this.title,
  });

  /// 登录页地址（如 https://passport.bilibili.com/login）。
  final String loginUrl;

  /// 检测 cookie 的域（如 https://www.bilibili.com / https://y.qq.com）。
  final String cookieDomain;

  /// 登录成功的判定 cookie 名（SESSDATA / qqmusic_key）。
  final String successKey;

  final String title;

  /// 便捷入口：B站。
  static Future<WebLoginResult?> loginBilibili(BuildContext context) =>
      Navigator.of(context, rootNavigator: true).push<WebLoginResult>(
        MaterialPageRoute(
          builder: (_) => const WebLoginPage(
            loginUrl: 'https://passport.bilibili.com/login',
            cookieDomain: 'https://www.bilibili.com',
            successKey: 'SESSDATA',
            title: '登录哔哩哔哩',
          ),
        ),
      );

  /// 便捷入口：QQ 音乐。
  static Future<WebLoginResult?> loginQqMusic(BuildContext context) =>
      Navigator.of(context, rootNavigator: true).push<WebLoginResult>(
        MaterialPageRoute(
          builder: (_) => const WebLoginPage(
            loginUrl: 'https://y.qq.com',
            cookieDomain: 'https://y.qq.com',
            successKey: 'qqmusic_key',
            title: '登录 QQ 音乐',
          ),
        ),
      );

  @override
  State<WebLoginPage> createState() => _WebLoginPageState();
}

class _WebLoginPageState extends State<WebLoginPage> {
  Timer? _timer;
  bool _done = false;
  String _hint = '请在页面中完成登录，成功后自动返回';

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    if (_done) return;
    try {
      final cookies = await CookieManager.instance()
          .getCookies(url: WebUri(widget.cookieDomain));
      final map = {for (final c in cookies) c.name: c.value};
      final key = map[widget.successKey];
      final altKey =
          widget.successKey == 'qqmusic_key' ? map['qm_keyst'] : null;
      if ((key != null && key.isNotEmpty) ||
          (altKey != null && altKey.isNotEmpty)) {
        _done = true;
        _timer?.cancel();
        final cookieString =
            map.entries.map((e) => '${e.key}=${e.value}').join('; ');
        if (mounted) {
          setState(() => _hint = '登录成功，正在返回…');
          await Future<void>.delayed(const Duration(milliseconds: 600));
          if (mounted) {
            Navigator.of(context)
                .pop(WebLoginResult(success: true, cookieString: cookieString));
          }
        }
      }
    } catch (_) {
      // WebView 未就绪，下一轮再试
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(22),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(_hint,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        ),
      ),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(widget.loginUrl)),
      ),
    );
  }
}
