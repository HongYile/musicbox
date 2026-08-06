// 自动续期实测：用现存 p_skey 换 qqmusic_key。
// 用法：dart run tool/qq_refresh_check.dart
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:unison/services/sources/qqmusic/api/qq_client.dart';
import 'package:unison/services/sources/qqmusic/api/qq_login.dart';

Future<void> main() async {
  final home = Platform.environment['HOME']!;
  final client = QqClient.persistent(
      '$home/Library/Application Support/com.krelar.unison/cookies_qq');
  final before = await client.musicKey();
  print('换票前 qqmusic_key: ${before == null ? "无" : "有(尾号${before.substring(before.length - 4)})"}');
  final ok = await QqQrLogin(client.cookieJar).mintMusicKey();
  final after = await client.musicKey();
  print('mintMusicKey: $ok');
  print('换票后 qqmusic_key: ${after == null ? "无" : "有(尾号${after.substring(after.length - 4)})"}');
  exit(ok ? 0 : 1);
}
