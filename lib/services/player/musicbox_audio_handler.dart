import 'package:audio_service/audio_service.dart';

import 'player_service.dart';

/// 系统媒体控制接线（macOS Now Playing / 媒体键）。
///
/// 把 [PlayerService] 的播放状态同步给 audio_service：
/// 播放/暂停/seek/标题/艺人/封面。macOS 上 audio_service 进程内运行，
/// 直接持有 PlayerService 即可，无 isolate 问题。
class MusicboxAudioHandler extends BaseAudioHandler with SeekHandler {
  MusicboxAudioHandler(this._playerService) {
    _playerService.playingStream.listen(_broadcastState);
    _playerService.currentTrackStream.listen(_onTrackChanged);
    _playerService.durationStream.listen(_onDurationChanged);
  }

  final PlayerService _playerService;

  void _broadcastState(bool playing) {
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek},
      processingState: AudioProcessingState.ready,
      playing: playing,
      updatePosition: _playerService.position,
      speed: _playerService.player.state.rate,
    ));
  }

  void _onTrackChanged(CurrentTrack? track) {
    if (track == null) {
      mediaItem.add(null);
      return;
    }
    mediaItem.add(MediaItem(
      id: '${track.bvid}/${track.cid}',
      title: track.title,
      artist: track.artist,
      artUri: Uri.tryParse(track.coverUrl),
      duration: _playerService.duration,
    ));
    _broadcastState(_playerService.playing);
  }

  void _onDurationChanged(Duration duration) {
    final item = mediaItem.valueOrNull;
    if (item == null || duration <= Duration.zero) return;
    if (item.duration != duration) {
      mediaItem.add(item.copyWith(duration: duration));
    }
  }

  @override
  Future<void> play() => _playerService.player.play();

  @override
  Future<void> pause() => _playerService.player.pause();

  @override
  Future<void> seek(Duration position) => _playerService.seek(position);

  @override
  Future<void> skipToNext() => _playerService.next();

  @override
  Future<void> skipToPrevious() => _playerService.previous();

  @override
  Future<void> stop() => _playerService.stop();
}
