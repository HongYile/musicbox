import 'dart:io';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../pages/player_page.dart';
import '../providers.dart';
import '../services/player/player_service.dart';
import '../services/sources/bilibili/api/client.dart';
import 'marquee_text.dart';
import 'quality_badge.dart';
import 'tech_background.dart';

/// 底部通栏播放器（QQ音乐/网易云桌面端布局）：
/// 顶部细进度线 + [封面·标题·徽章] [居中传输控制] [音量·歌词·更多]。
/// 常驻所有页面；无播放内容时收缩隐藏。
class PlayerHubBar extends ConsumerWidget {
  const PlayerHubBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(currentTrackProvider).value;
    if (track == null) return const SizedBox.shrink();

    final playing = ref.watch(playingProvider).value ?? false;
    final mode = ref.watch(playModeProvider).value ?? PlayMode.sequence;
    final position = ref.watch(positionProvider).value ?? Duration.zero;
    final duration = ref.watch(durationProvider).value ?? Duration.zero;
    final player = ref.read(playerServiceProvider);
    final progress = duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark
                ? const Color(0xD9141418)
                : Colors.white.withValues(alpha: 0.85),
            border: Border(
                top: BorderSide(
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.white.withValues(alpha: 0.08)
                        : const Color(0xFFDFE6EE),
                    width: 1)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 2,
                child: LinearProgressIndicator(
                  value: progress,
                  backgroundColor:
                      Theme.of(context).brightness == Brightness.dark
                          ? Colors.white.withValues(alpha: 0.12)
                          : const Color(0xFFDFE6EE),
                  valueColor:
                      const AlwaysStoppedAnimation(Color(0xFF2864F0)),
                ),
              ),
              SizedBox(
                height: 72,
                child: Row(
                  children: [
                    // 左：封面 + 信息 + 徽章（长标题走马灯，不与中控重叠）
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: Row(
                          children: [
                            GestureDetector(
                              onTap: () => _openFullPlayer(context),
                              child: MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: _cover(track.coverUrl),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  MarqueeText(
                                    track.title,
                                    style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(height: 2),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Flexible(
                                        child: Text(track.artist,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                                fontSize: 11,
                                                color: Colors.grey)),
                                      ),
                                      const SizedBox(width: 6),
                                      Tooltip(
                                        message: _qualityTip(track),
                                        child: QualityBadge(
                                            choice: track.quality,
                                            compact: true),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // 中：传输控制（小而精致）
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: _modeLabel(mode),
                          visualDensity: VisualDensity.compact,
                          onPressed: player.cycleMode,
                          icon: Icon(_modeIcon(mode), size: 18),
                        ),
                        IconButton(
                          tooltip: '上一首',
                          visualDensity: VisualDensity.compact,
                          iconSize: 24,
                          onPressed: player.previous,
                          icon: const Icon(Icons.skip_previous),
                        ),
                        Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Color(0xFF3CCBD9), Color(0xFF2864F0)],
                            ),
                            boxShadow: [
                              BoxShadow(
                                  color: const Color(0xFF2864F0)
                                      .withValues(alpha: 0.35),
                                  blurRadius: 12,
                                  offset: const Offset(0, 4)),
                            ],
                          ),
                          child: IconButton(
                            color: Colors.white,
                            visualDensity: VisualDensity.compact,
                            iconSize: 22,
                            onPressed: player.playOrPause,
                            icon: Icon(playing
                                ? Icons.pause
                                : Icons.play_arrow),
                          ),
                        ),
                        IconButton(
                          tooltip: '下一首',
                          visualDensity: VisualDensity.compact,
                          iconSize: 24,
                          onPressed: player.next,
                          icon: const Icon(Icons.skip_next),
                        ),
                        IconButton(
                          tooltip: '播放队列',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => _openQueueSheet(context, player),
                          icon: const Icon(Icons.queue_music, size: 18),
                        ),
                      ],
                    ),
                    // 右：时间 / 音量 / 浏览器打开
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                '${_fmt(position)} / ${_fmt(duration)}',
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.grey),
                                overflow: TextOverflow.fade,
                                maxLines: 1,
                                softWrap: false,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const _VolumeControl(),
                            if (track.bvid.startsWith('BV'))
                              IconButton(
                                tooltip: '在浏览器打开',
                                visualDensity: VisualDensity.compact,
                                iconSize: 18,
                                onPressed: () => launchUrlString(
                                    'https://www.bilibili.com/video/${track.bvid}'),
                                icon: const Icon(Icons.open_in_new),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _qualityTip(CurrentTrack track) {
    final q = track.quality;
    if (q.isLossless) return 'FLAC 无损 / Hi-Res 音轨';
    if (q.isDolby) return '杜比全景声音轨';
    return '${q.qualityLabel} AAC 有损压缩音轨（B站分级：64K<132K<192K）';
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  IconData _modeIcon(PlayMode mode) => switch (mode) {
        PlayMode.sequence => Icons.repeat,
        PlayMode.single => Icons.repeat_one,
        PlayMode.shuffle => Icons.shuffle,
      };

  String _modeLabel(PlayMode mode) => switch (mode) {
        PlayMode.sequence => '顺序播放',
        PlayMode.single => '单曲循环',
        PlayMode.shuffle => '随机播放',
      };

  /// 点击封面：全屏播放页以底部滑入方式展开。
  void _openFullPlayer(BuildContext context) {
    Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 320),
      reverseTransitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (context, anim, secondary) => const _FullPlayerRoute(),
      transitionsBuilder: (context, anim, secondary, child) {
        final curved =
            CurvedAnimation(parent: anim, curve: const Cubic(.2, .9, .3, 1.15));
        return SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero)
              .animate(curved),
          child: FadeTransition(opacity: curved, child: child),
        );
      },
    ));
  }

  void _openQueueSheet(BuildContext context, PlayerService player) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StreamBuilder<List<QueueItem>>(
        stream: player.queueStream,
        initialData: player.queue,
        builder: (context, snap) {
          final queue = snap.data ?? const <QueueItem>[];
          if (queue.isEmpty) {
            return const SizedBox(
                height: 160, child: Center(child: Text('播放队列为空')));
          }
          return ListView.builder(
            itemCount: queue.length,
            itemBuilder: (context, i) {
              final item = queue[i];
              final current = i == player.queueIndex;
              return ListTile(
                dense: true,
                selected: current,
                leading: current
                    ? const Icon(Icons.play_arrow, color: Color(0xFF2864F0))
                    : SizedBox(
                        width: 24,
                        child: Text('${i + 1}', textAlign: TextAlign.center)),
                title: Text(item.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(item.artist,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  tooltip: '移除',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => player.removeAt(i),
                ),
                onTap: () {
                  player.playAt(i);
                  Navigator.of(sheetContext).pop();
                },
              );
            },
          );
        },
      ),
    );
  }

  Widget _cover(String coverUrl) {
    if (coverUrl.startsWith('http')) {
      return CachedNetworkImage(
        imageUrl: coverUrl,
        width: 48,
        height: 48,
        fit: BoxFit.cover,
        httpHeaders: const {'Referer': kBiliReferer},
        errorWidget: (_, _, _) => _placeholder(),
      );
    }
    if (coverUrl.isNotEmpty && File(coverUrl).existsSync()) {
      return Image.file(File(coverUrl),
          width: 48, height: 48, fit: BoxFit.cover);
    }
    return _placeholder();
  }

  Widget _placeholder() => const SizedBox(
      width: 48, height: 48, child: Icon(Icons.music_note, size: 22));
}

/// 全屏播放页路由（自铺背景 + 返回栏）。
class _FullPlayerRoute extends StatelessWidget {
  const _FullPlayerRoute();

  @override
  Widget build(BuildContext context) {
    return TechBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: const Text('正在播放'),
        ),
        body: const PlayerPage(),
      ),
    );
  }
}

/// 音量控制：图标 + 窄滑杆。
class _VolumeControl extends ConsumerStatefulWidget {
  const _VolumeControl();

  @override
  ConsumerState<_VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends ConsumerState<_VolumeControl> {
  @override
  Widget build(BuildContext context) {
    final player = ref.read(playerServiceProvider);
    return StreamBuilder<double>(
      stream: player.volumeStream,
      initialData: 100,
      builder: (context, snap) {
        final v = (snap.data ?? 100).clamp(0.0, 100.0);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              v == 0
                  ? Icons.volume_off
                  : v < 50
                      ? Icons.volume_down
                      : Icons.volume_up,
              size: 20,
              color: Colors.grey[700],
            ),
            SizedBox(
              width: 80,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 5),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 10),
                ),
                child: Slider(
                  value: v / 100,
                  onChanged: (nv) => player.setVolume(nv * 100),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
