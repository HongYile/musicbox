import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';

/// QQ 音乐域名与 UA。
const String kQqSearchDomain = 'https://c.y.qq.com';
const String kQqMusicuDomain = 'https://u.y.qq.com';
const String kQqUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

/// QQ 音乐 HTTP 客户端：搜索域 + musicu 域两个 dio + CookieJar。
///
/// 关键凭证（登录后由 WebView 抓 cookie 写入 jar）：
/// - `uin`：QQ 号（微信登录为 `wxuin`，使用时剥除非数字字符）
/// - `qqmusic_key`（或 `qm_keyst`，同一把票据两个名字）：取流鉴权 `comm.authst`
class QqClient {
  QqClient._(this.cookieJar)
      : search = _buildDio(kQqSearchDomain),
        musicu = _buildDio(kQqMusicuDomain);

  /// App 内使用：cookie 持久化到 [cookieDir]。
  factory QqClient.persistent(String cookieDir) {
    return QqClient._(PersistCookieJar(storage: FileStorage(cookieDir)));
  }

  /// 脚本/测试使用：内存 cookie，不持久化。
  factory QqClient.memory() => QqClient._(CookieJar());

  final CookieJar cookieJar;
  final Dio search;
  final Dio musicu;

  static Dio _buildDio(String baseUrl) => Dio(BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        responseType: ResponseType.json,
        headers: {
          'User-Agent': kQqUserAgent,
          'Referer': 'https://y.qq.com',
        },
      ));

  // ---------- 凭证读取 ----------

  Future<Map<String, String>> _cookies() async {
    final cookies = await cookieJar
        .loadForRequest(Uri.parse('https://y.qq.com'));
    return {for (final c in cookies) c.name: c.value};
  }

  /// QQ 号（无登录返回 '0'；微信登录取 wxuin 剥非数字）。
  Future<String> uin() async {
    final c = await _cookies();
    final raw = c['uin'] ?? c['wxuin'] ?? '0';
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    return digits.isEmpty ? '0' : digits;
  }

  /// 登录票据（qqmusic_key / qm_keyst 同物两名）。
  Future<String?> musicKey() async {
    final c = await _cookies();
    final key = c['qqmusic_key'] ?? c['qm_keyst'];
    return (key == null || key.isEmpty) ? null : key;
  }

  /// 是否具备取流所需登录凭证。
  Future<bool> hasCredential() async => await musicKey() != null;

  /// 写入整串 cookie（WebView 登录抓取后调用）。
  Future<void> importCookieString(String cookieString) async {
    final uri = Uri.parse('https://y.qq.com');
    final list = <Cookie>[];
    for (final pair in cookieString.split(';')) {
      final idx = pair.indexOf('=');
      if (idx <= 0) continue;
      final name = pair.substring(0, idx).trim();
      final value = pair.substring(idx + 1).trim();
      if (name.isEmpty) continue;
      list.add(Cookie(name, value)..domain = '.qq.com');
    }
    await cookieJar.saveFromResponse(uri, list);
  }

  /// 退出登录。
  Future<void> clearCredential() => cookieJar.deleteAll();
}
