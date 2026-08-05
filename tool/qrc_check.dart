// QRC 端到端验证：用 App 内的 qrc_crypto + lyricBundle 拉真实歌词。
// 用法：dart run tool/qrc_check.dart [songmid]
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:unison/services/sources/qqmusic/api/qq_client.dart';
import 'package:unison/services/sources/qqmusic/api/qq_endpoints.dart';

Future<void> main(List<String> args) async {
  final mid = args.isNotEmpty ? args[0] : '0039MnYb0qxYhV'; // 晴天
  final title = args.length > 1 ? args[1] : '晴天';
  final artist = args.length > 2 ? args[2] : '周杰伦';
  final album = args.length > 3 ? args[3] : '叶惠美';
  final dur = args.length > 4 ? int.parse(args[4]) : 269;
  final home = Platform.environment['HOME']!;
  final api = QqApi(QqClient.persistent(
      '$home/Library/Application Support/com.krelar.unison/cookies_qq'));
  final bundle = await api.lyricBundle(mid,
      title: title, artist: artist, album: album, durationSec: dur);
  print('hasWordTiming=${bundle.hasWordTiming} lines=${bundle.lines.length} '
      'trans=${bundle.trans.length} roma=${bundle.roma.length}');
  for (final l in bundle.lines.take(4)) {
    print('[${l.startMs}+${l.durMs}] ${l.text}');
    print('   words: ${l.words.take(6).map((w) => '${w.text}@${w.startMs}').join(' ')}');
  }
  exit(0);
}
