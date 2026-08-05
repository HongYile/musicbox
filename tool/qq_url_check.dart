// 夏祭り 取流验证：搜 mid → mediaMidOf → 各档位 songUrl。
// 用法：dart run tool/qq_url_check.dart [关键词]
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:unison/services/sources/qqmusic/api/qq_client.dart';
import 'package:unison/services/sources/qqmusic/api/qq_endpoints.dart';

Future<void> main(List<String> args) async {
  final kw = args.isNotEmpty ? args[0] : '夏祭り 东山奈央';
  final home = Platform.environment['HOME']!;
  final api = QqApi(QqClient.persistent(
      '$home/Library/Application Support/com.krelar.unison/cookies_qq'));
  final songs = await api.searchSongs(kw);
  if (songs.isEmpty) {
    print('搜索无结果');
    exit(1);
  }
  final s = songs.first;
  print('song: ${s.name} / ${s.singer}');
  print('songMid:  ${s.songMid}');
  print('mediaMid(搜索): ${s.mediaMid}');
  final mm = await api.mediaMidOf(s.songMid);
  print('mediaMid(详情): $mm  ${mm == s.mediaMid ? "一致" : "⚠ 不一致！"}');

  for (final prefix in ['F000', 'M800', 'M500']) {
    try {
      final url = await api.songUrl(s, prefix);
      print('$prefix: ${url == null ? "空(无权限)" : "OK ${url.substring(0, 60)}..."}');
    } catch (e) {
      print('$prefix: ERR $e');
    }
  }
  exit(0);
}
