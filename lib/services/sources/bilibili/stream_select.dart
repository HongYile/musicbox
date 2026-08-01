/// 从 playurl 响应中选择最优音频流（纯逻辑，无平台依赖）。
///
/// 降级链：dash.flac.audio(Hi-Res 30251) → dash.dolby.audio[0](30250)
///   → dash.audio 按 bandwidth 降序 + 音质 id 表次序择优。
/// backup_url 中 host 含 `upos-sz-` 的优先于 mcdn。
library;

/// 音质 id → 展示名（含网易云 991xx 自建段位）。
const Map<int, String> kAudioQualityLabels = {
  30251: 'Hi-Res',
  30250: '杜比',
  30280: '192K',
  30232: '132K',
  30216: '64K',
  // 网易云（level → id 映射见 netease/models.dart）
  99100: '母带',
  99101: 'Hi-Res',
  99102: '无损',
  99103: '320K',
  99104: '标准',
  // QQ 音乐（前缀 → id 映射见 qqmusic/api/qq_endpoints.dart）
  99200: '无损',
  99201: '320K',
  99202: '128K',
  99203: 'm4a',
  99204: 'ape',
};

/// 音质 id 优选次序表（越靠后越优，用于同 bandwidth 时决胜）。
const List<int> kAudioQualityOrder = [
  30257, 30216, 30259, 30260, 30232, 30280, 30250, 30251,
];

class StreamChoice {
  const StreamChoice({
    required this.url,
    required this.backupUrls,
    required this.qualityId,
    required this.bandwidth,
    required this.isLossless,
    required this.isDolby,
    this.expiresAt,
    this.httpHeaders = const {},
  });

  /// 首选播放地址（baseUrl，已带 upsig 签名）。
  final String url;

  /// 备用地址，upos-sz- host 在前。
  final List<String> backupUrls;

  /// 音质 id（30251/30250/30280/30232/30216…；网易云用 991xx 自建段位）。
  final int qualityId;
  final int bandwidth;
  final bool isLossless;
  final bool isDolby;

  /// 从 url 的 deadline 参数解析出的过期时间（无则 null）。
  final DateTime? expiresAt;

  /// 播放真实 CDN 所需请求头（B站走代理用不上；网易云直链需要 UA）。
  final Map<String, String> httpHeaders;

  String get qualityLabel => kAudioQualityLabels[qualityId] ?? '$qualityId';

  /// 所有候选地址（首选 + 备用）。
  List<String> get allUrls => [url, ...backupUrls];
}

class StreamSelectException implements Exception {
  StreamSelectException(this.message);
  final String message;
  @override
  String toString() => 'StreamSelectException: $message';
}

/// 风控异常：响应 data 中出现 v_voucher。
class RiskControlException implements Exception {
  RiskControlException(this.message);
  final String message;
  @override
  String toString() => 'RiskControlException: $message';
}

String _baseUrlOf(Map<String, dynamic> audio) =>
    (audio['baseUrl'] ?? audio['base_url'] ?? '') as String;

List<String> _backupUrlsOf(Map<String, dynamic> audio) {
  final raw = (audio['backupUrl'] ?? audio['backup_url'] ?? const []) as List;
  return raw.map((e) => e.toString()).toList();
}

/// 备用地址排序：host 含 upos-sz- 的优先，mcdn 靠后，其余保持原序。
List<String> sortBackupUrls(List<String> urls) {
  int rank(String u) {
    final host = Uri.tryParse(u)?.host ?? '';
    if (host.contains('upos-sz-')) return 0;
    if (host.contains('mcdn')) return 2;
    return 1;
  }

  final indexed = urls.toList();
  indexed.sort((a, b) => rank(a).compareTo(rank(b)));
  return indexed;
}

DateTime? _parseDeadline(String url) {
  final deadline = Uri.tryParse(url)?.queryParameters['deadline'];
  final sec = int.tryParse(deadline ?? '');
  if (sec == null) return null;
  return DateTime.fromMillisecondsSinceEpoch(sec * 1000);
}

StreamChoice _choiceFromAudio(
  Map<String, dynamic> audio, {
  required bool isLossless,
  required bool isDolby,
}) {
  final base = _baseUrlOf(audio);
  final backups = sortBackupUrls(_backupUrlsOf(audio));
  final url = base.isNotEmpty ? base : (backups.isNotEmpty ? backups.first : '');
  if (url.isEmpty) {
    throw StreamSelectException('音频流缺少可用地址');
  }
  return StreamChoice(
    url: url,
    backupUrls: backups.where((u) => u != url).toList(),
    qualityId: (audio['id'] as num?)?.toInt() ?? 0,
    bandwidth: (audio['bandwidth'] as num?)?.toInt() ?? 0,
    isLossless: isLossless,
    isDolby: isDolby,
    expiresAt: _parseDeadline(url),
  );
}

/// 从 playurl 响应的 data 字段选择音频流。
///
/// [playurlData] 即响应 JSON 的 `data` 对象。
/// 命中 v_voucher 抛 [RiskControlException]；无任何可用流抛 [StreamSelectException]。
StreamChoice selectAudioStream(Map<String, dynamic> playurlData) {
  if (playurlData.containsKey('v_voucher')) {
    throw RiskControlException('触发风控（v_voucher），请稍后重试');
  }
  final dash = playurlData['dash'] as Map<String, dynamic>?;
  if (dash == null) {
    throw StreamSelectException('响应中没有 dash 流信息');
  }

  // 1) Hi-Res 无损
  final flac = dash['flac'] as Map<String, dynamic>?;
  final flacAudio = flac?['audio'] as Map<String, dynamic>?;
  if (flacAudio != null && _baseUrlOf(flacAudio).isNotEmpty) {
    return _choiceFromAudio(flacAudio, isLossless: true, isDolby: false);
  }

  // 2) 杜比
  final dolby = dash['dolby'] as Map<String, dynamic>?;
  final dolbyAudios = (dolby?['audio'] as List?)?.cast<Map<String, dynamic>>();
  if (dolbyAudios != null && dolbyAudios.isNotEmpty) {
    return _choiceFromAudio(dolbyAudios.first, isLossless: false, isDolby: true);
  }

  // 3) 普通音频：bandwidth 降序，同码率按音质 id 表次序（靠后者优）
  final audios = (dash['audio'] as List?)?.cast<Map<String, dynamic>>() ?? [];
  if (audios.isEmpty) {
    throw StreamSelectException('dash 中没有任何音频流');
  }
  final sorted = audios.toList()
    ..sort((a, b) {
      final bwA = (a['bandwidth'] as num?)?.toInt() ?? 0;
      final bwB = (b['bandwidth'] as num?)?.toInt() ?? 0;
      if (bwA != bwB) return bwB.compareTo(bwA);
      final idA = (a['id'] as num?)?.toInt() ?? 0;
      final idB = (b['id'] as num?)?.toInt() ?? 0;
      final idxA = kAudioQualityOrder.indexOf(idA);
      final idxB = kAudioQualityOrder.indexOf(idB);
      if (idxA == -1 && idxB == -1) return 0;
      if (idxA == -1) return 1;
      if (idxB == -1) return -1;
      return idxB.compareTo(idxA);
    });
  return _choiceFromAudio(sorted.first, isLossless: false, isDolby: false);
}
