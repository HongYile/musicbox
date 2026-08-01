import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicbox/services/player/audio_proxy.dart';
import 'package:musicbox/services/sources/bilibili/api/client.dart';
import 'package:musicbox/services/sources/bilibili/api/endpoints.dart';

/// 本地假 CDN：可配置每个请求的状态码；hang=true 时永不响应（测超时）。
class _FakeCdn {
  HttpServer? _server;
  int statusCode = 200;
  bool hang = false;
  String? lastReferer;
  String? lastUserAgent;
  int headCount = 0;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((req) async {
      lastReferer = req.headers.value(HttpHeaders.refererHeader);
      lastUserAgent = req.headers.value(HttpHeaders.userAgentHeader);
      if (req.method == 'HEAD') headCount++;
      if (hang) return; // 永不 close，模拟超时节点
      req.response.statusCode = statusCode;
      await req.response.close();
    });
  }

  String get url => 'http://127.0.0.1:${_server!.port}/audio.m4s';

  Future<void> stop() async => _server?.close(force: true);
}

/// 假 API adapter：nav 给 WBI key，playurl 返回可编程的候选地址。
class _FakeApiAdapter implements HttpClientAdapter {
  List<String> candidates = [];
  int playurlCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    if (path == '/x/web-interface/nav') {
      return _json({
        'code': 0,
        'data': {
          'isLogin': false,
          'wbi_img': {
            'img_url': 'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png',
            'sub_url': 'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png',
          },
        },
      });
    }
    if (path == '/x/player/wbi/playurl') {
      playurlCount++;
      return _json({
        'code': 0,
        'data': {
          'dash': {
            'audio': [
              {
                'id': 30280,
                'bandwidth': 192000,
                'baseUrl': candidates.first,
                'backupUrl': candidates.sublist(1),
              },
            ],
          },
        },
      });
    }
    return ResponseBody.fromString('{"code":-404}', 404);
  }

  ResponseBody _json(Object data) => ResponseBody.fromString(
        jsonEncode(data),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}

/// 发一个不跟随重定向的 GET，返回 (statusCode, location)。
Future<(int, String?)> _getNoRedirect(String url) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.followRedirects = false;
    final resp = await req.close();
    await resp.drain<void>();
    return (resp.statusCode, resp.headers.value(HttpHeaders.locationHeader));
  } finally {
    client.close(force: true);
  }
}

void main() {
  group('CdnProber', () {
    test('首选 403 时切到备用节点', () async {
      final a = _FakeCdn()..statusCode = 403;
      final b = _FakeCdn()..statusCode = 200;
      await a.start();
      await b.start();
      addTearDown(() async {
        await a.stop();
        await b.stop();
      });

      final prober = CdnProber(timeout: const Duration(seconds: 2));
      expect(await prober.pickWorking([a.url, b.url]), b.url);
      // 探测带上了 Referer/UA
      expect(a.lastReferer, kBiliReferer);
      expect(a.lastUserAgent, kBiliUserAgent);
    });

    test('404 与超时同样触发切换；全部失败返回 null', () async {
      final dead = _FakeCdn()..statusCode = 404;
      final hanging = _FakeCdn()..hang = true;
      await dead.start();
      await hanging.start();
      addTearDown(() async {
        await dead.stop();
        await hanging.stop();
      });

      final prober = CdnProber(timeout: const Duration(milliseconds: 300));
      expect(await prober.pickWorking([dead.url, hanging.url]), isNull);
    });

    test('HEAD 返回 405 时降级 GET 探测', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        req.response.statusCode = req.method == 'HEAD' ? 405 : 200;
        await req.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}/audio.m4s';

      final prober = CdnProber(timeout: const Duration(seconds: 2));
      expect(await prober.pickWorking([url]), url);
    });
  });

  group('AudioProxy CDN 故障切换', () {
    late _FakeCdn a;
    late _FakeCdn b;
    late _FakeApiAdapter adapter;
    late AudioProxy proxy;

    setUp(() async {
      a = _FakeCdn()..statusCode = 403;
      b = _FakeCdn()..statusCode = 200;
      await a.start();
      await b.start();

      final client = BiliClient.memory();
      adapter = _FakeApiAdapter()..candidates = [a.url, b.url];
      client.api.httpClientAdapter = adapter;
      proxy = AudioProxy(
        BiliApi(client),
        prober: CdnProber(timeout: const Duration(seconds: 2)),
      );
      await proxy.start();
    });

    tearDown(() async {
      await proxy.stop();
      await a.stop();
      await b.stop();
    });

    test('主节点 403 时 302 到备用节点', () async {
      final (status, location) =
          await _getNoRedirect(proxy.streamUrl('BV1xx', 123));
      expect(status, 302);
      expect(location, b.url);
      expect(adapter.playurlCount, 1);
    });

    test('候选全部失效时重新解析 playurl 换新节点', () async {
      // 全部 403：第一次请求 502，且触发了一次重新解析
      b.statusCode = 403;
      final (status1, _) = await _getNoRedirect(proxy.streamUrl('BV1xx', 123));
      expect(status1, 502);
      expect(adapter.playurlCount, 2); // 首次解析 + 全部失效后重解析

      // 修复 b 后无需人工干预：缓存的候选还是旧的（403），
      // 全部失效 → 再解析 → 拿到新候选（指向恢复 200 的 b）→ 302
      b.statusCode = 200;
      adapter.candidates = [a.url, b.url];
      final (status2, location2) =
          await _getNoRedirect(proxy.streamUrl('BV1xx', 123));
      expect(status2, 302);
      expect(location2, b.url);
    });

    test('候选健康时不会因重解析浪费 playurl 调用', () async {
      a.statusCode = 200;
      await _getNoRedirect(proxy.streamUrl('BV1xx', 123));
      await _getNoRedirect(proxy.streamUrl('BV1xx', 123));
      expect(adapter.playurlCount, 1); // 缓存命中，无重解析
    });
  });
}
