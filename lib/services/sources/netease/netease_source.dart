import '../bilibili/models.dart';
import '../bilibili/stream_select.dart';
import '../music_source.dart';
import 'api/ncm_endpoints.dart';
import 'stream_select.dart';

/// 网易云音源：MusicSource 的第二个编译期内置实现。
///
/// 单曲 id 映射为 bvid（cid 恒 0）；pagelist 无分 P 概念，返回单元素。
class NeteaseSource implements MusicSource {
  NeteaseSource(this._api);

  final NcmApi _api;

  @override
  String get id => 'netease';

  @override
  String get name => '网易云音乐';

  @override
  Future<List<BiliSearchResult>> search(String keyword, {int page = 1}) async {
    final songs = await _api.cloudsearch(keyword, page: page);
    return songs
        .map((s) => BiliSearchResult(
              bvid: '${s.id}',
              title: s.name,
              author: s.artists,
              durationSec: s.durationMs ~/ 1000,
              coverUrl: s.coverUrl,
              play: 0,
            ))
        .toList();
  }

  @override
  Future<StreamChoice> getStream(String bvid, int cid) async {
    final id = int.tryParse(bvid);
    if (id == null) throw NcmStreamSelectException('非法网易云曲目 id: $bvid');
    final info = await selectNcmSongUrl((level) => _api.songUrlV1(id, level));
    return ncmStreamChoice(info);
  }

  @override
  Future<List<BiliVideoPage>> pagelist(String bvid) async =>
      const [BiliVideoPage(cid: 0, part: '', durationSec: 0)];
}
