import '../music_source.dart';
import 'api/endpoints.dart';
import 'models.dart';
import 'stream_select.dart';

/// B站音源：MusicSource 的第一个编译期内置实现。
class BilibiliSource implements MusicSource {
  BilibiliSource(this._api);

  final BiliApi _api;

  @override
  String get id => 'bilibili';

  @override
  String get name => '哔哩哔哩';

  @override
  Future<List<BiliSearchResult>> search(String keyword, {int page = 1}) =>
      _api.searchVideos(keyword, page: page);

  @override
  Future<StreamChoice> getStream(String bvid, int cid) =>
      _api.selectStream(bvid, cid);

  @override
  Future<List<BiliVideoPage>> pagelist(String bvid) => _api.pagelist(bvid);
}
