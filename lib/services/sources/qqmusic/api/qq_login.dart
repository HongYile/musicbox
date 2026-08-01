import 'dart:convert';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

/// QQ 扫码登录（ptlogin2 链）。
///
/// 链路与 B站扫码同构，但腾讯侧分两段：
/// 1. ptqrshow 取二维码（PNG 字节 + qrsig cookie）；
/// 2. ptqrlogin 轮询（ptqrtoken = hash33(qrsig)），成功给 ticket URL；
/// 3. 访问 ticket URL 得 qq.com 域 cookie（uin / skey / p_skey）；
/// 4. 用 p_skey 换 QQ 音乐票据 qqmusic_key（g_tk = hash33(p_skey)）。
///
/// 状态码（ptuiCB 首字段）：'0' 成功 / '65' 失效 / '66' 未扫码 / '67' 已扫未确认。
enum QqQrStep { waiting, scanned, exchanging, success, expired, error }

class QqQrSession {
  const QqQrSession({required this.qrPng, required this.qrsig});

  /// 二维码 PNG 图片字节（ptqrshow 直接返回图片）。
  final Uint8List qrPng;

  /// 轮询凭证（cookie 形式）。
  final String qrsig;
}

class QqQrResult {
  const QqQrResult(this.step, {this.message = '', this.uin = ''});

  final QqQrStep step;
  final String message;
  final String uin;
}

/// 腾讯 pt 系列 hash（ptqrtoken 与 g_tk 同一算法）。
int qqHash33(String s) {
  var h = 0;
  for (final unit in s.codeUnits) {
    h += (h << 5) + unit;
    h &= 0x7fffffff;
  }
  return h;
}

class QqQrLogin {
  QqQrLogin(this.cookieJar, {Dio? dio}) : _dio = dio ?? _buildDio(cookieJar);

  final CookieJar cookieJar;
  final Dio _dio;

  static const _ptHost = 'https://ssl.ptlogin2.qq.com';

