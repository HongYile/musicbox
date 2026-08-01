import 'dart:async';

import '../sources/bilibili/api/endpoints.dart';
import '../sources/bilibili/models.dart';
import 'token_store.dart';

/// 登录态。
class BiliLoginState {
  const BiliLoginState.loggedOut()
      : isLogin = false,
        mid = 0,
        uname = '';

  const BiliLoginState.loggedIn({required this.mid, required this.uname})
      : isLogin = true;

  final bool isLogin;
  final int mid;
  final String uname;
}

/// B站扫码登录与登录态管理。
///
/// cookie（SESSDATA 等）由 BiliClient 的 PersistCookieJar 持久化；
/// refresh_token 进 TokenStore（安全存储优先，文件兜底）。
class BiliAuthService {
  BiliAuthService(this._api, {TokenStore? tokenStore})
      : _storage = tokenStore ?? TokenStore();

  /// TokenStore 中 refresh_token 的 key（cookie 刷新流程也要读写）。
  static const kRefreshTokenKey = 'bili_refresh_token';

  /// TokenStore 中 cookie 刷新节流时间（nextCheckRefreshTime，毫秒 epoch）的 key。
  static const kNextCookieRefreshKey = 'bili_next_cookie_refresh_ms';

  final BiliApi _api;
  final TokenStore _storage;

  /// 申请二维码。
  Future<QrcodeSession> startLogin() => _api.qrcodeGenerate();

  /// 每 2s 轮询一次扫码状态，直到确认/失效。确认后持久化 refresh_token。
  Stream<QrcodePollResult> pollLogin(String qrcodeKey) async* {
    while (true) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final result = await _api.qrcodePoll(qrcodeKey);
      if (result.status == QrcodeStatus.confirmed) {
        final token = result.refreshToken;
        if (token != null && token.isNotEmpty) {
          await _storage.write(key: kRefreshTokenKey, value: token);
        }
        yield result;
        return;
      }
      yield result;
      if (result.status == QrcodeStatus.expired) return;
    }
  }

  /// 启动时恢复登录态：本地有 SESSDATA 即视为可能登录，调 nav 验证。
  Future<BiliLoginState> restore() async {
    if (!await _api.hasSessdata()) return const BiliLoginState.loggedOut();
    try {
      final nav = await _api.nav();
      if (!nav.isLogin) return const BiliLoginState.loggedOut();
      return BiliLoginState.loggedIn(mid: nav.mid, uname: nav.uname);
    } catch (_) {
      return const BiliLoginState.loggedOut();
    }
  }

  /// 退出登录：清 cookie、refresh_token 与 cookie 刷新节流记录。
  Future<void> logout() async {
    await _api.client.cookieJar.deleteAll();
    await _storage.delete(key: kRefreshTokenKey);
    await _storage.delete(key: kNextCookieRefreshKey);
  }
}
