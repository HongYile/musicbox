import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

import 'wbi_sign.dart';

/// 桌面 Chrome UA，与 B站 web 端行为对齐。
const String kBiliUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const String kBiliReferer = 'https://www.bilibili.com';

/// 拉取/缓存 WBI img_key/sub_key，并负责签名。
class WbiKeyProvider {
  WbiKeyProvider(this._dio);

  final Dio _dio;
  String? _mixinKey;
  DateTime? _fetchedAt;

  /// 缓存 12 小时刷新。
  static const _ttl = Duration(hours: 12);

  Future<String> mixinKey() async {
    final cached = _mixinKey;
    final at = _fetchedAt;
    if (cached != null &&
        at != null &&
        DateTime.now().difference(at) < _ttl) {
      return cached;
    }
    final resp = await _dio.get<Map<String, dynamic>>(
      'https://api.bilibili.com/x/web-interface/nav',
    );
    final wbiImg = (resp.data?['data']?['wbi_img']) as Map<String, dynamic>?;
    final imgUrl = wbiImg?['img_url'] as String?;
    final subUrl = wbiImg?['sub_url'] as String?;
    if (imgUrl == null || subUrl == null) {
      throw StateError('nav 接口未返回 wbi_img');
    }
    final key = WbiSign.mixinKey(
      WbiSign.keyFromUrl(imgUrl),
      WbiSign.keyFromUrl(subUrl),
    );
    _mixinKey = key;
    _fetchedAt = DateTime.now();
    return key;
  }

  void invalidate() {
    _mixinKey = null;
    _fetchedAt = null;
  }
}

/// B站 HTTP 客户端：api./passport. 两个 dio 实例 + CookieJar + UA/Referer + WBI 签名。
///
/// 纯 Dart（不依赖 Flutter），app 内用 [BiliClient.persistent]，
/// 脚本/测试可用 [BiliClient.memory]。
class BiliClient {
  BiliClient._(this.cookieJar)
      : api = _buildDio('https://api.bilibili.com'),
        passport = _buildDio('https://passport.bilibili.com') {
    wbiKeys = WbiKeyProvider(api);
    for (final dio in [api, passport]) {
      dio.interceptors.add(CookieManager(cookieJar));
      dio.interceptors.add(_headerInterceptor());
    }
    // WBI 签名拦截器放最后，保证在 header 之后、请求发出前执行。
    api.interceptors.add(_wbiInterceptor());
  }

  /// App 内使用：cookie 持久化到 [cookieDir]。
  factory BiliClient.persistent(String cookieDir) =>
      BiliClient._(PersistCookieJar(storage: FileStorage(cookieDir)));

  /// 脚本/测试使用：内存 cookie。
  factory BiliClient.memory() => BiliClient._(CookieJar());

  final CookieJar cookieJar;
  final Dio api;
  final Dio passport;
  late final WbiKeyProvider wbiKeys;

  static Dio _buildDio(String baseUrl) => Dio(BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        responseType: ResponseType.json,
      ));

  Interceptor _headerInterceptor() =>
      InterceptorsWrapper(onRequest: (options, handler) {
        options.headers['User-Agent'] = kBiliUserAgent;
        options.headers['Referer'] = kBiliReferer;
        handler.next(options);
      });

  Interceptor _wbiInterceptor() =>
      InterceptorsWrapper(onRequest: (options, handler) async {
        if (options.extra['useWbi'] == true) {
          try {
            final mixin = await wbiKeys.mixinKey();
            options.queryParameters =
                WbiSign.sign(options.queryParameters, mixin);
          } catch (e) {
            return handler.reject(
              DioException(
                requestOptions: options,
                error: e,
                message: 'WBI 签名失败: $e',
              ),
            );
          }
        }
        handler.next(options);
      });
}

class BiliApiException implements Exception {
  BiliApiException(this.code, this.message);
  final int code;
  final String message;
  @override
  String toString() => 'BiliApiException($code): $message';
}
