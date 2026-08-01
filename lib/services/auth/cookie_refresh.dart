import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:pointycastle/export.dart';

import '../sources/bilibili/api/client.dart';

/// B站 Web 端 cookie 刷新（防止 SESSDATA 过期后被迫重新扫码）。
///
/// 流程（参考 biu 的实现思路，Dart 重写）：
/// 1. 用固定 RSA 公钥（OAEP/SHA-256）加密 `refresh_<当前毫秒时间戳>`，
///    hex 后得到 correspondPath；
/// 2. GET `https://www.bilibili.com/correspond/1/<correspondPath>`，
///    从返回 HTML 的 `<div id="1-name">` 中取出 refresh_csrf；
/// 3. POST `passport.bilibili.com/x/passport-login/web/cookie/refresh`
///    （表单：csrf=bili_jct、refresh_csrf、refresh_token、source=main_web），
///    成功后 Set-Cookie 下发新 cookie，响应 data 带新 refresh_token；
/// 4. POST `.../web/confirm/refresh`（csrf、refresh_token=旧值）确认，
///    然后持久化新 refresh_token。
///
/// 通过 [interceptor] 挂到 dio 上前置触发：仅登录态生效；刷新成功后
/// 2 天内不再检查（nextCheckRefreshTime 节流）；30 秒窗口内并发调用
/// 合并为一次执行（单飞）；任何失败都不阻塞原请求。
class CookieRefreshService {
  CookieRefreshService(
    this._client, {
    required Future<String?> Function() readRefreshToken,
    required Future<void> Function(String token) writeRefreshToken,
    DateTime Function()? now,
    Dio? http,
    this._loadNextCheckAt,
    this._persistNextCheckAt,
    // ignore: prefer_initializing_formals 命名参数需对外公开，不能用字段形式
  })  : _readRefreshToken = readRefreshToken,
        // ignore: prefer_initializing_formals 命名参数需对外公开，不能用字段形式
        _writeRefreshToken = writeRefreshToken,
        _now = now ?? DateTime.now,
        _http = http ?? _buildHttp(_client.cookieJar);

  /// 刷新成功后的节流间隔。
  static const checkInterval = Duration(days: 2);

  /// 单飞窗口：上一次尝试（无论成败）后该时长内不再发起。
  static const singleFlightWindow = Duration(seconds: 30);

  /// B站 cookie 刷新用的固定 RSA 公钥（JWK n，base64url）。
  static const _kModulusB64Url =
      'y4HdjgJHBlbaBN04VERG4qNBIFHP6a3GozCl75AihQloSWCXC5HDNgyinEnhaQ_4'
      '-gaMud_GF50elYXLlCToR9se9Z8z433U3KjM-3Yx7ptKkmQNAMggQwAVKgq3zY'
      'AoidNEWuxpkY_mAitTSRLnsJW-NCTa0bqBFF6Wm1MxgfE';

  final BiliClient _client;
  final Future<String?> Function() _readRefreshToken;
  final Future<void> Function(String token) _writeRefreshToken;
  final Future<DateTime?> Function()? _loadNextCheckAt;
  final Future<void> Function(DateTime at)? _persistNextCheckAt;
  final DateTime Function() _now;
  final Dio _http;

  DateTime? _nextCheckAt;
  bool _nextCheckLoaded = false;
  DateTime? _lastAttemptAt;
  Future<bool>? _inFlight;

