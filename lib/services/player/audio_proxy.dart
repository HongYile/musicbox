import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import '../sources/bilibili/api/client.dart';
import '../sources/bilibili/api/endpoints.dart';
import '../sources/bilibili/stream_select.dart';

/// CDN 候选节点探测器。
///
/// 播放器请求真实 CDN 需要 Referer/UA；节点失效时表现为
/// 403/404/连接超时。选定流后用 [pickWorking] 依次探测候选
/// （主 URL + backupUrls，已按 upos-sz- 优先排序），返回第一个可用地址。
class CdnProber {
  CdnProber({Duration? timeout})
      : _timeout = timeout ?? const Duration(seconds: 5);

  final Duration _timeout;

  /// 按顺序探测候选地址，返回第一个可用的；全部不可用返回 null。
  Future<String?> pickWorking(List<String> candidates) async {
    for (final url in candidates) {
      if (await _healthy(url)) return url;
    }
    return null;
  }

  Future<bool> _healthy(String url) async {
    // HEAD 优先（省流量）；节点不支持 HEAD（405）时降级 GET。
    final head = await _probe(url, 'HEAD');
    if (head != null) return head;
    return await _probe(url, 'GET') ?? false;
  }

  /// 返回 null 表示该方法不被支持（405），应降级；false 为节点不可用。
  Future<bool?> _probe(String url, String method) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final req = await client
          .openUrl(method, Uri.parse(url))
          .timeout(_timeout);
      req.followRedirects = false;
      req.headers.set(HttpHeaders.refererHeader, kBiliReferer);
      req.headers.set(HttpHeaders.userAgentHeader, kBiliUserAgent);
      final resp = await req.close().timeout(_timeout);
      await resp.drain<void>();
      if (resp.statusCode == 405) return null;
      return resp.statusCode < 400;
    } catch (_) {
      return false; // 超时/连接失败等一律视为节点不可用
    } finally {
      client.close(force: true);
    }
  }
}

/// 本地 HTTP 流代理。
///
/// media_kit 不直接播 B站 CDN URL，而是播
/// `http://127.0.0.1:<port>/stream/<bvid>/<cid>`；
/// 本服务在收到请求时才做 取流→选流，然后 302 重定向到真实 URL
/// （真实 URL 已带 upsig 签名）。流 URL 约 120 分钟过期，
/// 过期后播放器只需重新请求本代理即可拿到新地址，播放无感。
///
/// CDN 故障切换：重定向前先探测候选节点（主 URL + backupUrls），
/// 命中第一个可用节点；全部失效时才重新走一次 playurl 解析换新候选。
class AudioProxy {
  AudioProxy(this._api, {CdnProber? prober})
      : _prober = prober ?? CdnProber();

  final BiliApi _api;
  final CdnProber _prober;
  HttpServer? _server;
  final Map<String, StreamChoice> _cache = {};

  /// 距过期不足该时长视为已过期，重新解析。
  static const _expiryMargin = Duration(seconds: 60);

  int get port => _server?.port ?? 0;

  Future<void> start() async {
    if (_server != null) return;
    final router = Router()..get('/stream/<bvid>/<cid>', _handleStream);
    _server = await shelf_io.serve(
      router.call,
      InternetAddress.loopbackIPv4,
      0, // 随机端口，避免冲突
    );
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _cache.clear();
  }

  /// 播放器应请求的本地地址。
  String streamUrl(String bvid, int cid) =>
      'http://127.0.0.1:$port/stream/$bvid/$cid';

  bool _isValid(StreamChoice c) {
    final exp = c.expiresAt;
    if (exp == null) return true;
    return exp.isAfter(DateTime.now().add(_expiryMargin));
  }

  /// 解析（带缓存）某稿件的音频流，供 UI 展示音质徽章等。
  Future<StreamChoice> resolveTrack(String bvid, int cid) async {
    final key = '$bvid/$cid';
    final cached = _cache[key];
    if (cached != null && _isValid(cached)) return cached;
    final choice = await _api.selectStream(bvid, cid);
    _cache[key] = choice;
    return choice;
  }

  /// 缓存失效后强制重新解析一次 playurl（候选全部失效时调用）。
  Future<StreamChoice> _reResolve(String bvid, int cid) async {
    final key = '$bvid/$cid';
    _cache.remove(key);
    final choice = await _api.selectStream(bvid, cid);
    _cache[key] = choice;
    return choice;
  }

  Future<Response> _handleStream(Request req, String bvid, String cidStr) async {
    final cid = int.tryParse(cidStr);
    if (cid == null) return Response.badRequest(body: 'bad cid');
    try {
      var choice = await resolveTrack(bvid, cid);
      var url = await _prober.pickWorking(choice.allUrls);
      if (url == null) {
        // 候选全部失效（403/404/超时且非 URL 过期）：重新解析一次换新节点。
        choice = await _reResolve(bvid, cid);
        url = await _prober.pickWorking(choice.allUrls);
      }
      if (url == null) {
        return Response(502, body: 'all CDN candidates unavailable');
      }
      return Response.found(
        Uri.parse(url),
        headers: {'Cache-Control': 'no-store'},
      );
    } on RiskControlException catch (e) {
      return Response(429, body: '$e');
    } catch (e) {
      return Response.internalServerError(body: 'resolve failed: $e');
    }
  }
}
