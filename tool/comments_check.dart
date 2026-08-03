// 评论链路实测：用 App 持久化 cookie 跑 aidOf/replies 与 songIdByMid/comments。
// 用法：dart run tool/comments_check.dart [bvid] [songmid]
import 'dart:io';

import 'package:unison/services/sources/bilibili/api/client.dart';
import 'package:unison/services/sources/bilibili/api/endpoints.dart';
import 'package:unison/services/sources/qqmusic/api/qq_client.dart';
import 'package:unison/services/sources/qqmusic/api/qq_endpoints.dart';

Future<void> main(List<String> args) async {
  final bvid = args.isNotEmpty ? args[0] : 'BV1GJ411x7h7';
  final home = Platform.environment['HOME']!;
  final support = '$home/Library/Application Support/com.krelar.unison';

  final bili = BiliApi(BiliClient.persistent('$support/cookies'));
  final aid = await bili.aidOf(bvid);
  final page = await bili.replies(aid, ps: 3);
  print('bili aid=$aid end=${page.isEnd}');
  for (final c in page.items) {
    print('  [${c.like}] ${c.author}: ${c.message.replaceAll('\n', ' ')}');
  }

  // 咏春 - 七朵组合
  final mid = args.length > 1 ? args[1] : '002kLjjv0w884W';
  final qq = QqApi(QqClient.persistent('$support/cookies_qq'));
  final songId = await qq.songIdByMid(mid);
  final qc = await qq.comments(songId, pageSize: 3);
  print('qq songId=$songId end=${qc.isEnd}');
  for (final c in qc.items) {
    print('  [${c.like}] ${c.author}: ${c.message.replaceAll('\n', ' ')}');
  }
  exit(0);
}
