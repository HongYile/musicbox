/// AI 歌名提取：把 B站脏标题（【Hi-Res】/ UP主前缀/ 歌词摘句等）
/// 交给 OpenAI 兼容接口（默认 DeepSeek）提炼成干净的 歌名+歌手，
/// 用于换源试听与歌词匹配的搜索词。
///
/// Key 只存本机（TokenStore），永不上传仓库；可选加密同步（见设置页）。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

/// AI 配置（见设置页「AI 歌曲识别」）。
class AiConfig {
  const AiConfig({
    this.baseUrl = 'https://api.deepseek.com',
    this.model = 'deepseek-v4-flash',
    this.apiKey = '',
    this.syncEnabled = false,
  });

  final String baseUrl;
  final String model;
  final String apiKey;

  /// 是否把 Key 加密后随坚果云同步（默认关，仅本机保存）。
  final bool syncEnabled;

  bool get configured => apiKey.trim().isNotEmpty;

  AiConfig copyWith({
    String? baseUrl,
    String? model,
    String? apiKey,
    bool? syncEnabled,
  }) =>
      AiConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        model: model ?? this.model,
        apiKey: apiKey ?? this.apiKey,
        syncEnabled: syncEnabled ?? this.syncEnabled,
      );
}

/// 提取结果。
class AiSongName {
  const AiSongName(this.title, this.artist);

  final String title;
  final String artist;

  /// 搜索关键词（有歌手则"歌名 歌手"）。
  String get keyword => artist.isEmpty ? title : '$title $artist';
}

class AiTitleService {
  AiTitleService(this._config, {Dio? http})
      : _http = http ?? Dio(BaseOptions(
            connectTimeout: const Duration(seconds: 8),
            receiveTimeout: const Duration(seconds: 15)));

  final AiConfig Function() _config;
  final Dio _http;

  /// 会话级缓存：同一原始标题不重复调用。
  final _cache = <String, AiSongName>{};

  /// 从 [rawTitle]（必要时参考 [uploader]）提取干净歌名。
  /// 未配置/失败返回 null，调用方回退规则清洗。
  Future<AiSongName?> extract({
    required String rawTitle,
    String uploader = '',
  }) async {
    final cfg = _config();
    if (!cfg.configured || rawTitle.trim().isEmpty) return null;
    final hit = _cache[rawTitle];
    if (hit != null) return hit;

    final prompt = '从下面的B站视频标题中提取歌曲名和歌手，只输出JSON：'
        '{"title":"歌名","artist":"歌手"}。规则：去掉【】标签、'
        '"Hi-Res/无损/动态歌词/4K"等修饰、歌词摘句、播放量等噪声；'
        '标题里没有歌手时artist留空。UP主名（供参考，不一定是歌手）：$uploader\n'
        '标题：$rawTitle';
    try {
      final resp = await _http.post<Map<String, dynamic>>(
        '${cfg.baseUrl.replaceAll(RegExp(r'/$'), '')}/chat/completions',
        options: Options(headers: {
          'Authorization': 'Bearer ${cfg.apiKey.trim()}',
          'Content-Type': 'application/json',
        }),
        data: {
          'model': cfg.model,
          'messages': [
            {'role': 'user', 'content': prompt},
          ],
          'temperature': 0,
          'max_tokens': 100,
        },
      );
      final content = resp.data?['choices']?[0]?['message']?['content'];
      if (content is! String) return null;
      final parsed = parseAiSongJson(content);
      if (parsed == null || parsed.title.isEmpty) return null;
      _cache[rawTitle] = parsed;
      return parsed;
    } catch (_) {
      return null; // 网络/配额/格式问题都静默回退
    }
  }
}

/// 从模型输出里抠出 {"title","artist"}（容忍 ```json 包裹与多余文字）。
/// 纯函数便于单测。
AiSongName? parseAiSongJson(String content) {
  final start = content.indexOf('{');
  final end = content.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    final map = jsonDecode(content.substring(start, end + 1));
    if (map is! Map) return null;
    final title = (map['title'] ?? '').toString().trim();
    final artist = (map['artist'] ?? '').toString().trim();
    if (title.isEmpty) return null;
    return AiSongName(title, artist);
  } catch (_) {
    return null;
  }
}
