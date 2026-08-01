import '../ncm_crypto.dart';
import '../models.dart';
import 'ncm_client.dart';

/// 网易云接口集合（纯 Dart）。
///
/// 登录/搜索走 eapi（interfacepc），取流走 xeapi（interface3）。
class NcmApi {
  NcmApi(this.client);

  final NcmClient client;

  Map<String, dynamic> _expectMap(Map<String, dynamic> body, String what) {
    final code = (body['code'] as num?)?.toInt() ?? -1;
    if (code != 200) {
      throw NcmApiException(code, '$what 失败: ${body['message'] ?? body['msg'] ?? body}');
    }
    return body;
  }

  // ---------- 扫码登录 ----------

  /// 第一步：取 unikey。
  Future<String> qrKey() async {
    final body =
        await client.eapiPost('/api/login/qrcode/unikey', {'type': 3});
    _expectMap(body, 'login/qr/key');
    return (body['unikey'] ?? '') as String;
  }

  /// 第二步：二维码内容（纯本地拼接，交给 qr_flutter 渲染）。
  String qrUrl(String unikey) => 'https://music.163.com/login?codekey=$unikey';

  /// 第三步：轮询（800 过期 / 801 待扫码 / 802 待确认 / 803 成功）。
  ///
  /// 803 时 MUSIC_U 已在 [NcmClient.eapiPost] 内写入 CookieJar。
  Future<({int code, String message})> qrCheck(String unikey) async {
    final body = await client
        .eapiPost('/api/login/qrcode/client/login', {'key': unikey, 'type': 3});
    return (
      code: (body['code'] as num?)?.toInt() ?? -1,
      message: (body['message'] ?? '') as String,
    );
  }

  /// 当前登录账号信息（登录态校验；未登录 code 非 200）。
  Future<({int uid, String nickname})> userAccount() async {
    final body = await client.eapiPost('/api/nuser/account/get', {});
    _expectMap(body, 'nuser/account');
    final profile = (body['profile'] as Map?)?.cast<String, dynamic>() ?? const {};
    final account = (body['account'] as Map?)?.cast<String, dynamic>() ?? const {};
    return (
      uid: (account['id'] as num?)?.toInt() ?? 0,
      nickname: (profile['nickname'] ?? '') as String,
    );
  }

  /// 匿名 token（MUSIC_A）签发：无 MUSIC_U 时的兜底身份，失败不致命。
  Future<void> ensureAnonymousToken() async {
    if (await client.hasMusicU()) return;
    final ma = await client.cookieValue(kNcmWebDomain, 'MUSIC_A');
    if (ma != null && ma.isNotEmpty) return;
    try {
      await client.eapiPost('/api/register/anonimous', {
        'username': ncmAnonymousUsername(client.deviceId),
      });
    } catch (_) {
      // 匿名 token 拿不到不阻塞，接口仍可按纯匿名尝试。
    }
  }

  // ---------- 搜索 ----------

  /// cloudsearch（type=1 单曲），返回歌曲列表。
  Future<List<NcmSong>> cloudsearch(String keyword,
      {int page = 1, int limit = 30}) async {
    final body = await client.eapiPost('/api/cloudsearch/pc', {
      's': keyword,
      'type': 1,
      'limit': limit,
      'offset': (page - 1) * limit,
      'total': true,
    });
    _expectMap(body, 'cloudsearch');
    final result = (body['result'] as Map?)?.cast<String, dynamic>() ?? const {};
    final songs = (result['songs'] as List?) ?? const [];
    return songs
        .map((e) => NcmSong.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }

  // ---------- 取流 ----------

  /// song/url/v1（xeapi）。返回单条播放信息；无权限时 url=null 或 freeTrial。
  Future<NcmSongUrl> songUrlV1(int id, String level) async {
    await ensureAnonymousToken();
    final body = await client.xeapiPost(
      '/api/song/enhance/player/url/v1',
      {'ids': '[$id]', 'level': level, 'encodeType': 'flac'},
    );
    _expectMap(body, 'song/url/v1');
    final list = (body['data'] as List?) ?? const [];
    if (list.isEmpty) throw NcmApiException(-1, 'song/url/v1 返回空列表');
    return NcmSongUrl.fromJson((list.first as Map).cast<String, dynamic>());
  }
}
