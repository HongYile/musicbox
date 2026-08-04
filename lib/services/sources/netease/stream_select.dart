/// 网易云取流降级链（纯逻辑，无平台依赖）。
///
/// 依次请求 hires → lossless → exhigh → standard，
/// 命中可播放（url 非空且非试听）即返回；全部不可播抛 [NcmStreamSelectException]。
library;

import '../quality_preference.dart';
import '../bilibili/stream_select.dart';
import 'models.dart';

class NcmStreamSelectException implements Exception {
  NcmStreamSelectException(this.message);
  final String message;
  @override
  String toString() => 'NcmStreamSelectException: $message';
}

/// 按降级链取流。[fetch] 即 `NcmApi.songUrlV1`（测试可注入假实现）。
/// [chain] 默认按全局音质偏好过滤（320K 跳过无损档、128K 只留 standard）。
Future<NcmSongUrl> selectNcmSongUrl(
  Future<NcmSongUrl> Function(String level) fetch, {
  List<String>? chain,
}) async {
  chain ??= switch (QualityPreference.current) {
    '320k' => const [NcmLevel.exhigh, NcmLevel.standard],
    '128k' => const [NcmLevel.standard],
    _ => NcmLevel.fallbackChain,
  };
  NcmSongUrl? last;
  for (final level in chain) {
    final info = await fetch(level);
    last = info;
    if (info.playable) return info;
  }
  final fee = last?.fee ?? 0;
  final hint = (fee == 1 || fee == 4) ? '（VIP/付费曲目，需登录有权限的账号）' : '';
  throw NcmStreamSelectException('所有音质等级均无播放权限$hint');
}

/// NcmSongUrl → 通用 StreamChoice（直链 + UA 头，无备用地址）。
StreamChoice ncmStreamChoice(NcmSongUrl info) {
  final url = info.url;
  if (url == null || url.isEmpty) {
    throw NcmStreamSelectException('该音质无可用播放地址');
  }
  return StreamChoice(
    url: url,
    backupUrls: const [],
    qualityId: kNcmLevelQualityIds[info.level] ?? 99104,
    bandwidth: info.bitrateKbps * 1000,
    isLossless: info.isLossless,
    isDolby: false,
    httpHeaders: kNcmStreamHeaders,
  );
}
