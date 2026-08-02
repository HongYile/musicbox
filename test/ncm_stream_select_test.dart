/// 网易云降级链与搜索解析单测（纯逻辑，假 fetcher 注入）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:unison/services/sources/netease/models.dart';
import 'package:unison/services/sources/netease/stream_select.dart';

NcmSongUrl _url({
  String level = 'hires',
  String? url = 'https://cdn.example.com/a.flac',
  bool freeTrial = false,
  int fee = 0,
  int br = 0,
}) =>
    NcmSongUrl(
      id: 1,
      url: url,
      level: level,
      type: 'flac',
      bitrateKbps: br,
      size: 100,
      freeTrial: freeTrial,
      fee: fee,
    );

void main() {
  group('selectNcmSongUrl 降级链', () {
    test('hires 可播直接命中，不再请求后续等级', () async {
      final asked = <String>[];
      final info = await selectNcmSongUrl((level) async {
        asked.add(level);
        return _url(level: level);
      });
      expect(info.level, 'hires');
      expect(asked, ['hires']);
    });

    test('url=null 逐级降级到 lossless', () async {
      final asked = <String>[];
      final info = await selectNcmSongUrl((level) async {
        asked.add(level);
        return level == 'lossless'
            ? _url(level: level)
            : _url(level: level, url: null, fee: 1);
      });
      expect(info.level, 'lossless');
      expect(asked, ['hires', 'lossless']);
    });

    test('freeTrial（试听）视为不可播继续降级', () async {
      final info = await selectNcmSongUrl((level) async =>
          _url(level: level, freeTrial: level != 'standard'));
      expect(info.level, 'standard');
    });

    test('全部不可播抛异常并带 VIP 提示', () async {
      expect(
        () => selectNcmSongUrl(
            (level) async => _url(level: level, url: null, fee: 1)),
        throwsA(predicate((e) =>
            e is NcmStreamSelectException && e.message.contains('VIP'))),
      );
    });
  });

  group('ncmStreamChoice', () {
    test('hires → Hi-Res 音质 id + 无损标记 + UA 头', () {
      final c = ncmStreamChoice(_url(level: 'hires', br: 2000));
      expect(c.qualityId, 99101);
      expect(c.qualityLabel, 'Hi-Res');
      expect(c.isLossless, isTrue);
      expect(c.httpHeaders, isNotEmpty);
    });

    test('exhigh → 320K 且非无损', () {
      final c = ncmStreamChoice(_url(level: 'exhigh', br: 320));
      expect(c.qualityId, 99103);
      expect(c.qualityLabel, '320K');
      expect(c.isLossless, isFalse);
      expect(c.bandwidth, 320000);
    });
  });

  group('NcmSong.fromJson（cloudsearch 解析）', () {
    test('ar/al 字段', () {
      final s = NcmSong.fromJson({
        'id': 123,
        'name': '晴天',
        'ar': [
          {'name': '周杰伦'},
          {'name': '某人'},
        ],
        'al': {'name': '叶惠美', 'picUrl': 'https://p1.music.126.net/x.jpg'},
        'dt': 269000,
      });
      expect(s.id, 123);
      expect(s.artists, '周杰伦/某人');
      expect(s.album, '叶惠美');
      expect(s.durationMs, 269000);
      expect(s.coverUrl, 'https://p1.music.126.net/x.jpg');
    });

    test('artists/album 兼容字段 + 缺失兜底', () {
      final s = NcmSong.fromJson({
        'id': 1,
        'name': 'x',
        'artists': [
          {'name': 'a'}
        ],
        'album': {'name': 'b'},
        'duration': 1000,
      });
      expect(s.artists, 'a');
      expect(s.album, 'b');
      expect(s.coverUrl, '');
    });
  });

  group('NcmSongUrl.fromJson', () {
    test('freeTrialInfo 非空 → 试听；sr 兼容字段', () {
      final info = NcmSongUrl.fromJson({
        'id': 1,
        'url': 'https://m702.music.126.net/x.mp3',
        'level': 'hires',
        'type': 'mp3',
        'br': 128000,
        'size': 100,
        'freeTrialInfo': {'end': 30},
        'fee': 1,
        'sr': 48000,
      });
      expect(info.freeTrial, isTrue);
      expect(info.playable, isFalse);
      expect(info.sampleRate, 48000);
      expect(info.bitrateKbps, 128);
    });

    test('url null + fee=1 → 不可播', () {
      final info = NcmSongUrl.fromJson(
          {'id': 1, 'url': null, 'level': 'lossless', 'fee': 1});
      expect(info.playable, isFalse);
      expect(info.isLossless, isTrue);
    });
  });
}
