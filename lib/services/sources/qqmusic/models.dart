/// QQ 音乐手写模型（MVP 阶段不用 codegen）。
library;

import '../../lyrics/qrc_parser.dart';

class QqSong {
  const QqSong({
    required this.songMid,
    required this.mediaMid,
    required this.name,
    required this.singer,
    required this.album,
    required this.intervalSec,
    required this.coverUrl,
  });

  /// 歌曲 mid（搜索/取流主键）。
  final String songMid;

  /// 媒体文件 mid（构造 filename 用；缺失时回退 songMid）。
  final String mediaMid;
  final String name;
  final String singer;
  final String album;
  final int intervalSec;
  final String coverUrl;

  factory QqSong.fromSearchJson(Map<String, dynamic> json) {
    final songMid = (json['songmid'] ?? '') as String;
    final mediaMid = (json['strMediaMid'] ?? '') as String;
    final singers = (json['singer'] as List? ?? const [])
        .whereType<Map>()
        .map((s) => (s['name'] ?? '') as String)
        .where((n) => n.isNotEmpty)
        .join('/');
    final albumMid = (json['albummid'] ?? '') as String;
    return QqSong(
      songMid: songMid,
      mediaMid: mediaMid.isNotEmpty ? mediaMid : songMid,
      name: (json['songname'] ?? '') as String,
      singer: singers,
      album: (json['albumname'] ?? '') as String,
      intervalSec: (json['interval'] as num?)?.toInt() ?? 0,
      coverUrl: albumMid.isNotEmpty
          ? 'https://y.gtimg.cn/music/photo_new/T002R300x300M000$albumMid.jpg'
          : '',
    );
  }
}

/// QQ 音乐评论单条。
class QqComment {
  const QqComment({
    required this.author,
    required this.avatar,
    required this.message,
    required this.like,
    required this.timeSec,
  });

  final String author;
  final String avatar;
  final String message;
  final int like;
  final int timeSec;

  factory QqComment.fromJson(Map<String, dynamic> json) => QqComment(
        author: (json['nick'] ?? '') as String,
        avatar: (json['avatarurl'] ?? '') as String,
        message: (json['rootcommentcontent'] ?? '') as String,
        like: (json['praisenum'] as num?)?.toInt() ?? 0,
        timeSec: (json['time'] as num?)?.toInt() ?? 0,
      );
}

/// 评论分页结果。
class QqCommentPage {
  const QqCommentPage({required this.items, required this.isEnd});

  final List<QqComment> items;
  final bool isEnd;
}

/// QQ 歌词包：逐字原文 + 翻译 + 音译。
class QqLyricBundle {
  const QqLyricBundle({
    required this.lines,
    required this.trans,
    required this.roma,
    required this.hasWordTiming,
  });

  /// 逐字时间轴原文（无逐字时行内仅一个词）。
  final List<QrcLine> lines;

  /// 翻译：行起点 ms → 文本。
  final Map<int, String> trans;

  /// 音译：行起点 ms → 文本。
  final Map<int, String> roma;

  /// 服务端是否返回了逐字时间戳（qrc=1）。
  final bool hasWordTiming;
}
