import 'package:flutter_test/flutter_test.dart';
import 'package:unison/services/sources/bilibili/stream_select.dart';

Map<String, dynamic> _audio(int id, int bandwidth, {String? host, List<String>? backups}) => {
      'id': id,
      'bandwidth': bandwidth,
      'baseUrl': 'https://${host ?? 'upos-sz-mirrorcos.bilivideo.com'}/a$id.m4s?deadline=1999999999',
      'backupUrl': backups ?? [],
      'codecs': 'mp4a.40.2',
    };

void main() {
  group('selectAudioStream', () {
    test('有 flac 时优先选 Hi-Res', () {
      final data = {
        'dash': {
          'audio': [_audio(30280, 192000)],
          'flac': {
            'display': true,
            'audio': _audio(30251, 800000, backups: [
              'https://mcdn.bilivideo.com/flac.m4s',
              'https://upos-sz-mirrorcos.bilivideo.com/flac.m4s',
            ]),
          },
          'dolby': {
            'type': 2,
            'audio': [_audio(30250, 400000)],
          },
        },
      };
      final c = selectAudioStream(data);
      expect(c.isLossless, isTrue);
      expect(c.isDolby, isFalse);
      expect(c.qualityId, 30251);
      expect(c.qualityLabel, 'Hi-Res');
      expect(c.bandwidth, 800000);
      // backup 排序：upos-sz- 优先于 mcdn
      expect(c.backupUrls.first, contains('upos-sz-'));
      expect(c.backupUrls.last, contains('mcdn'));
      expect(c.expiresAt, isNotNull);
    });

    test('无 flac 有 dolby 时选杜比', () {
      final data = {
        'dash': {
          'audio': [_audio(30280, 192000), _audio(30216, 64000)],
          'dolby': {
            'type': 2,
            'audio': [_audio(30250, 400000)],
          },
        },
      };
      final c = selectAudioStream(data);
      expect(c.isLossless, isFalse);
      expect(c.isDolby, isTrue);
      expect(c.qualityId, 30250);
      expect(c.qualityLabel, '杜比');
    });

    test('只有普通 audio 时按 bandwidth 降序择优', () {
      final data = {
        'dash': {
          'audio': [
            _audio(30216, 64000),
            _audio(30280, 192000),
            _audio(30232, 132000),
          ],
        },
      };
      final c = selectAudioStream(data);
      expect(c.qualityId, 30280);
      expect(c.qualityLabel, '192K');
      expect(c.isLossless, isFalse);
      expect(c.isDolby, isFalse);
    });

    test('同 bandwidth 按音质 id 表次序择优', () {
      final data = {
        'dash': {
          'audio': [
            _audio(30232, 132000),
            _audio(30280, 132000), // 同码率，30280 在表中更靠后
          ],
        },
      };
      expect(selectAudioStream(data).qualityId, 30280);
    });

    test('v_voucher 视为风控', () {
      expect(
        () => selectAudioStream({'v_voucher': 'xxx', 'dash': {}}),
        throwsA(isA<RiskControlException>()),
      );
    });

    test('无 dash 抛 StreamSelectException', () {
      expect(() => selectAudioStream({}), throwsA(isA<StreamSelectException>()));
    });
  });
}
