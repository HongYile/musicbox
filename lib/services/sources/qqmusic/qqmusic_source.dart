import '../bilibili/stream_select.dart';
import 'api/qq_endpoints.dart';
import 'models.dart';
import 'stream_select.dart';

/// QQ 音乐音源（编译期内置实现）。
///
/// B站概念映射：bvid 字段携带 songMid，cid 恒 0，无分 P 概念。
class QQMusicSource {
  QQMusicSource(this._api);

  final QqApi _api;

  static const id = 'qqmusic';
  static const sourceName = 'QQ音乐';

  Future<List<QqSong>> searchSongs(String keyword, {int page = 1}) =>
      _api.searchSongs(keyword, page: page);

  Future<StreamChoice> getStream(QqSong song) =>
      selectQqSongUrl(song, _api.songUrl);
}
