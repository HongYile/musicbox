import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'services/auth/bili_auth.dart';
import 'services/auth/ncm_auth.dart';
import 'services/auth/qq_auth.dart';
import 'services/auth/token_store.dart';
import 'services/library/download_service.dart';
import 'services/library/library_db.dart';
import 'services/lyrics/lrclib_service.dart';
import 'services/player/audio_proxy.dart';
import 'services/player/player_service.dart';
import 'services/sources/bilibili/api/client.dart';
import 'services/sources/bilibili/api/endpoints.dart';
import 'services/sources/bilibili/bilibili_source.dart';
import 'services/sources/bilibili/hires_probe.dart';
import 'services/sources/bilibili/models.dart';
import 'services/sources/music_source.dart';
import 'services/sources/netease/api/ncm_client.dart';
import 'services/sources/netease/api/ncm_endpoints.dart';
import 'services/sources/netease/netease_source.dart';
import 'services/sources/qqmusic/api/qq_client.dart';
import 'services/sources/qqmusic/api/qq_endpoints.dart';
import 'services/sources/qqmusic/qqmusic_source.dart';
import 'services/sync/library_sync.dart';
import 'services/sync/webdav_client.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 以下三个 provider 在 main() 中 override 注入实例。

final biliClientProvider = Provider<BiliClient>(
  (ref) => throw UnimplementedError('must override in main'),
);

/// 网易云客户端（main() 中 override 注入实例）。
final ncmClientProvider = Provider<NcmClient>(
  (ref) => throw UnimplementedError('must override in main'),
);

final audioProxyProvider = Provider<AudioProxy>(
  (ref) => throw UnimplementedError('must override in main'),
);

final playerServiceProvider = Provider<PlayerService>(
  (ref) => throw UnimplementedError('must override in main'),
);

final libraryDbProvider = Provider<LibraryDatabase>(
  (ref) => throw UnimplementedError('must override in main'),
);

final downloadServiceProvider = Provider<DownloadService>(
  (ref) => throw UnimplementedError('must override in main'),
);

/// 密钥存储（main() 中 override 注入带文件兜底的实例）。
final tokenStoreProvider = Provider<TokenStore>(
  (ref) => throw UnimplementedError('must override in main'),
);

final biliApiProvider =
    Provider<BiliApi>((ref) => BiliApi(ref.watch(biliClientProvider)));

/// Hi-Res 探测（缓存+并发限制），曲目列表/搜索列表的音质徽章用。
final hiResProbeProvider =
    Provider<HiResProbe>((ref) => HiResProbe(ref.watch(biliApiProvider).selectStream));

final musicSourceProvider =
    Provider<MusicSource>((ref) => BilibiliSource(ref.watch(biliApiProvider)));

final ncmApiProvider =
    Provider<NcmApi>((ref) => NcmApi(ref.watch(ncmClientProvider)));

final neteaseSourceProvider =
    Provider<MusicSource>((ref) => NeteaseSource(ref.watch(ncmApiProvider)));

/// QQ 音乐客户端（main() 中 override 注入实例）。
final qqClientProvider = Provider<QqClient>(
  (ref) => throw UnimplementedError('must override in main'),
);

final qqApiProvider =
    Provider<QqApi>((ref) => QqApi(ref.watch(qqClientProvider)));

final qqMusicSourceProvider =
    Provider<QQMusicSource>((ref) => QQMusicSource(ref.watch(qqApiProvider)));

/// QQ 音乐登录态。
final qqLoginStateProvider = FutureProvider<bool>(
  (ref) => ref.watch(qqClientProvider).hasCredential(),
);

/// QQ 音乐登录服务（内嵌网页）。
final qqAuthServiceProvider =
    Provider<QqAuthService>((ref) => QqAuthService(ref.watch(qqClientProvider)));

// ---------- 坚果云同步 ----------

/// TokenStore 中坚果云凭证的 key。
const kNutstoreEmailKey = 'nutstore_email';
const kNutstorePasswordKey = 'nutstore_password';

/// 本 session 是否已成功拉取过一次（防"启动即推空库覆盖云端"事故）。
/// 只有拉取成功（含远端为空）后才允许防抖推送。
final syncPulledOnceProvider = StateProvider<bool>((ref) => false);

/// WebDAV 客户端（main() 注入已配置实例；保存账号后运行时更新）。
final webDavClientProvider = StateProvider<WebDavClient?>(
  (ref) => throw UnimplementedError('must override in main'),
);

/// 曲库同步服务（随 WebDAV 配置变化重建）。
final syncServiceProvider = Provider<LibrarySyncService>((ref) {
  return LibrarySyncService(
      ref.watch(libraryDbProvider), ref.watch(webDavClientProvider));
});

/// 当前选中的音源 id（'bilibili' / 'netease'）。
final selectedSourceProvider = StateProvider<String>((ref) => 'bilibili');

final ncmAuthServiceProvider =
    Provider<NcmAuthService>((ref) => NcmAuthService(ref.watch(ncmApiProvider)));

