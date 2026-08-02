import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:unison/services/sources/bilibili/hires_probe.dart';
import 'package:unison/services/sources/bilibili/stream_select.dart';

StreamChoice _choice(int qualityId,
        {bool isLossless = false, bool isDolby = false}) =>
    StreamChoice(
      url: 'https://cdn.example.com/a.m4s',
      backupUrls: const [],
      qualityId: qualityId,
      bandwidth: 100000,
      isLossless: isLossless,
      isDolby: isDolby,
    );

void main() {
  group('HiResProbe', () {
    test('缓存命中：同一 key 只调一次选流', () async {
      var calls = 0;
      final probe = HiResProbe((bvid, cid) async {
        calls++;
        return _choice(30251, isLossless: true);
      });

      final a = await probe.probe('BV1', 100);
      final b = await probe.probe('BV1', 100);
      expect(a!.isLossless, isTrue);
      expect(b!.qualityId, 30251);
      expect(calls, 1);
      expect(probe.cached('BV1', 100)!.qualityId, 30251);
    });

    test('并发去重：飞行中的同 key 请求合并', () async {
      var calls = 0;
      final gate = Completer<void>();
      final probe = HiResProbe((bvid, cid) async {
        calls++;
        await gate.future;
        return _choice(30280);
      });

      final f1 = probe.probe('BV2', 200);
      final f2 = probe.probe('BV2', 200);
      gate.complete();
      await Future.wait([f1, f2]);
      expect(calls, 1);
    });

    test('失败不缓存：返回 null 且下次可重试', () async {
      var calls = 0;
      final probe = HiResProbe((bvid, cid) async {
        calls++;
        if (calls == 1) throw StateError('boom');
        return _choice(30232);
      });

      expect(await probe.probe('BV3', 300), isNull);
      expect(probe.cached('BV3', 300), isNull);
      final retry = await probe.probe('BV3', 300);
      expect(retry!.qualityId, 30232);
      expect(calls, 2);
    });

    test('并发限制：同时在途请求不超过 maxConcurrent', () async {
      var running = 0, maxSeen = 0;
      final gates = <Completer<void>>[];
      final probe = HiResProbe((bvid, cid) {
        running++;
        if (running > maxSeen) maxSeen = running;
        final c = Completer<void>();
        gates.add(c);
        return c.future.then((_) {
          running--;
          return _choice(30280);
        });
      });

      final futures = [
        for (var i = 0; i < 8; i++) probe.probe('BV$i', i),
      ];
      // 等首批任务进入选流
      await Future<void>.delayed(const Duration(milliseconds: 1));
      expect(running, HiResProbe.maxConcurrent);

      // 循环放行所有已登记的门，直到 8 个请求全部完成
      var done = false;
      unawaited(Future.wait(futures).then((_) => done = true));
      while (!done) {
        for (final g in List<Completer<void>>.of(gates)) {
          if (!g.isCompleted) g.complete();
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await Future.wait(futures);
      expect(maxSeen, lessThanOrEqualTo(HiResProbe.maxConcurrent));
    });
  });
}
