import 'bilibili/models.dart';
import 'bilibili/stream_select.dart';

/// 音源抽象：编译期内置实现，不做运行时插件。
///
/// 每个音源提供：扫码/账号登录、搜索、取流三项能力。
abstract class MusicSource {
  /// 音源唯一 id，如 'bilibili'。
  String get id;

  /// 展示名。
  String get name;

  /// 搜索。
  Future<List<BiliSearchResult>> search(String keyword, {int page = 1});

  /// 取流并选中最优音频流。
  Future<StreamChoice> getStream(String bvid, int cid);

  /// 分 P 列表（搜索结果 → cid）。
  Future<List<BiliVideoPage>> pagelist(String bvid);
}