/// 网易云登录态。
final ncmLoginStateProvider =
    StateNotifierProvider<NcmLoginStateController, NcmLoginState>((ref) {
  return NcmLoginStateController(ref.watch(ncmAuthServiceProvider));
});

class NcmLoginStateController extends StateNotifier<NcmLoginState> {
  NcmLoginStateController(this._auth) : super(const NcmLoginState.loggedOut()) {
    restore();
  }

  final NcmAuthService _auth;

  Future<void> restore() async {
    state = await _auth.restore();
  }

  Future<void> onLoginSuccess() async {
    state = await _auth.restore();
  }

  Future<void> logout() async {
    await _auth.logout();
    state = const NcmLoginState.loggedOut();
  }
}

final authServiceProvider = Provider<BiliAuthService>((ref) => BiliAuthService(
    ref.watch(biliApiProvider),
    tokenStore: ref.watch(tokenStoreProvider)));

/// 当前登录态。
final loginStateProvider =
    StateNotifierProvider<LoginStateController, BiliLoginState>((ref) {
  return LoginStateController(ref.watch(authServiceProvider));
});

class LoginStateController extends StateNotifier<BiliLoginState> {
  LoginStateController(this._auth) : super(const BiliLoginState.loggedOut()) {
    restore();
  }

  final BiliAuthService _auth;

  Future<void> restore() async {
    state = await _auth.restore();
  }

  Future<void> onLoginSuccess() async {
    state = await _auth.restore();
  }

  Future<void> logout() async {
    await _auth.logout();
    state = const BiliLoginState.loggedOut();
  }
}

/// 搜索结果（按 selectedSourceProvider 分发到对应音源）。
final searchResultsProvider = StateNotifierProvider<SearchController,
    AsyncValue<List<BiliSearchResult>>>((ref) {
  return SearchController(ref);
});

class SearchController
    extends StateNotifier<AsyncValue<List<BiliSearchResult>>> {
  SearchController(this._ref) : super(const AsyncValue.data([]));

  final Ref _ref;

  String _keyword = '';
  int _page = 1;

  /// 续页状态（UI 侧配合 setState 展示底部指示器）。
  bool loadingMore = false;
  bool noMore = false;

  Future<List<BiliSearchResult>> _fetch(String keyword, int page) {
    final source = _ref.read(selectedSourceProvider);
    if (source == 'qqmusic') {
      return _ref
          .read(qqMusicSourceProvider)
          .searchSongs(keyword, page: page)
          .then((songs) => [
                for (final s in songs)
                  BiliSearchResult(
                    bvid: s.songMid,
                    title: s.name,
                    author: s.singer,
                    durationSec: s.intervalSec,
                    coverUrl: s.coverUrl,
                    play: 0,
                  ),
              ]);
    }
    final MusicSource source0 = source == 'netease'
        ? _ref.read(neteaseSourceProvider)
        : _ref.read(musicSourceProvider);
    return source0.search(keyword, page: page);
  }

  Future<void> search(String keyword) async {
    if (keyword.trim().isEmpty) return;
    _keyword = keyword.trim();
    _page = 1;
    noMore = false;
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() => _fetch(_keyword, 1));
  }

  /// 滚动到底自动续页：追加下一页结果；空页标记 noMore。
  Future<void> loadMore() async {
    if (loadingMore || noMore || _keyword.isEmpty) return;
    final current = state.value;
    if (current == null || current.isEmpty) return;
    loadingMore = true;
    try {
      final next = await _fetch(_keyword, _page + 1);
      if (next.isEmpty) {
        noMore = true;
      } else {
        _page++;
        state = AsyncValue.data([...current, ...next]);
      }
    } catch (_) {
      // 续页失败保持现有列表，下次滚动到底可重试。
    } finally {
      loadingMore = false;
    }
  }
}

/// 当前播放曲目。
final currentTrackProvider = StreamProvider<CurrentTrack?>(
  (ref) => ref.watch(playerServiceProvider).currentTrackStream,
);

final positionProvider = StreamProvider<Duration>(
  (ref) => ref.watch(playerServiceProvider).positionStream,
);

final durationProvider = StreamProvider<Duration>(
  (ref) => ref.watch(playerServiceProvider).durationStream,
);

final playingProvider = StreamProvider<bool>(
  (ref) => ref.watch(playerServiceProvider).playingStream,
);

/// 播放队列（歌单连播时非空）。
final queueProvider = StreamProvider<List<QueueItem>>(
  (ref) => ref.watch(playerServiceProvider).queueStream,
);

/// 播放模式（列表循环/顺序/单曲/随机）。
final playModeProvider = StreamProvider<PlayMode>(
  (ref) => ref.watch(playerServiceProvider).modeStream,
);

