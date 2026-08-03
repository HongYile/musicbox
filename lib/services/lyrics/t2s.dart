/// 繁→简逐字转换（OpenCC STCharacters 字表，assets/t2s.txt 懒加载）。
///
/// 字表格式：`繁\t简 [候选2 ...]`，取第一个简化字。
/// 纯 Dart 无原生依赖，桌面/移动全平台可用。
library;

import 'package:flutter/services.dart' show rootBundle;

class T2s {
  T2s._();

  static Map<int, int>? _map; // 繁体 rune → 简体 rune

  /// 加载字表（幂等）。测试可注入 [loader] 从文件读。
  static Future<void> ensureLoaded({Future<String> Function()? loader}) async {
    if (_map != null) return;
    final raw = loader != null
        ? await loader()
        : await rootBundle.loadString('assets/t2s.txt');
    final map = <int, int>{};
    for (final line in raw.split('\n')) {
      if (line.isEmpty || line.startsWith('#')) continue;
      final tab = line.indexOf('\t');
      if (tab <= 0) continue;
      final t = line.substring(0, tab);
      final rest = line.substring(tab + 1).trim();
      if (rest.isEmpty) continue;
      final s = rest.split(' ').first;
      if (t.runes.length == 1 && s.runes.length == 1) {
        map[t.runes.first] = s.runes.first;
      }
    }
    _map = map;
  }

  /// 逐字转换；未加载或不在表内的字原样保留。
  static String convert(String text) {
    final map = _map;
    if (map == null || text.isEmpty) return text;
    return String.fromCharCodes(text.runes.map((r) => map[r] ?? r));
  }
}
