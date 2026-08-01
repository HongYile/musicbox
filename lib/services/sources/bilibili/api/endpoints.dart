import 'package:dio/dio.dart';

import '../models.dart';
import '../stream_select.dart';
import 'client.dart';

final _wbiOptions = Options(extra: const {'useWbi': true});

/// B站接口集合（纯 Dart）。code != 0 时抛 [BiliApiException]，
/// data 含 v_voucher 时抛 [RiskControlException]。
class BiliApi {
  BiliApi(this.client);

  final BiliClient client;

  Map<String, dynamic> _expectMap(Map<String, dynamic> body, String what) {
    final code = (body['code'] as num?)?.toInt() ?? -1;
    if (code != 0) {
      throw BiliApiException(code, '$what 失败: ${body['message']}');
    }
    final data = body['data'];
    if (data is! Map<String, dynamic>) {
      throw BiliApiException(-1, '$what 返回格式异常');
    }
    if (data.containsKey('v_voucher')) {
      throw RiskControlException('$what 触发风控（v_voucher）');
    }
    return data;
  }

  /// nav：返回 (isLogin, mid, uname)。匿名时 code=-101 但 data 仍有效。
  Future<({bool isLogin, int mid, String uname})> nav() async {
    final resp =
        await client.api.get<Map<String, dynamic>>('/x/web-interface/nav');
    final body = resp.data!;
    final code = (body['code'] as num?)?.toInt() ?? -1;
    if (code != 0 && code != -101) {
      throw BiliApiException(code, 'nav 失败: ${body['message']}');
    }
    final data = (body['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    return (
      isLogin: data['isLogin'] == true,
      mid: (data['mid'] as num?)?.toInt() ?? 0,
      uname: (data['uname'] ?? '') as String,
    );
  }

  /// 视频分 P 列表（data 是数组，不走 _expectMap）。
  Future<List<BiliVideoPage>> pagelist(String bvid) async {
    final resp = await client.api.get<Map<String, dynamic>>(
      '/x/player/pagelist',
      queryParameters: {'bvid': bvid},
    );
    final body = resp.data!;
    final code = (body['code'] as num?)?.toInt() ?? -1;
    if (code != 0) {
      throw BiliApiException(code, 'pagelist 失败: ${body['message']}');
    }
    final list = (body['data'] as List?) ?? const [];
    return list
        .map((e) => BiliVideoPage.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  /// 取流（WBI 签名，fnval=4048 请求全部 DASH 流），返回 data 原文。
  Future<Map<String, dynamic>> playurl(String bvid, int cid) async {
    final resp = await client.api.get<Map<String, dynamic>>(
      '/x/player/wbi/playurl',
      queryParameters: {
        'bvid': bvid,
        'cid': cid,
        'fnval': 4048,
        'fnver': 0,
        'fourk': 1,
        'platform': 'pc',
      },
      options: _wbiOptions,
    );
    return _expectMap(resp.data!, 'playurl');
  }

  /// 取流并选中最优音频流。
  Future<StreamChoice> selectStream(String bvid, int cid) async =>
      selectAudioStream(await playurl(bvid, cid));

  /// 搜索视频稿件（WBI 签名）。
  Future<List<BiliSearchResult>> searchVideos(String keyword,
      {int page = 1}) async {
    final resp = await client.api.get<Map<String, dynamic>>(
      '/x/web-interface/wbi/search/type',
      queryParameters: {
        'search_type': 'video',
        'keyword': keyword,
        'page': page,
      },
      options: _wbiOptions,
    );
    final data = _expectMap(resp.data!, 'search');
    final result = (data['result'] as List?) ?? const [];
    return result
        .where((e) => (e as Map)['type'] == 'video')
        .map(
            (e) => BiliSearchResult.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  /// 申请扫码登录二维码。
  Future<QrcodeSession> qrcodeGenerate() async {
    final resp = await client.passport.get<Map<String, dynamic>>(
      '/x/passport-login/web/qrcode/generate',
    );
    final data = _expectMap(resp.data!, 'qrcode/generate');
    return QrcodeSession(
      url: data['url'] as String,
      qrcodeKey: data['qrcode_key'] as String,
    );
  }

  /// 轮询扫码状态（86101 未扫码 / 86090 已扫未确认 / 86038 已失效 / 0 成功）。
  Future<QrcodePollResult> qrcodePoll(String qrcodeKey) async {
    final resp = await client.passport.get<Map<String, dynamic>>(
      '/x/passport-login/web/qrcode/poll',
      queryParameters: {'qrcode_key': qrcodeKey},
    );
    final data = _expectMap(resp.data!, 'qrcode/poll');
    final code = (data['code'] as num?)?.toInt() ?? -1;
    switch (code) {
      case 0:
        return QrcodePollResult(
          status: QrcodeStatus.confirmed,
          refreshToken: data['refresh_token'] as String?,
        );
      case 86090:
        return const QrcodePollResult(status: QrcodeStatus.scanned);
      case 86038:
        return const QrcodePollResult(status: QrcodeStatus.expired);
      case 86101:
      default:
        return const QrcodePollResult(status: QrcodeStatus.waiting);
    }
  }

  /// 当前登录用户创建的全部收藏夹（WBI 签名；未登录抛异常）。
  Future<List<BiliFavFolder>> favFolders() async {
    final me = await nav();
    if (!me.isLogin) {
      throw BiliApiException(-101, '获取收藏夹需要登录');
    }
    final resp = await client.api.get<Map<String, dynamic>>(
      '/x/v3/fav/folder/created/list-all',
      queryParameters: {'up_mid': me.mid, 'type': 2},
      options: _wbiOptions,
    );
    final data = _expectMap(resp.data!, 'fav/folders');
    final list = (data['list'] as List?) ?? const [];
    return list
        .map((e) => BiliFavFolder.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  /// 某收藏夹内容分页（WBI 签名）。
  Future<BiliFavPage> favFolderContent(int mediaId,
      {int pn = 1, int ps = 20}) async {
    final resp = await client.api.get<Map<String, dynamic>>(
      '/x/v3/fav/resource/list',
      queryParameters: {
        'media_id': mediaId,
        'pn': pn,
        'ps': ps,
        'platform': 'web',
      },
      options: _wbiOptions,
    );
    final data = _expectMap(resp.data!, 'fav/resource');
    final medias = (data['medias'] as List?) ?? const [];
    return BiliFavPage(
      items: medias
          .map((e) => BiliFavItem.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
      hasMore: data['has_more'] == true,
    );
  }

  /// 本地 cookie 中是否已有 SESSDATA。
  Future<bool> hasSessdata() async {
    final cookies = await client.cookieJar
        .loadForRequest(Uri.parse('https://api.bilibili.com'));
    return cookies.any((c) => c.name == 'SESSDATA' && c.value.isNotEmpty);
  }
}
