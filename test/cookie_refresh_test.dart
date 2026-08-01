import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicbox/services/auth/cookie_refresh.dart';
import 'package:musicbox/services/sources/bilibili/api/client.dart';

class _RecordedRequest {
  _RecordedRequest(this.method, this.uri, this.body);
  final String method;
  final Uri uri;
  final String body;
}

/// 不落网的假 adapter：按注册的 responder 返回响应并记录请求。
class _FakeAdapter implements HttpClientAdapter {
  final List<_RecordedRequest> requests = [];
  FutureOr<ResponseBody> Function(RequestOptions options, String body)?
      responder;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body =
        requestStream == null ? '' : await utf8.decodeStream(requestStream);
    requests.add(_RecordedRequest(options.method, options.uri, body));
    final r = responder;
    if (r == null) return ResponseBody.fromString('{}', 404);
    return r(options, body);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object data, {int status = 200, List<String>? setCookies}) {
  return ResponseBody.fromString(
    jsonEncode(data),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
      'set-cookie': ?setCookies,
    },
  );
}

const _correspondHtml =
    '<html><body><div id="1-name">  refreshCsrfValue  </div></body></html>';

/// 搭一套带登录 cookie 的内存客户端 + 刷新服务。
class _Fixture {
  _Fixture() {
    client = BiliClient.memory();
    refreshAdapter = _FakeAdapter();
    refreshHttp = Dio()
      ..httpClientAdapter = refreshAdapter
      ..interceptors.add(CookieManager(client.cookieJar));
  }

  late final BiliClient client;
  late final _FakeAdapter refreshAdapter;
  late final Dio refreshHttp;
  final Map<String, String> tokenStore = {'token': 'oldToken'};
  DateTime now = DateTime(2026, 1, 1, 12);

  late final CookieRefreshService service = CookieRefreshService(
    client,
    readRefreshToken: () async => tokenStore['token'],
    writeRefreshToken: (token) async => tokenStore['token'] = token,
    now: () => now,
    http: refreshHttp,
  );

  Future<void> seedLoginCookies() async {
    await client.cookieJar.saveFromResponse(
      Uri.parse('https://www.bilibili.com'),
      [
        Cookie('SESSDATA', 'sess')..domain = '.bilibili.com',
        Cookie('bili_jct', 'csrf123')..domain = '.bilibili.com',
      ],
    );
  }

  /// 标准成功链路：correspond → refresh（下发新 bili_jct）→ confirm。
  void stubSuccessFlow() {
    refreshAdapter.responder = (options, body) {
      final path = options.uri.path;
      if (options.method == 'GET' && path.startsWith('/correspond/1/')) {
        return ResponseBody.fromString(_correspondHtml, 200, headers: {
          Headers.contentTypeHeader: ['text/html'],
        });
      }
      if (path == '/x/passport-login/web/cookie/refresh') {
        return _json(
          {
            'code': 0,
            'data': {'status': 0, 'refresh_token': 'newToken'},
          },
          setCookies: ['bili_jct=csrf456; Domain=.bilibili.com; Path=/'],
        );
      }
      if (path == '/x/passport-login/web/confirm/refresh') {
        return _json({'code': 0});
      }
      return ResponseBody.fromString('{}', 404);
    };
  }

  int countRequests(String pathPart, {String method = 'POST'}) =>
      refreshAdapter.requests
          .where((r) => r.method == method && r.uri.path.contains(pathPart))
          .length;
}

