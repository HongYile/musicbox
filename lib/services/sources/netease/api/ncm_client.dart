import 'dart:convert';
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';

import '../ncm_crypto.dart';

/// 网易云各通道域名（与蓝本 util/config.json 一致）。
const String kNcmWebDomain = 'https://music.163.com';
const String kNcmApiDomain = 'https://interface.music.163.com';
const String kNcmEapiDomain = 'https://interfacepc.music.163.com';
const String kNcmXeapiDomain = 'https://interface3.music.163.com';

/// PC 客户端 UA（eapi 通道）。
const String kNcmEapiUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/3.1.29.205117';

/// Android 客户端 UA（api/xeapi 通道）。
const String kNcmAndroidUserAgent =
    'NeteaseMusic/9.1.65.240927161425(9001065);Dalvik/2.1.0 (Linux; U; Android 14; 23013RK75C Build/UKQ1.230804.001)';

/// 网易云 HTTP 客户端：eapi/xeapi/api 三个 dio + CookieJar + 设备指纹。
///
/// 纯 Dart（不依赖 Flutter）。cookie 只作 MUSIC_U/MUSIC_A 的持久化存储，
/// 请求 Cookie 头按蓝本 request.js 手工构造（dio_cookie_manager 会覆盖
/// 手工 Cookie 头，故不使用）。
class NcmClient {
  NcmClient._(this.cookieJar, {String? deviceId})
      : deviceId = deviceId ?? ncmGenerateDeviceId(SecureNcmRandom()),
        eapi = _buildDio(kNcmEapiDomain, kNcmEapiUserAgent),
        xeapi = _buildDio(kNcmXeapiDomain, kNcmAndroidUserAgent),
        api = _buildDio(kNcmApiDomain, kNcmAndroidUserAgent);

  /// App 内使用：cookie/deviceId/xeapi 公钥持久化到 [cookieDir]。
  factory NcmClient.persistent(String cookieDir) {
    Directory(cookieDir).createSync(recursive: true);
    final idFile = File('$cookieDir/ncm_deviceid');
    String? deviceId;
    if (idFile.existsSync()) {
      deviceId = idFile.readAsStringSync().trim();
      if (deviceId.isEmpty) deviceId = null;
    }
    final client = NcmClient._(
      PersistCookieJar(storage: FileStorage(cookieDir)),
      deviceId: deviceId,
    );
    if (deviceId == null) idFile.writeAsStringSync(client.deviceId);
    client._keyFile = File('$cookieDir/ncm_xeapi_key.json');
    return client;
  }

  /// 脚本/测试使用：内存 cookie，不持久化。
  factory NcmClient.memory() => NcmClient._(CookieJar());

  final CookieJar cookieJar;
  final Dio eapi;
  final Dio xeapi;
  final Dio api;

  /// 设备指纹（52 位大写 hex），eapi/xeapi 头与匿名 token 共用。
  final String deviceId;

  XeapiPublicKeyState? _xeapiKeyState;
  File? _keyFile;

