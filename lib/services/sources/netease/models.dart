/// 网易云音源的手写不可变模型（MVP 阶段不用 codegen）。
library;

/// 单曲（cloudsearch 结果条目）。
class NcmSong {
  const NcmSong({
    required this.id,
    required this.name,
    required this.artists,
    required this.album,
    required this.durationMs,
    required this.coverUrl,
  });

  final int id;
  final String name;

  /// 艺术家名，"/" 连接。
  final String artists;
  final String album;
  final int durationMs;
  final String coverUrl;

  factory NcmSong.fromJson(Map<String, dynamic> json) {
    final ars = (json['ar'] as List?) ?? (json['artists'] as List?) ?? const [];
    final names = ars
        .map((e) => ((e as Map)['name'] ?? '').toString())
        .where((s) => s.isNotEmpty)
        .join('/');
    final al = (json['al'] as Map?)?.cast<String, dynamic>() ??
        (json['album'] as Map?)?.cast<String, dynamic>() ??
        const {};
    return NcmSong(
      id: (json['id'] as num).toInt(),
      name: (json['name'] ?? '') as String,
      artists: names,
      album: (al['name'] ?? '') as String,
      durationMs:
          (json['dt'] as num?)?.toInt() ?? (json['duration'] as num?)?.toInt() ?? 0,
      coverUrl: (al['picUrl'] ?? '') as String,
    );
  }
}

/// 音质等级（song/url/v1 的 level 枚举子集，按降级链排序）。
class NcmLevel {
  static const jymaster = 'jymaster';
  static const hires = 'hires';
  static const lossless = 'lossless';
  static const exhigh = 'exhigh';
  static const standard = 'standard';

  /// 降级链：Hi-Res → 无损 → 极高 → 标准。
  static const fallbackChain = [hires, lossless, exhigh, standard];
}

/// 网易云音质 id（自建命名空间，避开 B站 30xxx 段）→ 展示名。
const Map<int, String> kNcmQualityLabels = {
  99100: '母带',
  99101: 'Hi-Res',
  99102: '无损',
  99103: '320K',
  99104: '标准',
};

/// level → 音质 id。
const Map<String, int> kNcmLevelQualityIds = {
  'jymaster': 99100,
  'hires': 99101,
  'lossless': 99102,
  'exhigh': 99103,
  'standard': 99104,
};

/// song/url/v1 返回的单条播放信息。
class NcmSongUrl {
  const NcmSongUrl({
    required this.id,
    required this.url,
    required this.level,
    required this.type,
    required this.bitrateKbps,
    required this.size,
    required this.freeTrial,
    required this.fee,
    this.bitDepth,
    this.sampleRate,
  });

  final int id;

  /// CDN 直链；无权限时为 null。
  final String? url;
  final String level;

  /// 容器格式（flac/mp3/aac…）。
  final String type;
  final int bitrateKbps;
  final int size;

  /// 仅试听（freeTrialInfo 非空）。
  final bool freeTrial;

  /// 0 免费 / 1 VIP / 4 付费专辑 / 8 非会员可免费低音质。
  final int fee;

  /// 无损/Hi-Res 的位深与采样率（响应里没有则为 null）。
  final int? bitDepth;
  final int? sampleRate;

  bool get isLossless =>
      level == NcmLevel.lossless ||
      level == NcmLevel.hires ||
      level == NcmLevel.jymaster;

  bool get playable => url != null && url!.isNotEmpty && !freeTrial;

  factory NcmSongUrl.fromJson(Map<String, dynamic> json) => NcmSongUrl(
        id: (json['id'] as num?)?.toInt() ?? 0,
        url: json['url'] as String?,
        level: (json['level'] ?? '') as String,
        type: (json['type'] ?? '') as String,
        bitrateKbps: ((json['br'] as num?)?.toInt() ?? 0) ~/ 1000,
        size: (json['size'] as num?)?.toInt() ?? 0,
        freeTrial: json['freeTrialInfo'] != null,
        fee: (json['fee'] as num?)?.toInt() ?? 0,
        bitDepth: (json['bitDepth'] as num?)?.toInt(),
        sampleRate: (json['sampleRate'] as num?)?.toInt() ??
            (json['sr'] as num?)?.toInt(),
      );
}

/// 播放网易云 CDN 所需的请求头（桌面端 UA；网易 CDN 不校验 Referer）。
const Map<String, String> kNcmStreamHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/3.1.29.205117',
};
