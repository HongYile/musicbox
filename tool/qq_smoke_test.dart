/// QQ 音乐无界面联调：匿名搜索 + 无 cookie 取流（预期 purl 空、走降级到失败）。
/// 运行：dart run tool/qq_smoke_test.dart
library;

// ignore_for_file: avoid_print
import 'package:musicbox/services/sources/qqmusic/api/qq_client.dart';
import 'package:musicbox/services/sources/qqmusic/api/qq_endpoints.dart';
import 'package:musicbox/services/sources/qqmusic/stream_select.dart';

Future<void> main() async {
  final client = QqClient.memory();
  final api = QqApi(client);

  print('[1] 匿名搜索 "周杰伦"...');
  final songs = await api.searchSongs('周杰伦');
  print('    结果 ${songs.length} 条');
  if (songs.isEmpty) {
    print('FAIL: 搜索无结果');
    return;
  }
  final first = songs.first;
  print('    第一条: ${first.name} - ${first.singer} (mid=${first.songMid})');

  print('[2] 无 cookie 取流（预期逐级 purl 为空，最终失败）...');
  try {
    final choice = await selectQqSongUrl(first, api.songUrl);
    print('    意外成功: ${choice.url}（可能该曲免费）');
  } catch (e) {
    print('    按预期失败: $e');
  }

  print('[3] 凭证状态: uin=${await client.uin()} hasCredential=${await client.hasCredential()}（应均为未登录）');
  print('PASS: QQ 音乐接口形态可用');
}