/// 读取用户持久化记忆的播放模式（默认列表循环）。
/// 自己的歌单开始播放时恢复它——B站合集强制 loopAll 只是会话级的。
Future<PlayMode> readSavedPlayMode() async {
  final prefs = await SharedPreferences.getInstance();
  return PlayMode.values.asNameMap()[prefs.getString('play_mode')] ??
      PlayMode.loopAll;
}

/// LRCLib 歌词服务。
final lrclibServiceProvider = Provider<LrclibService>((ref) => LrclibService());

// ---------- 主题 ----------

const _kThemeModeKey = 'musicbox_theme_mode';

/// 主题模式（跟随系统/亮色/暗色），持久化到 shared_preferences。
final themeModeProvider =
    StateNotifierProvider<ThemeModeController, ThemeMode>((ref) {
  return ThemeModeController();
});

class ThemeModeController extends StateNotifier<ThemeMode> {
  ThemeModeController() : super(ThemeMode.system) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final idx = prefs.getInt(_kThemeModeKey);
    if (idx != null && idx >= 0 && idx < ThemeMode.values.length) {
      state = ThemeMode.values[idx];
    }
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kThemeModeKey, mode.index);
  }
}

/// 底部导航当前页。
final navIndexProvider = StateProvider<int>((ref) => 0);

/// 左侧导航栏页序（main.dart HomeShell 的 _pages 顺序）。
class NavIndex {
  static const search = 0;
  static const library = 1;
  static const mine = 2;
}

// ---------- 本地曲库 / 歌单 ----------

/// 歌单列表（含曲目数）。
final playlistsProvider =
    StateNotifierProvider<PlaylistsController, List<PlaylistSummary>>((ref) {
  return PlaylistsController(ref.watch(libraryDbProvider));
});

class PlaylistsController extends StateNotifier<List<PlaylistSummary>> {
  PlaylistsController(this._db) : super(const []) {
    refresh();
  }

  final LibraryDatabase _db;

  void refresh() => state = _db.listPlaylistSummaries();

  int create(String name) {
    final id = _db.createPlaylist(name);
    refresh();
    return id;
  }

  void delete(int id) {
    _db.deletePlaylist(id);
    refresh();
  }

  void rename(int id, String name) {
    _db.renamePlaylist(id, name);
    refresh();
  }

  /// 拖拽排序：按新顺序重写 sort_order。
  void reorder(List<int> orderedIds) {
    _db.reorderPlaylists(orderedIds);
    refresh();
  }

  /// 加入歌单；重复返回 false。
  bool addTrack({
    required int playlistId,
    required String sourceId,
    required String trackId,
    required String title,
    String artist = '',
    String cover = '',
    int durationSec = 0,
    int cid = 0,
  }) {
    final added = _db.addTrack(
      playlistId: playlistId,
      sourceId: sourceId,
      trackId: trackId,
      title: title,
      artist: artist,
      cover: cover,
      durationSec: durationSec,
      cid: cid,
    );
    refresh();
    return added;
  }
}

/// 某歌单的曲目列表。
final playlistTracksProvider = FutureProvider.autoDispose
    .family<List<PlaylistTrack>, int>((ref, playlistId) async {
  return ref.watch(libraryDbProvider).tracksOf(playlistId);
});

// ---------- 下载 ----------

class DownloadsState {
  const DownloadsState({this.entries = const [], this.progress = const {}});

  final List<DownloadEntry> entries;

  /// trackId → 进行中进度。
  final Map<String, DownloadProgress> progress;
}

final downloadsProvider =
    StateNotifierProvider<DownloadsController, DownloadsState>((ref) {
  return DownloadsController(
      ref.watch(libraryDbProvider), ref.watch(downloadServiceProvider));
});

class DownloadsController extends StateNotifier<DownloadsState> {
  DownloadsController(this._db, this._service) : super(const DownloadsState()) {
    refresh();
    _sub = _service.progressStream.listen((p) {
      final progress = Map<String, DownloadProgress>.of(state.progress);
      if (p.status == DownloadStatus.downloading) {
        progress[p.trackId] = p;
      } else {
        progress.remove(p.trackId);
      }
      state = DownloadsState(
        entries: p.status == DownloadStatus.downloading
            ? state.entries
            : _db.listDownloads(),
        progress: progress,
      );
    });
  }

  final LibraryDatabase _db;
  final DownloadService _service;
  StreamSubscription<DownloadProgress>? _sub;

  void refresh() =>
      state = DownloadsState(entries: _db.listDownloads(), progress: state.progress);

  /// 发起下载（取最优流，Hi-Res 优先）。失败抛异常由 UI 提示。
  Future<void> start({
    required String bvid,
    required int cid,
    required String title,
    String artist = '',
    String coverUrl = '',
  }) async {
    await _service.downloadTrack(
      bvid: bvid,
      cid: cid,
      title: title,
      artist: artist,
      coverUrl: coverUrl,
    );
    refresh();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

/// 工具：秒 → mm:ss / hh:mm:ss。
String formatDuration(int seconds) {
  final d = Duration(seconds: seconds);
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final h = d.inHours;
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}
