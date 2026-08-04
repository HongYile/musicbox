// 楼中楼分页实测：dart run tool/sub_check.dart
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:unison/services/sources/bilibili/api/client.dart';
import 'package:unison/services/sources/bilibili/api/endpoints.dart';

Future<void> main() async {
  final home = Platform.environment['HOME']!;
  final api = BiliApi(BiliClient.persistent(
      '$home/Library/Application Support/com.krelar.unison/cookies'));
  // BV1GJ411x7h7 aid=80433022，热评 rpid=3760801399（1905 条楼中楼）
  final p1 = await api.subReplies(80433022, 3760801399, pn: 1);
  print('page1: ${p1.items.length} 条, isEnd=${p1.isEnd}');
  print('  首条: ${p1.items.first.author}: ${p1.items.first.message}');
  final p2 = await api.subReplies(80433022, 3760801399, pn: 2);
  print('page2: ${p2.items.length} 条, isEnd=${p2.isEnd}');
  exit(0);
}
