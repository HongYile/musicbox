import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:media_kit/media_kit.dart';

import '../crash_log.dart';

import '../sources/bilibili/api/client.dart';
import '../sources/bilibili/stream_select.dart';
import '../sources/netease/api/ncm_endpoints.dart';
import '../sources/netease/stream_select.dart';
import '../sources/qqmusic/api/qq_endpoints.dart';
import '../sources/qqmusic/models.dart';
import '../sources/qqmusic/stream_select.dart';
import 'audio_proxy.dart';

/// 播放模式：列表循环（默认）/ 顺序（播完停）/ 单曲循环 / 随机。
enum PlayMode { sequence, single, shuffle, loopAll }

/// 计算"播完一首"后的下一个队列下标（纯逻辑，可单测）。
///
/// 返回 null 表示队列播完应停止；[randomNext] 为随机源（注入便于测试），
/// 参数为上限（不含），返回 [0, max)。
int? nextQueueIndex({
  required int current,
  required int length,
  required PlayMode mode,
  int Function(int max)? randomNext,
}) {
  if (length <= 0 || current < 0 || current >= length) return null;
  switch (mode) {
    case PlayMode.single:
      return current;
    case PlayMode.sequence:
      return current + 1 < length ? current + 1 : null;
    case PlayMode.loopAll:
      return (current + 1) % length;
    case PlayMode.shuffle:
      if (length == 1) return current;
      // 在排除 current 的 length-1 个候选里均匀取
      final r = (randomNext ?? Random().nextInt)(length - 1);
      return r >= current ? r + 1 : r;
  }
}

/// 当前播放曲目信息（供 UI 展示）。
class CurrentTrack {
  const CurrentTrack({
    required this.bvid,
    required this.cid,
    required this.title,
    required this.artist,
    required this.coverUrl,
    required this.quality,
  });

  final String bvid;
  final int cid;
  final String title;
  final String artist;
  final String coverUrl;
  final StreamChoice quality;
}

/// 队列条目（歌单连续播放用）。
class QueueItem {
  const QueueItem({
    required this.bvid,
    required this.cid,
    required this.title,
    required this.artist,
    required this.coverUrl,
    this.sourceId = 'bilibili',
  });

  final String bvid;
  final int cid;
  final String title;
  final String artist;
  final String coverUrl;

  /// 音源 id：bilibili / qqmusic / netease。
  final String sourceId;
}

/// media_kit 播放器封装。
///
/// 播的是本地代理地址；真实 CDN 请求所需的 Referer/UA 通过
/// httpHeaders 传给 mpv，302 跳转后仍生效。
/// 系统媒体控制（Now Playing/媒体键）由 MusicboxAudioHandler 同步。
class PlayerService {
  PlayerService(this._proxy, {this.ncmApi, this.qqApi}) {
    // 桌面端：暂停时把 mpv 输出设备置空以释放 CoreAudio——
    // 否则暂停状态仍占着声卡，macOS 会认为本机仍在输出，
    // AirPods 在附近用 iPhone 时会被这台 Mac 抢连。恢复播放时切回 auto。
    if (Platform.isMacOS || Platform.isWindows) {
      player.stream.playing.listen((playing) async {
        final platform = player.platform;
        if (platform is NativePlayer) {
          try {
            await platform.setProperty(
                'audio-device', playing ? 'auto' : 'null');
          } catch (_) {}
        }
      });
    }
  }

  final AudioProxy _proxy;
  final NcmApi? ncmApi;
  final QqApi? qqApi;
  final Player player = Player();

  final _currentTrackController = StreamController<CurrentTrack?>.broadcast();

  CurrentTrack? _current;
  CurrentTrack? get current => _current;

  Stream<CurrentTrack?> get currentTrackStream => _currentTrackController.stream;
  Stream<Duration> get positionStream => player.stream.position;
  Stream<Duration> get durationStream => player.stream.duration;
  Stream<bool> get playingStream => player.stream.playing;

  bool get playing => player.state.playing;
  Duration get position => player.state.position;
  Duration get duration => player.state.duration;

  // ---------- 队列 / 播放模式 ----------

  List<QueueItem> _queue = const [];
  int _queueIndex = -1;
  StreamSubscription<bool>? _completedSub;

