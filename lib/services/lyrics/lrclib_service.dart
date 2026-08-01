import 'package:dio/dio.dart';

/// LRCLib 公开歌词 API（https://lrclib.net），与音源解耦：
/// 按 标题+艺人 搜索，取第一条含同步歌词的结果。
class LrclibService {
  LrclibService([Dio? dio])
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: 'https://lrclib.net',
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8),
              headers: {'User-Agent': 'musicbox v0.1 (personal use)'},
            ));

  final Dio _dio;

  /// 返回 LRC 文本（syncedLyrics 优先，退 plainLyrics）；找不到/出错返回 null。
  Future<String?> fetchLyric({
    required String track,
    String artist = '',
  }) async {
    final query = artist.isEmpty ? track : '$track $artist';
    try {
      final resp = await _dio.get<List<dynamic>>(
        '/api/search',
        queryParameters: {'q': query},
      );
      final list = resp.data ?? const [];
      String? plain;
      for (final item in list) {
        if (item is! Map) continue;
        final synced = item['syncedLyrics'];
        if (synced is String && synced.trim().isNotEmpty) return synced;
        final p = item['plainLyrics'];
        if (p is String && p.trim().isNotEmpty) plain ??= p;
      }
      return plain;
    } catch (_) {
      return null;
    }
  }
}
