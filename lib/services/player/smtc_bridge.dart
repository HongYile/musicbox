import 'dart:async';

import 'package:smtc_windows/smtc_windows.dart';

import 'player_service.dart';

/// Windows 系统媒体控制（SMTC）桥接：媒体键/系统播放界面 ↔ PlayerService。
/// 仅 Windows 使用（macOS/iOS/Android/Linux 走 audio_service）。
class SmtcBridge {
  SmtcBridge(this._player);

  final PlayerService _player;

  StreamSubscription<PressedButton>? _btnSub;
  StreamSubscription<CurrentTrack?>? _trackSub;
  StreamSubscription<bool>? _playingSub;

  Future<void> init() async {
    await SMTCWindows.initialize();
    final smtc = SMTCWindows();

    _btnSub = smtc.buttonPressStream.listen((btn) {
      switch (btn) {
        case PressedButton.play:
          _player.player.play();
        case PressedButton.pause:
          _player.player.pause();
        case PressedButton.next:
          _player.next();
        case PressedButton.previous:
          _player.previous();
        default:
          break;
      }
    });

    _trackSub = _player.currentTrackStream.listen((t) {
      if (t == null) return;
      smtc.updateMetadata(MusicMetadata(
        title: t.title,
        artist: t.artist,
        thumbnail: t.coverUrl.startsWith('http') ? t.coverUrl : null,
      ));
    });

    _playingSub = _player.playingStream.listen((playing) {
      smtc.setPlaybackStatus(
          playing ? PlaybackStatus.playing : PlaybackStatus.paused);
    });
  }

  Future<void> dispose() async {
    await _btnSub?.cancel();
    await _trackSub?.cancel();
    await _playingSub?.cancel();
  }
}