  PlayMode _mode = PlayMode.loopAll;
  PlayMode get mode => _mode;

  /// 模式变更回调（main.dart 挂持久化到 shared_preferences）。
  void Function(PlayMode mode)? onModeChanged;

  final _queueController = StreamController<List<QueueItem>>.broadcast();
  final _modeController = StreamController<PlayMode>.broadcast();

  /// 播放失败通知流（UI 弹右上角提示）。
  final _errorController = StreamController<String>.broadcast();
  Stream<String> get errorStream => _errorController.stream;

  /// 当前首解析/播放失败：发通知，1 秒后由调用方继续跳下一首。
  void _notifyPlayError(Object e) {
    final t =
        _queueIndex >= 0 && _queueIndex < _queue.length ? _queue[_queueIndex] : null;
    final reason = e.toString().replaceAll(RegExp(r'^[A-Za-z]+: '), '');
    CrashLog.log('播放失败', e);
    _errorController
        .add('无法播放「${t?.title ?? '未知曲目'}」：$reason（1 秒后自动下一首）');
  }

  /// 队列变更流（歌单连播/移除条目时更新）。
  Stream<List<QueueItem>> get queueStream => _queueController.stream;
  Stream<PlayMode> get modeStream => _modeController.stream;

  List<QueueItem> get queue => _queue;
  int get queueIndex => _queueIndex;
  bool get hasNext => _queueIndex >= 0 && _queueIndex < _queue.length - 1;

  void _emitQueue() => _queueController.add(List.unmodifiable(_queue));

  /// 模式切换顺序：列表循环 → 单曲循环 → 随机 → 顺序（播完停）。
  static const _modeCycle = [
    PlayMode.loopAll,
    PlayMode.single,
    PlayMode.shuffle,
    PlayMode.sequence,
  ];

  /// 直接设置播放模式。[save] 为 false 时仅本次会话生效
  /// （合集强制列表循环用），不覆盖用户的持久化选择。
  void setMode(PlayMode mode, {bool save = true}) {
    if (mode == _mode) return;
    _mode = mode;
    _modeController.add(_mode);
    if (save) onModeChanged?.call(_mode);
  }

  /// 循环切换播放模式（列表循环 → 单曲 → 随机 → 顺序）。
  PlayMode cycleMode() {
    final next = _modeCycle[(_modeCycle.indexOf(_mode) + 1) % _modeCycle.length];
    setMode(next);
    return next;
  }

  /// 播放整个队列（歌单连续播放）：从 [startIndex] 开始，播完按模式自动切歌。
  /// [mode] 指定本次播放的模式（仅会话内生效，不覆盖持久化记忆）：
  /// B站合集传 loopAll，自己的歌单传用户记忆的模式。
  Future<CurrentTrack> playQueue(List<QueueItem> items,
      {int startIndex = 0, PlayMode? mode}) async {
    assert(items.isNotEmpty);
    if (mode != null) setMode(mode, save: false);
    _queue = List.of(items);
    _queueIndex = startIndex;
    _completedSub ??= player.stream.completed.listen((done) {
      if (done) _onCompleted();
    });
    _emitQueue();
    return _playItem(_queue[_queueIndex]);
  }

  Future<void> _onCompleted() async {
    final idx = nextQueueIndex(
        current: _queueIndex, length: _queue.length, mode: _mode);
    if (idx == null) return; // 队列播完，停住
    if (idx == _queueIndex) {
      // 单曲循环：重开当前
      try {
        await _playItem(_queue[_queueIndex]);
      } catch (_) {}
      return;
    }
    _queueIndex = idx;
    try {
      await _playItem(_queue[_queueIndex]);
    } catch (e) {
      _notifyPlayError(e);
      await Future<void>.delayed(const Duration(seconds: 1));
      await _onCompleted(); // 单首失败不中断，1 秒后继续往下
    }
  }

  /// 队列下一首（手动切歌）。随机模式下随机跳；其他模式顺序步进，到队尾停止。
  Future<void> next() async {
    if (_queue.isEmpty) return;
    final idx = _mode == PlayMode.shuffle
        ? nextQueueIndex(
            current: _queueIndex, length: _queue.length, mode: _mode)
        : (_queueIndex + 1 < _queue.length ? _queueIndex + 1 : null);
    if (idx == null) return;
    _queueIndex = idx;
    try {
      await _playItem(_queue[_queueIndex]);
    } catch (e) {
      _notifyPlayError(e);
      await Future<void>.delayed(const Duration(seconds: 1));
      // 单首失败不中断队列，继续往下
      await next();
    }
  }

