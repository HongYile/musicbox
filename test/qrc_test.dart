import 'package:unison/services/lyrics/qrc_parser.dart';
import 'package:unison/services/sources/qqmusic/api/qrc_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseQrc', () {
    test('逐字时间戳解析', () {
      final lines = parseQrc(
          '[ti:晴天]\n[ar:周杰伦]\n[0,2250]晴(0,160)天(160,160)\n[2250,1000]词：周杰伦(0,500)\n');
      expect(lines.length, 2);
      expect(lines[0].text, '晴天');
      expect(lines[0].words.length, 2);
      expect(lines[0].words[1].startMs, 160);
      expect(lines[0].words[1].durMs, 160);
    });

    test('无逐字标记的行退化为整行一个词（翻译/音译通道）', () {
      final lines = parseQrc('[1000,2000]一整行翻译文本\n');
      expect(lines.single.words.single.text, '一整行翻译文本');
      expect(lines.single.words.single.startMs, 1000);
    });

    test('sungWordCount / qrcCurrentIndex', () {
      final lines = parseQrc('[0,480]晴(0,160)天(160,160)啊(320,160)\n'
          '[1000,500]第二(0,250)行(250,250)\n');
      expect(lines[0].sungWordCount(const Duration(milliseconds: 0)), 1);
      expect(lines[0].sungWordCount(const Duration(milliseconds: 200)), 2);
      expect(lines[0].sungWordCount(const Duration(milliseconds: 999)), 3);
      expect(qrcCurrentIndex(lines, const Duration(milliseconds: 500)), 0);
      expect(qrcCurrentIndex(lines, const Duration(milliseconds: 1200)), 1);
    });

    test('元数据行与空行跳过', () {
      expect(parseQrc('[ti:标题]\n[offset:0]\n\n').length, 0);
    });
  });

  group('qrc_crypto', () {
    test('extractLyricContent 去 XML 转义', () {
      expect(
          extractLyricContent('<LyricInfo><Lyric_1 LyricContent="[0,100]a&quot;b"/>'
              '</LyricInfo>'),
          '[0,100]a"b');
    });

    test('extractLyricContent 非 XML 原样返回', () {
      expect(extractLyricContent('[0,100]直接歌词'), '[0,100]直接歌词');
    });
  });
}
