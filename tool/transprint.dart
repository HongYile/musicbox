// 翻译通道内容打印：dart run tool/transprint.dart
// ignore_for_file: avoid_print, curly_braces_in_flow_control_structures
import 'dart:io';
import 'package:unison/services/sources/qqmusic/api/qq_client.dart';
import 'package:unison/services/sources/qqmusic/api/qq_endpoints.dart';
Future<void> main() async {
  final home = Platform.environment['HOME']!;
  final api = QqApi(QqClient.persistent('$home/Library/Application Support/com.krelar.unison/cookies_qq'));
  final b = await api.lyricBundle('003WFMXk4O5ywc', title: '夜に駆ける', artist: 'YOASOBI', durationSec: 261);
  final vals = b.trans.values.take(6).toList();
  for (final v in vals) print(v);
  exit(0);
}