  Future<void> previous() async {
    if (_queueIndex <= 0) return;
    _queueIndex--;
    await _playItem(_queue[_queueIndex]);
  }

  /// 跳转播放队列中第 [index] 首。
  Future<void> playAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    _queueIndex = index;
    await _playItem(_queue[index]);
  }

  /// 追加到播放队列末尾（不动当前播放）。若队列空闲则从它开始播。
  Future<void> enqueue(QueueItem item) async {
    _completedSub ??= player.stream.completed.listen((done) {
      if (done) _onCompleted();
    });
    if (_queue.isEmpty && _current == null) {
      _queue = [item];
      _queueIndex = 0;
      _emitQueue();
      await _playItem(item);
      return;
    }
    _queue = [..._queue, item];
    _emitQueue();
  }

  /// 下一首播放：插到当前曲目之后（不动当前播放）。队列空闲则直接播。
  Future<void> playNext(QueueItem item) async {
    if (_queue.isEmpty || _current == null || _queueIndex < 0) {
      await enqueue(item);
      return;
    }
    _queue = [..._queue]..insert(_queueIndex + 1, item);
    _emitQueue();
  }

  /// 批量追加到播放队列末尾。
  Future<void> enqueueAll(List<QueueItem> items) async {
    for (final item in items) {
      await enqueue(item);
    }
  }

  /// 从队列移除第 [index] 首；移除当前首时自动播放补位曲目。
  Future<void> removeAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    _queue.removeAt(index);
    if (_queue.isEmpty) {
      await stop();
      return;
    }
    if (index < _queueIndex) {
      _queueIndex--;
    } else if (index == _queueIndex) {
      if (_queueIndex >= _queue.length) _queueIndex = _queue.length - 1;
      await _playItem(_queue[_queueIndex]);
    }
    _emitQueue();
  }

  /// 播放指定稿件：先经代理解析出流（拿到音质信息），再播本地代理地址。
  Future<CurrentTrack> playTrack({
    required String bvid,
    required int cid,
    required String title,
    required String artist,
    required String coverUrl,
  }) async {
    // 单曲播放清空队列
    _queue = const [];
    _queueIndex = -1;
    return _playItem(QueueItem(
      bvid: bvid,
      cid: cid,
      title: title,
      artist: artist,
      coverUrl: coverUrl,
    ));
  }

  Future<CurrentTrack> _playItem(QueueItem item) async {
    final track = switch (item.sourceId) {
      'qqmusic' => await _resolveQq(item),
      'netease' => await _resolveNcm(item),
      _ => await _resolveBili(item),
    };
    _current = track;
    _currentTrackController.add(track);
    return track;
  }

  Future<CurrentTrack> _resolveBili(QueueItem item) async {
    final choice = await _proxy.resolveTrack(item.bvid, item.cid);
    final track = CurrentTrack(
      bvid: item.bvid,
      cid: item.cid,
      title: item.title,
      artist: item.artist,
      coverUrl: item.coverUrl,
      quality: choice,
    );
    await player.open(
      Media(
        _proxy.streamUrl(item.bvid, item.cid),
        httpHeaders: const {
          'Referer': kBiliReferer,
          'User-Agent': kBiliUserAgent,
        },
      ),
    );
    return track;
  }

  Future<CurrentTrack> _resolveQq(QueueItem item) async {
    final api = qqApi;
    if (api == null) throw StateError('QQ音乐音源未初始化');
    // mediaMid 与 songMid 可能不同（歌单只存了 songMid）——
    // 实时查真实 mediaMid，否则文件名错误导致全档位返回空
    String mediaMid = item.bvid;
    try {
      mediaMid = await api.mediaMidOf(item.bvid);
    } catch (_) {}
    final song = QqSong(
      songMid: item.bvid,
      mediaMid: mediaMid,
      name: item.title,
      singer: item.artist,
      album: '',
      intervalSec: 0,
      coverUrl: item.coverUrl,
    );
    final choice = await () async {
      try {
        return await selectQqSongUrl(song, api.songUrl);
      } catch (e) {
        // 有凭证仍全档位取不到流：多半是 qqmusic_key 过期（VIP 曲全部 104003），
        // 提示重新登录；无凭证则是权限问题。
        final hasCred = await api.client.hasCredential();
        throw StateError(hasCred
            ? 'QQ 登录凭证可能已过期，请到「我的」重新登录（或该曲无版权）'
            : '该曲需要绿钻会员（或歌曲无版权）');
      }
    }();
    final track = CurrentTrack(
      bvid: 'qq:${item.bvid}',
      cid: 0,
      title: item.title,
      artist: item.artist,
      coverUrl: item.coverUrl,
      quality: choice,
    );
    await player.open(Media(choice.url, httpHeaders: choice.httpHeaders));
    return track;
  }

  Future<CurrentTrack> _resolveNcm(QueueItem item) async {
    final api = ncmApi;
    if (api == null) throw StateError('网易云音源未初始化');
    final id = int.tryParse(item.bvid);
    if (id == null) throw ArgumentError('非法网易云曲目 id: ${item.bvid}');
    final info = await selectNcmSongUrl((level) => api.songUrlV1(id, level));
    final choice = ncmStreamChoice(info);
    final track = CurrentTrack(
      bvid: 'ncm:${item.bvid}',
      cid: 0,
      title: item.title,
      artist: item.artist,
      coverUrl: item.coverUrl,
      quality: choice,
    );
    await player.open(Media(choice.url, httpHeaders: choice.httpHeaders));
    return track;
  }

  /// 播放网易云单曲：xeapi 取流（降级链），直链 + UA 头交给 media_kit。
  Future<CurrentTrack> playNeteaseTrack({
    required String songId,
    required String title,
    required String artist,
    required String coverUrl,
  }) async {
    _queue = const [];
    _queueIndex = -1;
    final track = await _resolveNcm(QueueItem(
      bvid: songId,
      cid: 0,
      title: title,
      artist: artist,
      coverUrl: coverUrl,
      sourceId: 'netease',
    ));
    _current = track;
    _currentTrackController.add(track);
    return track;
  }

  /// 播放 QQ 音乐单曲：vkey 取流（降级链），直链 + UA 头交给 media_kit。
  Future<CurrentTrack> playQqTrack(QqSong song) async {
    _queue = const [];
    _queueIndex = -1;
    final track = await _resolveQq(QueueItem(
      bvid: song.songMid,
      cid: 0,
      title: song.name,
      artist: song.singer,
      coverUrl: song.coverUrl,
      sourceId: 'qqmusic',
    ));
    _current = track;
    _currentTrackController.add(track);
    return track;
  }

  /// 播放本地下载文件（coverUrl 传本地封面文件路径，UI 自行区分 http/file）。
  Future<CurrentTrack> playLocalFile({
    required String filePath,
    required String title,
    String artist = '',
    String coverPath = '',
    int qualityId = 0,
  }) async {
    _queue = const [];
    _queueIndex = -1;
    final choice = StreamChoice(
      url: filePath,
      backupUrls: const [],
      qualityId: qualityId,
      bandwidth: 0,
      isLossless: filePath.endsWith('.flac'),
      isDolby: false,
    );
    final track = CurrentTrack(
      bvid: '',
      cid: 0,
      title: title,
      artist: artist,
      coverUrl: coverPath,
      quality: choice,
    );
    await player.open(Media(filePath));
    _current = track;
    _currentTrackController.add(track);
    return track;
  }

  Future<void> playOrPause() => player.playOrPause();
  Future<void> seek(Duration position) => player.seek(position);

  /// 音量（0-100）。
  Future<void> setVolume(double volume) => player.setVolume(volume);
  Stream<double> get volumeStream => player.stream.volume;
  Future<void> stop() async {
    await player.stop();
    _queue = const [];
    _queueIndex = -1;
    _current = null;
    _emitQueue();
    _currentTrackController.add(null);
  }

  Future<void> dispose() async {
    await _completedSub?.cancel();
    await player.dispose();
    await _currentTrackController.close();
    await _queueController.close();
    await _modeController.close();
    await _errorController.close();
  }
}
