import 'package:flutter_test/flutter_test.dart';
import 'package:musicbox/services/sources/qqmusic/models.dart';
import 'package:musicbox/services/sources/qqmusic/stream_select.dart';

void main() {
  group('QqSong.fromSearchJson', () {
    test('解析搜索结果（含歌手拼接/封面/strMediaMid 回退）', () {
      final song = QqSong.fromSearchJson({
        'songmid': '0043xxxx',
        'strMediaMid': '0043yyyy',
        'songname': '追憶の海',
        'singer': [
          {'name': 'Chleh'},
        ],
        'albumname': 'Astlibra',
        'albummid': '000abcde',
        'interval': 249,
      });
      expect(song.songMid, '0043xxxx');
      expect(song.mediaMid, '0043yyyy');
      expect(song.singer, 'Chleh');
      expect(song.coverUrl, contains('000abcde'));
      expect(song.intervalSec, 249);
    });

    test('strMediaMid 缺失时回退 songMid；无 albummid 时封面为空', () {
      final song = QqSong.fromSearchJson({
        'songmid': 'm1',
        'songname': 't',
        'singer': const [],
      });
      expect(song.mediaMid, 'm1');
      expect(song.coverUrl, '');
    });
  });

  group('selectQqSongUrl 降级链', () {
    QqSong song() => QqSong(
        songMid: 'm', mediaMid: 'm', name: 'n', singer: 's', album: '', intervalSec: 0, coverUrl: '');

    test('无损命中直接返回，标记 isLossless', () async {
      final tried = <String>[];
      final choice = await selectQqSongUrl(song(), (s, prefix) async {
        tried.add(prefix);
        return 'https://cdn.example.com/$prefix.flac';
      });
      expect(choice.isLossless, isTrue);
      expect(choice.qualityId, 99200);
      expect(tried, ['F000']); // 不再尝试后续档位
    });

    test('无损无权限(purl 空)降级 320K，标记非无损', () async {
      final choice = await selectQqSongUrl(song(), (s, prefix) async {
        return prefix == 'F000' ? null : 'https://cdn.example.com/$prefix.mp3';
      });
      expect(choice.isLossless, isFalse);
      expect(choice.qualityId, 99201);
    });

    test('全部无权限抛错', () async {
      expect(
        () => selectQqSongUrl(song(), (s, prefix) async => null),
        throwsStateError,
      );
    });

    test('单档异常不中断，继续降级', () async {
      final choice = await selectQqSongUrl(song(), (s, prefix) async {
        if (prefix == 'F000') throw StateError('boom');
        if (prefix == 'M800') return null;
        return 'https://cdn.example.com/m500.mp3';
      });
      expect(choice.qualityId, 99202);
    });
  });
}
