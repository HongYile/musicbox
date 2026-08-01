import '../bilibili/stream_select.dart';
import 'api/qq_endpoints.dart';
import 'models.dart';

/// QQ 音乐选流：按降级链（F000 无损 → M800 320K → M500 128K）
/// 依次尝试，purl 为空（无权限/VIP 限定）继续降级；全部失败抛错。
Future<StreamChoice> selectQqSongUrl(
  QqSong song,
  Future<String?> Function(QqSong song, String prefix) fetch,
) async {
  Object? lastError;
  for (final prefix in kQqQualityChain) {
    final type = kQqFileTypes[prefix]!;
    try {
      final url = await fetch(song, prefix);
      if (url == null) continue; // 该档位无权限，降级
      return StreamChoice(
        url: url,
        backupUrls: const [],
        qualityId: type.$2,
        bandwidth: 0,
        isLossless: prefix == 'F000' || prefix == 'A000',
        isDolby: false,
        httpHeaders: const {
          'User-Agent':
              'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
        },
      );
    } catch (e) {
      lastError = e;
    }
  }
  throw StateError('QQ音乐取流失败（可能需绿钻登录或歌曲无版权）: $lastError');
}