  static Dio _buildDio(CookieJar jar) {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      validateStatus: (_) => true,
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
        'Referer': 'https://xui.ptlogin2.qq.com/',
        'sec-ch-ua': '"Chromium";v="126", "Not=A?Brand";v="8"',
        'sec-ch-ua-mobile': '?0',
        'sec-ch-ua-platform': '"macOS"',
        'Sec-Fetch-Dest': 'empty',
        'Sec-Fetch-Mode': 'cors',
        'Sec-Fetch-Site': 'same-site',
      },
    ));
    dio.interceptors.add(CookieManager(jar));
    return dio;
  }

  Future<void> _captureCookies(String url, Response resp) async {
    final raw = resp.headers['set-cookie'] ?? const [];
    final cookies = <Cookie>[];
    for (final line in raw) {
      final first = line.split(';').first;
      final idx = first.indexOf('=');
      if (idx <= 0) continue;
      cookies.add(Cookie(
          first.substring(0, idx).trim(), first.substring(idx + 1).trim())
        ..domain = '.qq.com');
    }
    if (cookies.isNotEmpty) {
      await cookieJar.saveFromResponse(Uri.parse('https://y.qq.com'), cookies);
    }
  }

  Future<Map<String, String>> _jarCookies() async {
    final cookies =
        await cookieJar.loadForRequest(Uri.parse('https://y.qq.com'));
    return {for (final c in cookies) c.name: c.value};
  }

  /// 申请二维码。
  Future<QqQrSession> generate() async {
    final resp = await _dio.get<List<int>>(
      '$_ptHost/ptqrshow',
      queryParameters: {
        'appid': '716027609',
        'e': '2',
        'l': 'M',
        's': '3',
        'd': '72',
        'v': '4',
        't': DateTime.now().millisecondsSinceEpoch / 1000,
        'daid': '383',
        'pt_3rd_aid': '0',
      },
      options: Options(responseType: ResponseType.bytes),
    );
    await _captureCookies('$_ptHost/ptqrshow', resp);
    final jar = await _jarCookies();
    final qrsig = jar['qrsig'];
    if (qrsig == null || qrsig.isEmpty) {
      throw StateError('ptqrshow 未返回 qrsig');
    }
    return QqQrSession(
        qrPng: Uint8List.fromList(resp.data ?? const []), qrsig: qrsig);
  }

  /// 轮询扫码状态，直到成功/失效/出错。
  Stream<QqQrResult> poll(QqQrSession session) async* {
    final token = qqHash33(session.qrsig);
    while (true) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final resp = await _dio.get<String>(
        '$_ptHost/ptqrlogin',
        queryParameters: {
          'u1': 'https://graph.qq.com/oauth2.0/login_jump',
          'ptqrtoken': token,
          'ptredirect': '0',
          'h': '1',
          't': '1',
          'g': '1',
          'from_ui': '1',
          'ptlang': '2052',
          'action': '0-0-${DateTime.now().millisecondsSinceEpoch}',
          'js_ver': '23081515',
          'js_type': '1',
          'login_sig': '',
          'pt_uistyle': '40',
          'aid': '716027609',
          'daid': '383',
        },
      );
      final body = resp.data ?? '';
      final fields = RegExp(r"'([^']*)'").allMatches(body)
          .map((m) => m.group(1)!)
          .toList();
      if (fields.length < 3) {
        yield QqQrResult(QqQrStep.error, message: 'ptqrlogin 返回异常: $body');
        return;
      }
      switch (fields[0]) {
        case '65':
          yield QqQrResult(QqQrStep.expired, message: fields[4]);
          return;
        case '66':
          yield QqQrResult(QqQrStep.waiting, message: fields[4]);
        case '67':
          yield QqQrResult(QqQrStep.scanned, message: fields[4]);
        case '0':
          // 扫码成功：访问 ticket URL 换 qq.com 域 cookie，再换音乐票据
          yield QqQrResult(QqQrStep.exchanging, message: '扫码成功，正在换取登录态…');
          final result = await _exchange(fields[2]);
          yield result;
          return;
      }
    }
  }

  Future<QqQrResult> _exchange(String ticketUrl) async {
    // 1) ticket URL → qq.com 域 cookie（uin/skey/p_skey）
    final resp = await _dio.get<void>(ticketUrl,
        options: Options(followRedirects: false));
    await _captureCookies(ticketUrl, resp);
    var jar = await _jarCookies();
    final pSkey = jar['p_skey'];
    final uin = jar['uin'] ?? '';
    if (pSkey == null || pSkey.isEmpty) {
      return QqQrResult(QqQrStep.error,
          message: 'ticket 未换到 p_skey（Set-Cookie 缺失）');
    }

    // 2) p_skey → QQ 音乐票据（g_tk 同 hash33；音乐域 Set-Cookie 下发）
    final gtk = qqHash33(pSkey);
    try {
      await _dio.post<String>(
        'https://u.y.qq.com/cgi-bin/musicu.fcg',
        data: jsonEncode({
          'comm': {'g_tk': gtk, 'format': 'json', 'ct': 24, 'cv': 0},
          'req_0': {
            'module': 'music.login.LoginServer',
            'method': 'Login',
            'param': {'str_musicid': uin.replaceAll(RegExp(r'\D'), '')},
          },
        }),
        options: Options(
          headers: {
            'Cookie': 'uin=$uin; skey=${jar['skey']}; p_skey=$pSkey',
            'Referer': 'https://y.qq.com',
          },
          contentType: 'application/json',
        ),
      );
    } catch (_) {
      // 即便请求失败，下面再统一检查票据是否到位
    }

    // 3) 兜底：访问 y.qq.com 首页让服务端按 p_skey 下发音乐会话
    try {
      final home = await _dio.get<void>('https://y.qq.com/',
          options: Options(followRedirects: false));
      await _captureCookies('https://y.qq.com/', home);
    } catch (_) {}

    jar = await _jarCookies();
    final key = jar['qqmusic_key'] ?? jar['qm_keyst'];
    if (key != null && key.isNotEmpty) {
      return QqQrResult(QqQrStep.success,
          message: '登录成功', uin: uin.replaceAll(RegExp(r'\D'), ''));
    }
    return QqQrResult(QqQrStep.error,
        message: '已拿到 p_skey 但未换到 qqmusic_key（需人工排查换票链路）');
  }
}
