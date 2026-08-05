// vkey 文件名矩阵测试：找出这首歌能播的文件名组合。
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:unison/services/sources/qqmusic/api/qq_client.dart';

Future<void> main() async {
  final home = Platform.environment['HOME']!;
  final client = QqClient.persistent(
      '$home/Library/Application Support/com.krelar.unison/cookies_qq');
  final uin = await client.uin();
  final key = await client.musicKey();

  const songMid = '002PNh513uZAPM';
  const mediaMid = '000N8wen19fDYh';
  final combos = <String>[
    'M500$songMid$mediaMid.mp3',
    'M500$songMid.mp3',
    'M800$songMid$mediaMid.mp3',
    'M800$songMid.mp3',
    'C400$songMid$mediaMid.m4a',
    'C400$songMid.m4a',
    'F000$songMid$mediaMid.flac',
    'F000$songMid.flac',
  ];

  for (final fn in combos) {
    final resp = await client.musicu.post(
      '/cgi-bin/musicu.fcg',
      data: {
        'req_0': {
          'module': 'vkey.GetVkeyServer',
          'method': 'CgiGetVkey',
          'param': {
            'filename': [fn],
            'guid': '123456789',
            'songmid': [songMid],
            'songtype': [0],
            'uin': uin,
            'loginflag': 1,
            'platform': '20',
          },
        },
        'comm': {'uin': uin, 'format': 'json', 'ct': 19, 'cv': 0, 'authst': ?key},
      },
    );
    try {
      final body = resp.data is String ? jsonDecode(resp.data) : resp.data;
      final data = body['req_0']['data'] as Map<String, dynamic>;
      final info = (data['midurlinfo'] as List).first as Map<String, dynamic>;
      final purl = (info['purl'] ?? '') as String;
      print('$fn → ${purl.isEmpty ? "空(result=${info['result']})" : "✓ OK"}');
    } catch (e) {
      print('$fn → ERR $e');
    }
  }
  exit(0);
}
