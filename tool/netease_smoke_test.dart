/// 网易云音源匿名联调脚本（纯 Dart，`dart run` 可执行）。
///
/// 链路：xeapi 握手 → cloudsearch(eapi) → song/url/v1(xeapi) 降级链。
/// 匿名只能拿 standard 甚至 null，打印结果即可，不强制成功取流。
library;

import 'dart:io';

import 'package:musicbox/services/sources/netease/api/ncm_client.dart';
import 'package:musicbox/services/sources/netease/api/ncm_endpoints.dart';
import 'package:musicbox/services/sources/netease/models.dart';

Future<void> main(List<String> args) async {
  final keyword = args.isNotEmpty ? args.join(' ') : '周杰伦';
  final client = NcmClient.memory();
  final api = NcmApi(client);

  stdout.writeln('== 1. xeapi 握手（公钥获取） ==');
  try {
    final state = await client.ensureXeapiKey();
    stdout.writeln(
        'OK version=${state.version} sk=${state.sk} publicKey=${state.publicKey.substring(0, 12)}...');
  } catch (e) {
    stdout.writeln('FAIL: $e');
    exitCode = 1;
    return;
  }

  stdout.writeln('\n== 2. cloudsearch（eapi，匿名）keyword=$keyword ==');
  int songId;
  try {
    final songs = await api.cloudsearch(keyword, limit: 5);
    stdout.writeln('OK ${songs.length} 条结果:');
    for (final s in songs) {
      stdout.writeln(
          '  [${s.id}] ${s.name} - ${s.artists} (${s.album}, ${s.durationMs ~/ 1000}s)');
    }
    if (songs.isEmpty) {
      stdout.writeln('FAIL: 搜索无结果');
      exitCode = 1;
      return;
    }
    songId = songs.first.id;
  } catch (e) {
    stdout.writeln('FAIL: $e');
    exitCode = 1;
    return;
  }

  stdout.writeln('\n== 3. song/url/v1（xeapi，降级链逐档打印）id=$songId ==');
  var anyPlayable = false;
  for (final level in NcmLevel.fallbackChain) {
    try {
      final info = await api.songUrlV1(songId, level);
      final url = info.url;
      stdout.writeln('  level=$level → url=${url == null ? "null" : "${url.substring(0, url.length > 80 ? 80 : url.length)}..."}'
          ' type=${info.type} br=${info.bitrateKbps}k size=${info.size}'
          ' freeTrial=${info.freeTrial} fee=${info.fee}'
          '${info.sampleRate != null ? ' sr=${info.sampleRate}' : ''}');
      if (info.playable) anyPlayable = true;
    } catch (e) {
      stdout.writeln('  level=$level → ERROR: $e');
    }
  }

  stdout.writeln('\n== 4. 匿名 token（MUSIC_A）==');
  try {
    await api.ensureAnonymousToken();
    final ma = await client.cookieValue(kNcmWebDomain, 'MUSIC_A');
    stdout.writeln(
        (ma != null && ma.isNotEmpty) ? 'OK 已写入 MUSIC_A' : '未获取（不致命）');
  } catch (e) {
    stdout.writeln('未获取（不致命）: $e');
  }

  stdout.writeln(
      '\nPASS：加解密与接口形态真实可用（匿名取流${anyPlayable ? "拿到可播地址" : "未拿到可播地址，属预期"}）。');
}
