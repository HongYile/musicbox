/// B站音源的手写不可变模型（MVP 阶段不用 codegen）。
library;

class BiliVideoPage {
  const BiliVideoPage({
    required this.cid,
    required this.part,
    required this.durationSec,
  });

  final int cid;
  final String part;
  final int durationSec;

  factory BiliVideoPage.fromJson(Map<String, dynamic> json) => BiliVideoPage(
        cid: (json['cid'] as num).toInt(),
        part: (json['part'] ?? '') as String,
        durationSec: (json['duration'] as num?)?.toInt() ?? 0,
      );
}

class BiliSearchResult {
  const BiliSearchResult({
    required this.bvid,
    required this.title,
    required this.author,
    required this.durationSec,
    required this.coverUrl,
    required this.play,
  });

  final String bvid;
  final String title;
  final String author;
  final int durationSec;
  final String coverUrl;
  final int play;

  factory BiliSearchResult.fromJson(Map<String, dynamic> json) {
    // 标题里可能带 <em class="keyword"> 高亮标签
    final rawTitle = (json['title'] ?? '') as String;
    final title = rawTitle.replaceAll(RegExp(r'</?em[^>]*>'), '');
    var cover = (json['pic'] ?? '') as String;
    if (cover.startsWith('//')) cover = 'https:$cover';
    return BiliSearchResult(
      bvid: (json['bvid'] ?? '') as String,
      title: title,
      author: (json['author'] ?? '') as String,
      durationSec: _parseDuration((json['duration'] ?? '') as String),
      coverUrl: cover,
      play: (json['play'] as num?)?.toInt() ?? 0,
    );
  }

  static int _parseDuration(String s) {
    final parts = s.split(':').map(int.tryParse).toList();
    if (parts.any((e) => e == null)) return 0;
    final nums = parts.cast<int>();
    var sec = 0;
    for (final n in nums) {
      sec = sec * 60 + n;
    }
    return sec;
  }
}

/// 当前用户创建的收藏夹条目。
class BiliFavFolder {
  const BiliFavFolder({
    required this.id,
    required this.title,
    required this.mediaCount,
  });

  /// 收藏夹 mlid（完整 id）。
  final int id;
  final String title;
  final int mediaCount;

  factory BiliFavFolder.fromJson(Map<String, dynamic> json) => BiliFavFolder(
        id: (json['id'] as num).toInt(),
        title: (json['title'] ?? '') as String,
        mediaCount: (json['media_count'] as num?)?.toInt() ?? 0,
      );
}

/// 收藏夹内容条目（视频稿件）。
class BiliFavItem {
  const BiliFavItem({
    required this.bvid,
    required this.title,
    required this.artist,
    required this.coverUrl,
    required this.durationSec,
    required this.invalid,
  });

  final String bvid;
  final String title;
  final String artist;
  final String coverUrl;
  final int durationSec;

  /// 已失效（up 删除或其他原因）的条目不可播放/导入。
  final bool invalid;

  factory BiliFavItem.fromJson(Map<String, dynamic> json) {
    var cover = (json['cover'] ?? '') as String;
    if (cover.startsWith('//')) cover = 'https:$cover';
    final upper = (json['upper'] as Map?)?.cast<String, dynamic>() ?? const {};
    return BiliFavItem(
      bvid: (json['bvid'] ?? json['bv_id'] ?? '') as String,
      title: (json['title'] ?? '') as String,
      artist: (upper['name'] ?? '') as String,
      coverUrl: cover,
      durationSec: (json['duration'] as num?)?.toInt() ?? 0,
      invalid: (json['attr'] as num?)?.toInt() != 0,
    );
  }
}

/// 收藏夹内容的一页。
class BiliFavPage {
  const BiliFavPage({required this.items, required this.hasMore});

  final List<BiliFavItem> items;
  final bool hasMore;
}

/// 视频评论区单条（x/v2/reply）。
class BiliComment {
  const BiliComment({
    required this.author,
    required this.avatar,
    required this.message,
    required this.like,
    required this.timeSec,
    required this.replyCount,
    this.subReplies = const [],
  });

  final String author;
  final String avatar;
  final String message;
  final int like;
  final int timeSec;

  /// 楼中楼回复数。
  final int replyCount;

  /// 楼中楼预览（接口自带，最多 3 条）。
  final List<BiliComment> subReplies;

  factory BiliComment.fromJson(Map<String, dynamic> json) {
    final member = (json['member'] as Map?)?.cast<String, dynamic>() ?? const {};
    final content =
        (json['content'] as Map?)?.cast<String, dynamic>() ?? const {};
    final subs = (json['replies'] as List?) ?? const [];
    return BiliComment(
      author: (member['uname'] ?? '') as String,
      avatar: (member['avatar'] ?? '') as String,
      message: (content['message'] ?? '') as String,
      like: (json['like'] as num?)?.toInt() ?? 0,
      timeSec: (json['ctime'] as num?)?.toInt() ?? 0,
      replyCount: (json['rcount'] as num?)?.toInt() ?? 0,
      subReplies: [
        for (final s in subs.whereType<Map>())
          BiliComment.fromJson(s.cast<String, dynamic>()),
      ],
    );
  }
}

/// 评论分页结果。
class BiliCommentPage {
  const BiliCommentPage({required this.items, required this.isEnd});

  final List<BiliComment> items;
  final bool isEnd;
}

class QrcodeSession {
  const QrcodeSession({required this.url, required this.qrcodeKey});

  /// 二维码内容（登录页 url），交给 qr_flutter 渲染。
  final String url;

  /// 轮询用的秘钥。
  final String qrcodeKey;
}

enum QrcodeStatus { waiting, scanned, expired, confirmed }

class QrcodePollResult {
  const QrcodePollResult({required this.status, this.refreshToken});

  final QrcodeStatus status;
  final String? refreshToken;
}