  static Dio _buildHttp(CookieJar jar) {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ));
    dio.interceptors.add(CookieManager(jar));
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      options.headers['User-Agent'] = kBiliUserAgent;
      options.headers['Referer'] = kBiliReferer;
      handler.next(options);
    }));
    return dio;
  }

  /// 挂到业务 dio 上的拦截器：请求发出前按需刷新 cookie。
  /// 刷新失败仅静默跳过，绝不影响原请求。
  Interceptor interceptor() =>
      InterceptorsWrapper(onRequest: (options, handler) async {
        try {
          await maybeRefresh();
        } catch (_) {
          // 失败不阻塞请求。
        }
        handler.next(options);
      });

  /// 按需执行一次刷新。返回是否真正刷新成功。
  Future<bool> maybeRefresh() async {
    final now = _now();
    await _ensureNextCheckLoaded();
    final next = _nextCheckAt;
    if (next != null && now.isBefore(next)) return false;
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight; // 单飞：并发调用合并
    final last = _lastAttemptAt;
    if (last != null && now.difference(last) < singleFlightWindow) {
      return false;
    }
    _lastAttemptAt = now;

    final future = _refreshSafely();
    _inFlight = future;
    try {
      final ok = await future;
      if (ok) {
        final at = _now().add(checkInterval);
        _nextCheckAt = at;
        await _persistNextCheckAt?.call(at);
      }
      return ok;
    } finally {
      _inFlight = null;
    }
  }

  Future<void> _ensureNextCheckLoaded() async {
    if (_nextCheckLoaded) return;
    _nextCheckLoaded = true;
    try {
      _nextCheckAt = await _loadNextCheckAt?.call();
    } catch (_) {
      _nextCheckAt = null;
    }
  }

  Future<bool> _refreshSafely() async {
    try {
      return await _doRefresh();
    } catch (_) {
      return false;
    }
  }

  Future<bool> _doRefresh() async {
    if (!await _hasSessdata()) return false;
    final refreshToken = await _readRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) return false;
    final csrf = await _biliJct();
    if (csrf == null || csrf.isEmpty) return false;

    // 1) correspond 页面换取 refresh_csrf
    final path = correspondPath(_now());
    final html = await _http.get<String>(
      'https://www.bilibili.com/correspond/1/$path',
      options: Options(responseType: ResponseType.plain),
    );
    final refreshCsrf = parseRefreshCsrf(html.data ?? '');
    if (refreshCsrf == null) return false;

    // 2) 刷新 cookie（响应 Set-Cookie 由 CookieManager 自动入库）
    final form = Options(contentType: Headers.formUrlEncodedContentType);
    final refreshed = await _http.post<Map<String, dynamic>>(
      'https://passport.bilibili.com/x/passport-login/web/cookie/refresh',
      data: {
        'csrf': csrf,
        'refresh_csrf': refreshCsrf,
        'refresh_token': refreshToken,
        'source': 'main_web',
      },
      options: form,
    );
    final body = refreshed.data;
    if (body == null || (body['code'] as num?)?.toInt() != 0) return false;
    final newToken =
        ((body['data'] as Map?)?['refresh_token'] as String?) ?? '';

    // 3) 确认刷新（携带刷新后的新 cookie，refresh_token 传旧值）
    final newCsrf = (await _biliJct()) ?? csrf;
    final confirmed = await _http.post<Map<String, dynamic>>(
      'https://passport.bilibili.com/x/passport-login/web/confirm/refresh',
      data: {'csrf': newCsrf, 'refresh_token': refreshToken},
      options: form,
    );
    if ((confirmed.data?['code'] as num?)?.toInt() != 0) return false;

    if (newToken.isNotEmpty) await _writeRefreshToken(newToken);
    return true;
  }

  Future<bool> _hasSessdata() async {
    final cookies = await _client.cookieJar
        .loadForRequest(Uri.parse('https://www.bilibili.com'));
    return cookies.any((c) => c.name == 'SESSDATA' && c.value.isNotEmpty);
  }

  Future<String?> _biliJct() async {
    final cookies = await _client.cookieJar
        .loadForRequest(Uri.parse('https://www.bilibili.com'));
    for (final c in cookies) {
      if (c.name == 'bili_jct' && c.value.isNotEmpty) return c.value;
    }
    return null;
  }

  /// 用固定 RSA 公钥加密 `refresh_<毫秒时间戳>`，输出小写 hex。
  static String correspondPath(DateTime at) {
    final key = RSAPublicKey(_decodeBase64UrlBigInt(_kModulusB64Url),
        BigInt.from(65537));
    final cipher = OAEPEncoding.withSHA256(RSAEngine())
      ..init(true, PublicKeyParameter<RSAPublicKey>(key));
    final input = utf8.encode('refresh_${at.millisecondsSinceEpoch}');
    final encrypted = cipher.process(Uint8List.fromList(input));
    return encrypted
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// 从 correspond 页面 HTML 中抠出 refresh_csrf（`<div id="1-name">`）。
  static String? parseRefreshCsrf(String html) {
    final match =
        RegExp('<div id="1-name">([^<]+)</div>').firstMatch(html);
    final value = match?.group(1)?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  static BigInt _decodeBase64UrlBigInt(String s) {
    final bytes = base64Url.decode(base64Url.normalize(s));
    var result = BigInt.zero;
    for (final b in bytes) {
      result = (result << 8) | BigInt.from(b);
    }
    return result;
  }
}
