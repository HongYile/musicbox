import 'dart:async';

import '../../services/sources/bilibili/models.dart';
import '../../services/sources/netease/api/ncm_endpoints.dart';

/// 网易云登录态。
class NcmLoginState {
  const NcmLoginState.loggedOut()
      : isLogin = false,
        uid = 0,
        nickname = '';

  const NcmLoginState.loggedIn({required this.uid, required this.nickname})
      : isLogin = true;

  final bool isLogin;
  final int uid;
  final String nickname;
}

/// 网易云扫码登录与登录态管理（与 BiliAuthService 同构）。
///
/// MUSIC_U 等 cookie 由 NcmClient 的 PersistCookieJar 持久化；
/// 复用通用二维码模型 QrcodeSession/QrcodePollResult。
class NcmAuthService {
  NcmAuthService(this._api);

  final NcmApi _api;

  /// 申请二维码（unikey → 登录 URL）。
  Future<QrcodeSession> startLogin() async {
    final key = await _api.qrKey();
    if (key.isEmpty) throw StateError('login/qr/key 未返回 unikey');
    return QrcodeSession(url: _api.qrUrl(key), qrcodeKey: key);
  }

  /// 每 2s 轮询一次扫码状态，直到确认/失效。
  Stream<QrcodePollResult> pollLogin(String unikey) async* {
    while (true) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final result = await _api.qrCheck(unikey);
      switch (result.code) {
        case 803:
          yield const QrcodePollResult(status: QrcodeStatus.confirmed);
          return;
        case 800:
          yield const QrcodePollResult(status: QrcodeStatus.expired);
          return;
        case 802:
          yield const QrcodePollResult(status: QrcodeStatus.scanned);
        case 801:
        default:
          yield const QrcodePollResult(status: QrcodeStatus.waiting);
      }
    }
  }

  /// 启动时恢复登录态：本地有 MUSIC_U 即调 userAccount 验证。
  Future<NcmLoginState> restore() async {
    if (!await _api.client.hasMusicU()) return const NcmLoginState.loggedOut();
    try {
      final me = await _api.userAccount();
      return NcmLoginState.loggedIn(uid: me.uid, nickname: me.nickname);
    } catch (_) {
      return const NcmLoginState.loggedOut();
    }
  }

  /// 退出登录：清空 cookie 与缓存的 xeapi 公钥。
  Future<void> logout() => _api.client.cookieJar.deleteAll();
}
