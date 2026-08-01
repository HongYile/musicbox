// 无界面联调脚本：匿名走一遍 nav(WBI key) → 签名搜索 → pagelist → playurl → 选流。
// 运行：dart run tool/smoke_test.dart [关键词]
import 'dart:io';

import 'package:musicbox/services/sources/bilibili/api/client.dart';
import 'package:musicbox/services/sources/bilibili/api/endpoints.dart';
import 'package:musicbox/services/sources/bilibili/stream_select.dart';

Future<void> main(List<String> args) async {
  final keyword = args.isNotEmpty ? args.first : '周杰伦';
  final client = BiliClient.memory();
  final api = BiliApi(client);

  try {
    final mixin = await client.wbiKeys.mixinKey();
    stdout.writeln('[1] wbi keys ok, mixin_key=$mixin');

    final navInfo = await api.nav();
    stdout.writeln(
        '[2] nav ok, isLogin=${navInfo.isLogin} mid=${navInfo.mid}');

    final results = await api.searchVideos(keyword);
    if (results.isEmpty) {
      stderr.writeln('FAIL: 搜索 "$keyword" 无结果');
      exitCode = 1;
      return;
    }
    final first = results.first;
    stdout.writeln(
        '[3] search ok, ${results.length} 条；第一条: ${first.bvid} ${first.title} (${first.author})');

    final pages = await api.pagelist(first.bvid);
    if (pages.isEmpty) {
      stderr.writeln('FAIL: pagelist 为空');
      exitCode = 1;
      return;
    }
    final cid = pages.first.cid;
    stdout.writeln('[4] pagelist ok, cid=$cid 分P数=${pages.length}');

    final choice = await api.selectStream(first.bvid, cid);
    final host = Uri.parse(choice.url).host;
    stdout.writeln('[5] playurl+select ok:');
    stdout.writeln('    音质: ${choice.qualityLabel} (id=${choice.qualityId})');
    stdout.writeln('    bandwidth: ${choice.bandwidth}');
    stdout.writeln('    host: $host');
    stdout.writeln('    backup数: ${choice.backupUrls.length}');
    stdout.writeln('    过期时间: ${choice.expiresAt}');
    stdout.writeln(
        '    无损=${choice.isLossless} 杜比=${choice.isDolby}');
    stdout.writeln('PASS: 匿名取流链路可用');
  } on RiskControlException catch (e) {
    stderr.writeln('FAIL: $e');
    exitCode = 2;
  } on BiliApiException catch (e) {
    stderr.writeln('FAIL: $e');
    exitCode = 1;
  } catch (e) {
    stderr.writeln('FAIL: $e');
    exitCode = 1;
  } finally {
    client.api.close();
    client.passport.close();
  }
}
