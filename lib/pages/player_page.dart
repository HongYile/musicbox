import 'dart:io';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../providers.dart';
import '../services/lyrics/lrc_parser.dart';
import '../services/player/player_service.dart';
import '../services/sources/bilibili/api/client.dart';
import '../widgets/add_to_playlist_dialog.dart';
import '../widgets/quality_badge.dart';
import '../widgets/source_audition_sheet.dart';

/// 全屏播放页。
///
/// 背景 = 封面放大高斯模糊的环境层（切歌交叉渐变）——主流音乐软件的
/// "灵动"招牌效果；内容弹性布局，任何窗口高度都不出现滚动条。
class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key});

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage>
    with SingleTickerProviderStateMixin {
  bool _showLyrics = false;
  List<LrcLine> _lyricLines = const [];
  String _lyricKey = '';
  final _lyricScroll = ScrollController();

  /// 进度条拖动中的暂存值（0-1）；松手才 seek，避免拖动中实时跳转。
  double? _dragValue;

  /// 封面光晕呼吸动画。
  late final AnimationController _glow = AnimationController(
      vsync: this, duration: const Duration(seconds: 3))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _glow.dispose();
    _lyricScroll.dispose();
    super.dispose();
  }

  /// 曲目变化时拉取歌词（LRCLib，与音源解耦）。
  Future<void> _loadLyrics(CurrentTrack track) async {
    final key = '${track.bvid}:${track.cid}:${track.title}';
    if (key == _lyricKey) return;
    _lyricKey = key;
    final raw = await ref
        .read(lrclibServiceProvider)
        .fetchLyric(track: track.title, artist: track.artist);
    if (!mounted || key != _lyricKey) return;
    setState(() {
      _lyricLines = raw == null ? const [] : parseLrc(raw);
    });
    if (_lyricScroll.hasClients) _lyricScroll.jumpTo(0);
  }

  Future<void> _download(CurrentTrack track) async {
    try {
      await ref.read(downloadServiceProvider).downloadTrack(
            bvid: track.bvid,
            cid: track.cid,
            title: track.title,
            artist: track.artist,
            coverUrl: track.coverUrl,
          );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('下载完成')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('下载失败: $e')));
      }
    }
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

  @override
  Widget build(BuildContext context) {
    final trackAsync = ref.watch(currentTrackProvider);
    final track = trackAsync.value ?? ref.read(playerServiceProvider).current;

    if (track == null) {
      return const Center(child: Text('还没有播放内容，去搜索页选一首吧'));
    }

    final position = ref.watch(positionProvider).value ?? Duration.zero;
    final duration = ref.watch(durationProvider).value ?? Duration.zero;
    final playing = ref.watch(playingProvider).value ?? false;
    final mode = ref.watch(playModeProvider).value ?? PlayMode.sequence;
    final player = ref.read(playerServiceProvider);

    _loadLyrics(track);

    final maxMs = duration.inMilliseconds.toDouble();
    final curMs =
        position.inMilliseconds.toDouble().clamp(0, maxMs > 0 ? maxMs : 1);

    return Stack(
      children: [
        // 封面模糊环境背景（切歌交叉渐变）
        Positioned.fill(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 600),
            child: KeyedSubtree(
              key: ValueKey(track.coverUrl),
              child: _BlurBackdrop(coverUrl: track.coverUrl),
            ),
          ),
        ),
        // 内容层
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final coverSize =
                  (constraints.maxHeight * 0.34).clamp(150.0, 240.0);
              return Padding(
                padding: const EdgeInsets.fromLTRB(28, 4, 28, 20),
                child: Column(
                  children: [
                    const Spacer(flex: 2),
                    // 封面（光晕呼吸 + 暂停缩小）
                    AnimatedScale(
                      scale: playing ? 1.0 : 0.94,
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeOut,
                      child: AnimatedBuilder(
                        animation: _glow,
                        builder: (context, child) {
                          final t = _glow.value;
                          return Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                    color: const Color(0xFF3CCBD9)
                                        .withValues(alpha: 0.28 + 0.18 * t),
                                    blurRadius: 45,
                                    spreadRadius: 2 + 3 * t,
                                    offset: const Offset(-6, 10)),
                                BoxShadow(
                                    color: const Color(0xFF2864F0)
                                        .withValues(
                                            alpha: 0.28 + 0.18 * (1 - t)),
                                    blurRadius: 45,
                                    spreadRadius: 2 + 3 * (1 - t),
                                    offset: const Offset(6, 10)),
                              ],
                            ),
                            child: child,
                          );
                        },
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: _cover(track.coverUrl, coverSize),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(track.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(track.artist,
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Tooltip(
                          message: _qualityTip(track),
                          child: QualityBadge(choice: track.quality),
                        ),
                      ],
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          tooltip: '换源试听',
                          icon: const Icon(Icons.find_replace),
                          onPressed: () => SourceAuditionSheet.show(context),
                        ),
                        IconButton(
                          tooltip: _showLyrics ? '隐藏歌词' : '显示歌词',
                          icon: Icon(_showLyrics
                              ? Icons.lyrics
                              : Icons.lyrics_outlined),
                          color: _showLyrics
                              ? Theme.of(context).colorScheme.primary
                              : null,
                          onPressed: () =>
                              setState(() => _showLyrics = !_showLyrics),
                        ),
                        if (track.bvid.startsWith('BV'))
                          IconButton(
                            tooltip: '在浏览器打开',
                            icon: const Icon(Icons.open_in_new),
                            onPressed: () => launchUrlString(
                                'https://www.bilibili.com/video/${track.bvid}'),
                          ),
                        if (track.bvid.isNotEmpty) ...[
                          IconButton(
                            tooltip: '加入歌单',
                            icon: const Icon(Icons.playlist_add),
                            onPressed: () => showAddToPlaylistDialog(
                              context,
                              ref,
                              trackId: track.bvid,
                              title: track.title,
                              artist: track.artist,
                              cover: track.coverUrl,
                              cid: track.cid,
                            ),
                          ),
                          IconButton(
                            tooltip: '下载（最优音质原始流）',
                            icon: const Icon(Icons.download),
                            onPressed: () => _download(track),
                          ),
                        ],
                      ],
                    ),
                    // 歌词（显示时替换留白区，不撑爆布局）
                    if (_showLyrics)
                      Expanded(child: _lyricsView(position))
                    else
                      const Spacer(flex: 3),
                    Slider(
                      value: _dragValue ?? (maxMs > 0 ? curMs / maxMs : 0),
                      onChanged: (v) => setState(() => _dragValue = v),
                      onChangeEnd: (v) {
                        player.seek(
                            Duration(milliseconds: (v * maxMs).round()));
                        setState(() => _dragValue = null);
                      },
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                            formatDuration(_dragValue != null
                                ? (_dragValue! * maxMs / 1000).round()
                                : position.inSeconds),
                            style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.color)),
                        Text(formatDuration(duration.inSeconds),
                            style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.color)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          tooltip: _modeLabel(mode),
                          onPressed: () => player.cycleMode(),
                          icon: Icon(_modeIcon(mode)),
                        ),
                        IconButton(
                          tooltip: '上一首',
                          iconSize: 32,
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
                                      .withValues(alpha: 0.40),
                                  blurRadius: 20,
                                  offset: const Offset(0, 8)),
                            ],
                          ),
                          child: IconButton(
                            iconSize: 40,
                            color: Colors.white,
                            onPressed: player.playOrPause,
                            icon: Icon(
                                playing ? Icons.pause : Icons.play_arrow),
                          ),
                        ),
                        IconButton(
                          tooltip: '下一首',
                          iconSize: 32,
                          onPressed: player.next,
                          icon: const Icon(Icons.skip_next),
                        ),
                        IconButton(
                          tooltip: '播放队列',
                          onPressed: () => _openQueueSheet(player),
                          icon: const Icon(Icons.queue_music),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  String _qualityTip(CurrentTrack track) {
    final q = track.quality;
    if (q.isLossless) return 'FLAC 无损 / Hi-Res 音轨';
    if (q.isDolby) return '杜比全景声音轨';
    return '${q.qualityLabel} AAC 有损压缩音轨（B站分级：64K<132K<192K）';
  }

  Widget _cover(String coverUrl, double size) {
    if (coverUrl.startsWith('http')) {
      return CachedNetworkImage(
        imageUrl: coverUrl,
        width: size,
        height: size,
        fit: BoxFit.cover,
        httpHeaders: const {'Referer': kBiliReferer},
        errorWidget: (_, _, _) => _coverPlaceholder(size),
      );
    }
    if (coverUrl.isNotEmpty && File(coverUrl).existsSync()) {
      return Image.file(File(coverUrl),
          width: size, height: size, fit: BoxFit.cover);
    }
    return _coverPlaceholder(size);
  }

  Widget _coverPlaceholder(double size) => SizedBox(
      width: size,
      height: size,
      child: Icon(Icons.music_note, size: size / 3));

  Widget _lyricsView(Duration position) {
    if (_lyricLines.isEmpty) {
      return const Center(
          child: Text('暂无歌词', style: TextStyle(color: Colors.grey)));
    }
    final current = lrcCurrentIndex(_lyricLines, position);
    if (_lyricScroll.hasClients && current >= 0) {
      final target = (current * 40.0 - 80).clamp(0.0, double.infinity);
      if ((_lyricScroll.offset - target).abs() > 40) {
        _lyricScroll.animateTo(target,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut);
      }
    }
    return ListView.builder(
      controller: _lyricScroll,
      itemExtent: 40,
      itemCount: _lyricLines.length,
      itemBuilder: (context, i) {
        final isCurrent = i == current;
        return Center(
          child: Text(
            _lyricLines[i].text.isEmpty ? '·' : _lyricLines[i].text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: isCurrent ? 15 : 13,
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              color: isCurrent
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey,
            ),
          ),
        );
      },
    );
  }

  void _openQueueSheet(PlayerService player) {
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
}

/// 封面取色模糊环境背景：封面放大铺满 → 50px 高斯模糊 → 白色渐变罩层。
class _BlurBackdrop extends StatelessWidget {
  const _BlurBackdrop({required this.coverUrl});

  final String coverUrl;

  @override
  Widget build(BuildContext context) {
    Widget image;
    if (coverUrl.startsWith('http')) {
      image = CachedNetworkImage(
        imageUrl: coverUrl,
        fit: BoxFit.cover,
        httpHeaders: const {'Referer': kBiliReferer},
        errorWidget: (_, _, _) => const SizedBox.expand(),
      );
    } else if (coverUrl.isNotEmpty && File(coverUrl).existsSync()) {
      image = Image.file(File(coverUrl), fit: BoxFit.cover);
    } else {
      image = const SizedBox.expand();
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
          child: image,
        ),
        // 罩层保证可读性（亮：白色渐变 / 暗：深黑渐变）
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: Theme.of(context).brightness == Brightness.dark
                  ? const [Color(0x99101014), Color(0xB3101014)]
                  : const [Color(0xB3FFFFFF), Color(0xCCFFFFFF)],
            ),
          ),
        ),
      ],
    );
  }
}
