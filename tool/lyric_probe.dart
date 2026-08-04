// 带登录 cookie 探测 QQ 歌词接口：
// A) fcg_query_lyric_new（匿名返回空，可能需 g_tk/登录）
// B) musicu PlayLyricInfo（带 uin/authst）
// 用法：dart run tool/lyric_probe.dart [songmid]
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:unison/services/sources/qqmusic/api/qq_client.dart';

/// QQ g_tk：由 p_skey 哈希（QQ 空间公开算法）。
int gtk(String skey) {
  var h = 5381;
  for (final c in skey.codeUnits) {
    h = (h + (h << 5) + c) & 0x7fffffff;
  }
  return h;
}

Future<void> main(List<String> args) async {
  final mid = args.isNotEmpty ? args[0] : '0039MnYb0qxYhV';
  final home = Platform.environment['HOME']!;
  final client = QqClient.persistent(
      '$home/Library/Application Support/com.krelar.unison/cookies_qq');
  final cookies = await client.cookieJar
      .loadForRequest(Uri.parse('https://y.qq.com'));
  final map = {for (final c in cookies) c.name: c.value};
  final skey = map['p_skey'] ?? map['skey'] ?? '';
  print('cookies: ${map.keys.length} 个, p_skey: ${skey.isNotEmpty}');
  final tk = gtk(skey);
  print('g_tk=$tk');

  // A) fcg_query_lyric_new 带 cookie + g_tk
  final a = await client.search.get<String>(
    '/qqmusic/fcgi-bin/fcg_query_lyric_new.fcg',
    queryParameters: {
      'songmid': mid,
      'g_tk': tk,
      'g_tk_new_20200303': tk,
      'loginUin': await client.uin(),
      'hostUin': 0,
      'format': 'json',
      'inCharset': 'utf8',
      'outCharset': 'utf-8',
      'notice': 0,
      'platform': 'yqq.json',
      'needNewCode': 0,
    },
    options: Options(responseType: ResponseType.plain),
  );
  final aText = a.data ?? '';
  print('A len=${aText.length} head: ${aText.substring(0, aText.length.clamp(0, 200))}');
  if (aText.isNotEmpty) {
    final d = jsonDecode(aText) as Map<String, dynamic>;
    for (final k in ['lyric', 'trans', 'roma']) {
      final v = (d[k] ?? '') as String;
      if (v.isEmpty) continue;
      final raw = utf8.decode(base64.decode(v), allowMalformed: true);
      print('A.$k: ${raw.substring(0, raw.length.clamp(0, 200)).replaceAll('\n', ' | ')}');
    }
  }
  exit(0);
}
