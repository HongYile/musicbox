import 'package:flutter_test/flutter_test.dart';
import 'package:unison/services/lyrics/lrc_parser.dart';
import 'package:unison/services/player/player_service.dart';

void main() {
  group('parseLrc', () {
    test('基础解析与排序', () {
      final lines = parseLrc('[00:10.00]第二行\n[00:01.50]第一行\n');
      expect(lines.length, 2);
      expect(lines[0].text, '第一行');
      expect(lines[0].time, const Duration(seconds: 1, milliseconds: 500));
      expect(lines[1].text, '第二行');
    });

    test('一行多时间标签', () {
      final lines = parseLrc('[00:01.00][00:05.00]重复行\n');
      expect(lines.length, 2);
      expect(lines[0].time, const Duration(seconds: 1));
      expect(lines[1].time, const Duration(seconds: 5));
      expect(lines.every((l) => l.text == '重复行'), isTrue);
    });

    test('跳过元数据行与无标签行', () {
      final lines = parseLrc('[ti:标题]\n[ar:歌手]\n纯文本行\n[00:02.00]有效行\n');
      expect(lines.length, 1);
      expect(lines[0].text, '有效行');
    });

    test('毫秒两位与三位都支持', () {
      final lines = parseLrc('[00:01.234]三位\n[00:02.56]两位\n');
      expect(lines[0].time, const Duration(seconds: 1, milliseconds: 234));
      expect(lines[1].time, const Duration(seconds: 2, milliseconds: 560));
    });

    test('空输入与纯空行', () {
      expect(parseLrc(''), isEmpty);
      expect(parseLrc('[00:01.00]\n'), hasLength(1));
    });
  });

  group('lrcCurrentIndex', () {
    final lines = parseLrc('[00:01.00]一\n[00:03.00]二\n[00:05.00]三\n');

    test('位置定位', () {
      expect(lrcCurrentIndex(lines, Duration.zero), -1);
      expect(lrcCurrentIndex(lines, const Duration(seconds: 1)), 0);
      expect(lrcCurrentIndex(lines, const Duration(seconds: 4)), 1);
      expect(lrcCurrentIndex(lines, const Duration(seconds: 99)), 2);
    });

    test('空歌词', () {
      expect(lrcCurrentIndex(const [], const Duration(seconds: 1)), -1);
    });
  });

  group('nextQueueIndex', () {
    test('顺序模式', () {
      expect(nextQueueIndex(current: 0, length: 3, mode: PlayMode.sequence), 1);
      expect(nextQueueIndex(current: 2, length: 3, mode: PlayMode.sequence),
          isNull);
    });

    test('单曲循环', () {
      expect(nextQueueIndex(current: 1, length: 3, mode: PlayMode.single), 1);
    });

    test('列表循环：到队尾回卷到 0', () {
      expect(nextQueueIndex(current: 0, length: 3, mode: PlayMode.loopAll), 1);
      expect(nextQueueIndex(current: 2, length: 3, mode: PlayMode.loopAll), 0);
      expect(nextQueueIndex(current: 0, length: 1, mode: PlayMode.loopAll), 0);
    });

    test('随机模式：不重复当前，范围合法', () {
      // 注入确定性随机源：恒返回 0
      final idx = nextQueueIndex(
          current: 0, length: 3, mode: PlayMode.shuffle, randomNext: (_) => 0);
      expect(idx, 1); // 排除 current=0 后的第 0 个候选是 1

      for (var c = 0; c < 5; c++) {
        for (var r = 0; r < 4; r++) {
          final v = nextQueueIndex(
              current: c, length: 5, mode: PlayMode.shuffle,
              randomNext: (_) => r);
          expect(v, isNot(equals(c)));
          expect(v, inInclusiveRange(0, 4));
        }
      }
    });

    test('随机模式：单元素队列循环自身', () {
      expect(nextQueueIndex(current: 0, length: 1, mode: PlayMode.shuffle), 0);
    });

    test('边界：空队列与越界', () {
      expect(nextQueueIndex(current: 0, length: 0, mode: PlayMode.sequence),
          isNull);
      expect(nextQueueIndex(current: 5, length: 3, mode: PlayMode.sequence),
          isNull);
    });
  });
}