void main() {
  group('correspondPath / parseRefreshCsrf', () {
    test('correspondPath 输出与密钥等长的小写 hex', () {
      final path =
          CookieRefreshService.correspondPath(DateTime(2026, 1, 1));
      // 固定公钥为 1024 位 → 密文 128 字节 → 256 个 hex 字符
      expect(path, matches(RegExp(r'^[0-9a-f]{256}$')));
      // 同一公钥 OAEP 随机化：两次结果应不同
      expect(CookieRefreshService.correspondPath(DateTime(2026, 1, 1)),
          isNot(path));
    });

    test('parseRefreshCsrf 从 HTML 抠值并容错', () {
      expect(CookieRefreshService.parseRefreshCsrf(_correspondHtml),
          'refreshCsrfValue');
      expect(CookieRefreshService.parseRefreshCsrf('<html></html>'), isNull);
    });
  });

  group('CookieRefreshService', () {
    test('未登录（无 SESSDATA）不发起任何请求', () async {
      final f = _Fixture()..stubSuccessFlow();
      expect(await f.service.maybeRefresh(), isFalse);
      expect(f.refreshAdapter.requests, isEmpty);
    });

    test('完整刷新链路：表单字段、旧 token 确认、新 token 落盘', () async {
      final f = _Fixture();
      await f.seedLoginCookies();
      f.stubSuccessFlow();

      expect(await f.service.maybeRefresh(), isTrue);

      expect(f.countRequests('/correspond/1/', method: 'GET'), 1);
      expect(f.countRequests('cookie/refresh'), 1);
      expect(f.countRequests('confirm/refresh'), 1);

      final refreshReq = f.refreshAdapter.requests
          .firstWhere((r) => r.uri.path.contains('cookie/refresh'));
      expect(refreshReq.body, contains('csrf=csrf123'));
      expect(refreshReq.body, contains('refresh_csrf=refreshCsrfValue'));
      expect(refreshReq.body, contains('refresh_token=oldToken'));
      expect(refreshReq.body, contains('source=main_web'));

      // confirm 用旧 refresh_token，csrf 用刷新后的新 bili_jct
      final confirmReq = f.refreshAdapter.requests
          .firstWhere((r) => r.uri.path.contains('confirm/refresh'));
      expect(confirmReq.body, contains('refresh_token=oldToken'));
      expect(confirmReq.body, contains('csrf=csrf456'));

      expect(f.tokenStore['token'], 'newToken');
    });

    test('节流：成功后 2 天内不再刷新，到期后再次刷新', () async {
      final f = _Fixture();
      await f.seedLoginCookies();
      f.stubSuccessFlow();

      expect(await f.service.maybeRefresh(), isTrue);
      expect(f.countRequests('cookie/refresh'), 1);

      // 2 天内：直接跳过
      f.now = f.now.add(const Duration(hours: 47));
      expect(await f.service.maybeRefresh(), isFalse);
      expect(f.countRequests('cookie/refresh'), 1);

      // 超过 2 天：再次刷新
      f.now = f.now.add(const Duration(hours: 2));
      expect(await f.service.maybeRefresh(), isTrue);
      expect(f.countRequests('cookie/refresh'), 2);
    });

    test('单飞：并发调用合并为一次刷新', () async {
      final f = _Fixture();
      await f.seedLoginCookies();

      final gate = Completer<void>();
      f.refreshAdapter.responder = (options, body) async {
        final path = options.uri.path;
        if (options.method == 'GET' && path.startsWith('/correspond/1/')) {
          await gate.future; // 卡住，制造并发窗口
          return ResponseBody.fromString(_correspondHtml, 200, headers: {
            Headers.contentTypeHeader: ['text/html'],
          });
        }
        if (path == '/x/passport-login/web/cookie/refresh') {
          return _json({
            'code': 0,
            'data': {'refresh_token': 'newToken'},
          });
        }
        if (path == '/x/passport-login/web/confirm/refresh') {
          return _json({'code': 0});
        }
        return ResponseBody.fromString('{}', 404);
      };

      // 同步连发三个调用：第一个真正执行，其余合并到同一 future
      final f1 = f.service.maybeRefresh();
      final f2 = f.service.maybeRefresh();
      final f3 = f.service.maybeRefresh();
      await Future<void>.delayed(Duration.zero); // 让首个请求进入 correspond
      gate.complete();
      final results = await Future.wait([f1, f2, f3]);

      expect(results, [true, true, true]);
      expect(f.countRequests('cookie/refresh'), 1);
      expect(f.countRequests('/correspond/1/', method: 'GET'), 1);
    });

    test('失败不阻塞：30 秒窗口内不重试，窗口后可重试', () async {
      final f = _Fixture();
      await f.seedLoginCookies();
      f.refreshAdapter.responder =
          (options, body) => ResponseBody.fromString('boom', 500);

      expect(await f.service.maybeRefresh(), isFalse);
      expect(f.countRequests('/correspond/1/', method: 'GET'), 1);

      // 30 秒窗口内：不再尝试
      f.now = f.now.add(const Duration(seconds: 10));
      expect(await f.service.maybeRefresh(), isFalse);
      expect(f.countRequests('/correspond/1/', method: 'GET'), 1);

      // 窗口过后：重试
      f.now = f.now.add(const Duration(seconds: 21));
      expect(await f.service.maybeRefresh(), isFalse);
      expect(f.countRequests('/correspond/1/', method: 'GET'), 2);
    });

    test('拦截器：首个请求触发刷新，之后节流；刷新失败请求照常', () async {
      final f = _Fixture();
      await f.seedLoginCookies();
      f.stubSuccessFlow();

      final apiAdapter = _FakeAdapter()
        ..responder = (options, body) => _json({'code': 0});
      f.client.api.httpClientAdapter = apiAdapter;
      f.client.api.interceptors.add(f.service.interceptor());

      final resp1 =
          await f.client.api.get<Map<String, dynamic>>('/x/test/one');
      expect(resp1.statusCode, 200);
      expect(f.countRequests('cookie/refresh'), 1);

      final resp2 =
          await f.client.api.get<Map<String, dynamic>>('/x/test/two');
      expect(resp2.statusCode, 200);
      expect(f.countRequests('cookie/refresh'), 1);

      // 刷新链路全部 500：业务请求依然成功
      final f2 = _Fixture();
      await f2.seedLoginCookies();
      f2.refreshAdapter.responder =
          (options, body) => ResponseBody.fromString('boom', 500);
      final apiAdapter2 = _FakeAdapter()
        ..responder = (options, body) => _json({'code': 0});
      f2.client.api.httpClientAdapter = apiAdapter2;
      f2.client.api.interceptors.add(f2.service.interceptor());
      final resp3 =
          await f2.client.api.get<Map<String, dynamic>>('/x/test/three');
      expect(resp3.statusCode, 200);
    });
  });
}