  static Dio _buildDio(String baseUrl, String ua) => Dio(BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        responseType: ResponseType.json,
        headers: {'User-Agent': ua},
      ));

  // ---------- cookie 读取 ----------

  Future<Map<String, String>> _jarCookies(Uri uri) async {
    final cookies = await cookieJar.loadForRequest(uri);
    return {for (final c in cookies) c.name: c.value};
  }

  Future<String?> cookieValue(String host, String name) async =>
      (await _jarCookies(Uri.parse(host)))[name];

  Future<bool> hasMusicU() async {
    final v = await cookieValue(kNcmWebDomain, 'MUSIC_U');
    return v != null && v.isNotEmpty;
  }

  /// 保存登录响应的 Set-Cookie（剥掉 Domain 属性，与蓝本一致）。
  Future<void> saveSetCookies(Uri uri, List<String>? setCookie) async {
    if (setCookie == null) return;
    final cookies = <Cookie>[];
    for (final line in setCookie) {
      final pair = line.split(';').first.trim();
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      cookies.add(Cookie(pair.substring(0, eq), pair.substring(eq + 1)));
    }
    await cookieJar.saveFromResponse(uri, cookies);
  }

  // ---------- eapi ----------

  String _requestId() =>
      '${DateTime.now().millisecondsSinceEpoch}_${(DateTime.now().microsecond % 9000 + 1000)}';

  /// eapi 通道的身份头对象（蓝本 request.js 的 header，pc 身份）。
  Future<Map<String, dynamic>> _eapiHeader() async {
    final jar = await _jarCookies(Uri.parse(kNcmWebDomain));
    final header = <String, dynamic>{
      'osver': 'Microsoft-Windows-10-Professional-build-19045-64bit',
      'deviceId': deviceId,
      'os': 'pc',
      'appver': '3.1.17.204416',
      'versioncode': '140',
      'mobilename': '',
      'buildver': (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
      'resolution': '1920x1080',
      '__csrf': jar['__csrf'] ?? '',
      'channel': 'netease',
      'requestId': _requestId(),
    };
    if ((jar['MUSIC_U'] ?? '').isNotEmpty) header['MUSIC_U'] = jar['MUSIC_U'];
    if ((jar['MUSIC_A'] ?? '').isNotEmpty) header['MUSIC_A'] = jar['MUSIC_A'];
    return header;
  }

  String _cookieString(Map<String, dynamic> values) => values.entries
      .where((e) => e.value != null && '${e.value}'.isNotEmpty)
      .map((e) => '${e.key}=${e.value}')
      .join('; ');

  /// eapi POST：返回明文 JSON。
  Future<Map<String, dynamic>> eapiPost(
    String uri,
    Map<String, dynamic> data,
  ) async {
    final header = await _eapiHeader();
    final payload = <String, dynamic>{...data, 'header': header};
    final params = ncmEapiParams(uri, payload);
    final resp = await eapi.post<dynamic>(
      '/eapi/${uri.substring(5)}', // '/api/xxx' → '/eapi/xxx'
      data: {'params': params},
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: {'Cookie': _cookieString(header)},
      ),
    );
    await saveSetCookies(
        Uri.parse(kNcmEapiDomain), resp.headers['set-cookie']);
    final body = resp.data;
    if (body is Map<String, dynamic>) return body;
    if (body is String) {
      return (jsonDecode(body) as Map).cast<String, dynamic>();
    }
    throw StateError('eapi $uri 返回格式异常');
  }

  // ---------- xeapi ----------

  /// 握手取服务端公钥状态（app 启动后首次使用时调用，结果持久化）。
  Future<XeapiPublicKeyState> ensureXeapiKey() async {
    final cached = _xeapiKeyState ?? _readKeyFile();
    if (cached != null) return cached;

    final r = SecureNcmRandom();
    final nonce =
        List.generate(16, (_) => (r.bytes(1)[0] % 10).toString()).join();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final resp = await api.post<dynamic>(
      '/api/gorilla/anti/crawler/security/key/get',
      data: {
        'appVersion': '9.1.65',
        'currentKeyVersion': '',
        'deviceId': deviceId,
        'nonce': nonce,
        'os': 'android',
        'requestType': 'active',
        'signature': ncmXeapiSign(timestamp, nonce),
        't1': '',
        't2': '',
        'timestamp': '$timestamp',
        'uid': '',
      },
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: {'Cookie': 'deviceId=${Uri.encodeComponent(deviceId)}'},
      ),
    );
    final body = resp.data is String
        ? (jsonDecode(resp.data as String) as Map).cast<String, dynamic>()
        : (resp.data as Map).cast<String, dynamic>();
    final data = (body['data'] as Map?)?.cast<String, dynamic>();
    if ((body['code'] as num?)?.toInt() != 200 ||
        data == null ||
        data['encryptedData'] == null) {
      throw StateError('xeapi 公钥请求失败: ${body['code']}');
    }
    // 校验响应签名（同一 HMAC，防中间人替换公钥）。
    final sig = data['signature'] as String?;
    final respTs = (data['timestamp'] as num?)?.toInt() ?? 0;
    if (sig == null || ncmXeapiSign(respTs, nonce) != sig) {
      throw StateError('xeapi 公钥响应签名校验失败');
    }
    final state = ncmXeapiDecryptPublicKey(data['encryptedData'] as String);
    if (state.sk.isEmpty) throw StateError('xeapi 公钥响应缺少 sk');
    _xeapiKeyState = state;
    _keyFile?.writeAsStringSync(jsonEncode(state.toJson()));
    return state;
  }

  XeapiPublicKeyState? _readKeyFile() {
    final f = _keyFile;
    if (f == null || !f.existsSync()) return null;
    try {
      final state = XeapiPublicKeyState.fromJson(
          (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>());
      _xeapiKeyState = state;
      return state;
    } catch (_) {
      return null;
    }
  }

  /// xeapi POST：{B,S,R} 表单，响应 AES-ECB(eapiKey) 解密。
  Future<Map<String, dynamic>> xeapiPost(
    String uri,
    Map<String, dynamic> data,
  ) async {
    final state = await ensureXeapiKey();
    final jar = await _jarCookies(Uri.parse(kNcmWebDomain));
    final body = ncmXeapi(uri, data, publicKeyState: state);
    final cookie = <String, dynamic>{
      'os': 'android',
      'osver': '16',
      'appver': '9.1.65',
      'buildver': (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
      'deviceId': deviceId,
      'sDeviceId': deviceId,
      if ((jar['MUSIC_U'] ?? '').isNotEmpty) 'MUSIC_U': jar['MUSIC_U'],
      if ((jar['MUSIC_A'] ?? '').isNotEmpty) 'MUSIC_A': jar['MUSIC_A'],
    };
    final headers = <String, dynamic>{
      'X-Client-Enc-State': 'ENCRYPTED',
      'x-aeapi': 'true',
      'x-deviceid': deviceId,
      'x-os': 'android',
      'x-osver': '16',
      'x-appver': '9.1.65',
      'x-sdeviceid': deviceId,
      'x-buildver': cookie['buildver'],
      if ((jar['MUSIC_U'] ?? '').isNotEmpty) 'x-music-u': jar['MUSIC_U'],
      'Cookie': _cookieString(cookie),
    };
    final resp = await xeapi.post<List<int>>(
      '/xeapi/${uri.substring(5)}',
      data: body,
      options: Options(
        contentType: Headers.formUrlEncodedContentType,
        responseType: ResponseType.bytes,
        headers: headers,
      ),
    );
    await saveSetCookies(
        Uri.parse(kNcmXeapiDomain), resp.headers['set-cookie']);
    // TODO(xeapi-session): 响应头 x-encr-ssid/x-encr-sskey 会话密钥学习未实现。
    final bytes = resp.data is List<int>
        ? resp.data!
        : utf8.encode(resp.data.toString());
    return ncmXeapiResDecrypt(bytes);
  }
}

class NcmApiException implements Exception {
  NcmApiException(this.code, this.message);
  final int code;
  final String message;
  @override
  String toString() => 'NcmApiException($code): $message';
}
