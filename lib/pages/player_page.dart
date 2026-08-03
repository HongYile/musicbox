import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../providers.dart';
import '../services/lyrics/lrc_parser.dart';
import '../services/lyrics/t2s.dart';
import '../services/player/player_service.dart';
import '../services/sources/bilibili/api/client.dart';
import '../widgets/add_to_playlist_dialog.dart';
import '../widgets/comments_panel.dart';
import '../widgets/quality_badge.dart';
import '../widgets/source_audition_sheet.dart';

/// 全屏播放页。
///
/// 布局参照主流音乐软件：左侧封面（保留原始宽高比）+ 曲目信息，
/// 右侧歌词/评论二选一面板（上下渐变遮罩，滚动条隐藏）；
/// 窄窗口退化为上下结构。背景 = 封面放大高斯模糊的环境层。
class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key});

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage>
    with SingleTickerProviderStateMixin {
  /// 右侧面板：0 歌词 / 1 评论。
  int _panelTab = 0;
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

  /// 曲目变化时拉取歌词（LRCLib，与音源解耦），统一转为简体中文。
  Future<void> _loadLyrics(CurrentTrack track) async {
    final key = '${track.bvid}:${track.cid}:${track.title}';
    if (key == _lyricKey) return;
    _lyricKey = key;
    final raw = await ref
        .read(lrclibServiceProvider)
        .fetchLyric(track: track.title, artist: track.artist);
    await T2s.ensureLoaded();
    if (!mounted || key != _lyricKey) return;
    setState(() {
      _lyricLines = raw == null ? const [] : parseLrc(T2s.convert(raw));
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
        PlayMode.loopAll => Icons.repeat,
        PlayMode.sequence => Icons.arrow_right_alt,
        PlayMode.single => Icons.repeat_one,
        PlayMode.shuffle => Icons.shuffle,
      };

  String _modeLabel(PlayMode mode) => switch (mode) {
        PlayMode.loopAll => '列表循环',
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
    final mode = ref.watch(playModeProvider).value ?? PlayMode.loopAll;
    final player = ref.read(playerServiceProvider);

    _loadLyrics(track);

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
              final wide = constraints.maxWidth >= 760;
              return Padding(
                padding: const EdgeInsets.fromLTRB(28, 4, 28, 20),
                child: wide
                    ? _wideLayout(constraints, track, playing, position)
                    : _narrowLayout(constraints, track, playing, position),
              );
            },
          ),
        ),
        // 底部控制区覆盖在最下（两种布局共用，由各自 Column 排布）
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final maxMs = duration.inMilliseconds.toDouble();
              final curMs = position.inMilliseconds
                  .toDouble()
                  .clamp(0, maxMs > 0 ? maxMs : 1);
              return Padding(
                padding: const EdgeInsets.fromLTRB(28, 4, 28, 20),
                child: Column(
                  children: [
                    const Spacer(),
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
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Theme.of(context).colorScheme.primary,
                                Theme.of(context).colorScheme.secondary,
                              ],
                            ),
                            boxShadow: [
                              BoxShadow(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primary
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

  /// 宽屏：左封面信息列 + 右歌词/评论面板；底部控制由外层叠加。
  Widget _wideLayout(BoxConstraints constraints, CurrentTrack track,
      bool playing, Duration position) {
    final coverMax = math
        .min(constraints.maxWidth * 0.30, constraints.maxHeight * 0.42)
        .clamp(150.0, 300.0);
    // 底部控制区约占 150px，内容区扣掉它
    return Padding(
      padding: const EdgeInsets.only(bottom: 150),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: constraints.maxWidth * 0.38,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _glowCover(track.coverUrl, coverMax, playing),
                const SizedBox(height: 18),
                _trackMeta(track, alignCenter: true),
              ],
            ),
          ),
          const SizedBox(width: 20),
          Expanded(child: _panelWithTabs(track, position)),
        ],
      ),
    );
  }

  /// 窄屏：顶部封面行 + 下面板；底部控制由外层叠加。
  Widget _narrowLayout(BoxConstraints constraints, CurrentTrack track,
      bool playing, Duration position) {
    final coverMax =
        (constraints.maxHeight * 0.20).clamp(96.0, 150.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: 150),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Row(
            children: [
              _glowCover(track.coverUrl, coverMax, playing),
              const SizedBox(width: 16),
              Expanded(child: _trackMeta(track, alignCenter: false)),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(child: _panelWithTabs(track, position)),
        ],
      ),
    );
  }

  /// 封面（光晕呼吸 + 暂停缩小），保留原始宽高比。
  Widget _glowCover(String coverUrl, double maxSide, bool playing) {
    return AnimatedScale(
      scale: playing ? 1.0 : 0.96,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
      child: AnimatedBuilder(
        animation: _glow,
        builder: (context, child) {
          final t = _glow.value;
          final dark = Theme.of(context).brightness == Brightness.dark;
          final glowA =
              dark ? const Color(0xFFEC407A) : const Color(0xFF7C4DFF);
          final glowB =
              dark ? const Color(0xFF9C7CFF) : const Color(0xFFEC407A);
          return Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                    color: glowA.withValues(alpha: 0.28 + 0.18 * t),
                    blurRadius: 45,
                    spreadRadius: 2 + 3 * t,
                    offset: const Offset(-6, 10)),
                BoxShadow(
                    color: glowB.withValues(alpha: 0.28 + 0.18 * (1 - t)),
                    blurRadius: 45,
                    spreadRadius: 2 + 3 * (1 - t),
                    offset: const Offset(6, 10)),
              ],
            ),
            child: child,
          );
        },
        child: _coverNatural(coverUrl, maxSide),
      ),
    );
  }

  /// 原比例封面：以短边限制最大尺寸，不裁剪、不强制方形。
  Widget _coverNatural(String coverUrl, double maxSide) {
    Widget image;
    if (coverUrl.startsWith('http')) {
      image = CachedNetworkImage(
        imageUrl: coverUrl,
        fit: BoxFit.contain,
        httpHeaders: const {'Referer': kBiliReferer},
        errorWidget: (_, _, _) => _coverPlaceholder(maxSide),
      );
    } else if (coverUrl.isNotEmpty && File(coverUrl).existsSync()) {
      image = Image.file(File(coverUrl), fit: BoxFit.contain);
    } else {
      image = _coverPlaceholder(maxSide);
    }
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxSide, maxHeight: maxSide),
      child: ClipRRect(borderRadius: BorderRadius.circular(16), child: image),
    );
  }

  Widget _coverPlaceholder(double size) => SizedBox(
      width: size,
      height: size,
      child: Icon(Icons.music_note, size: size / 3));

  /// 标题/歌手/徽章/操作按钮。
  Widget _trackMeta(CurrentTrack track, {required bool alignCenter}) {
    final align =
        alignCenter ? CrossAxisAlignment.center : CrossAxisAlignment.start;
    final textAlign = alignCenter ? TextAlign.center : TextAlign.start;
    return Column(
      crossAxisAlignment: align,
      children: [
        Text(track.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: textAlign,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(track.artist, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 10),
        Tooltip(
          message: _qualityTip(track),
          child: QualityBadge(choice: track.quality),
        ),
        Row(
          mainAxisAlignment: alignCenter
              ? MainAxisAlignment.center
              : MainAxisAlignment.start,
          children: [
            IconButton(
              tooltip: '换源试听',
              icon: const Icon(Icons.find_replace),
              onPressed: () => SourceAuditionSheet.show(context),
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
      ],
    );
  }

  /// 歌词/评论二选一面板：顶部切换 + 上下渐变遮罩 + 隐藏滚动条。
  Widget _panelWithTabs(CurrentTrack track, Duration position) {
    return Column(
      children: [
        SegmentedButton<int>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 0, label: Text('歌词')),
            ButtonSegment(value: 1, label: Text('评论')),
          ],
          selected: {_panelTab},
          onSelectionChanged: (s) => setState(() => _panelTab = s.first),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ShaderMask(
            // 上渐隐 → 中间实 → 下渐隐
            shaderCallback: (rect) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.black,
                Colors.black,
                Colors.transparent,
              ],
              stops: [0.0, 0.07, 0.93, 1.0],
            ).createShader(rect),
            blendMode: BlendMode.dstIn,
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context)
                  .copyWith(scrollbars: false),
              child: _panelTab == 0
                  ? _lyricsView(position)
                  : CommentsPanel(
                      key: ValueKey('${track.bvid}:${track.cid}'),
                      track: track),
            ),
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

  Widget _lyricsView(Duration position) {
    if (_lyricLines.isEmpty) {
      return const Center(
          child: Text('暂无歌词 / 纯音乐，请欣赏',
              style: TextStyle(color: Colors.grey)));
    }
    final current = lrcCurrentIndex(_lyricLines, position);
    return LayoutBuilder(
      builder: (context, constraints) {
        // 上下各垫半屏：第一行起始即在中间，歌词自下而上升起（QQ音乐式）。
        final pad = (constraints.maxHeight / 2 - 20)
            .clamp(0.0, double.infinity);
        if (_lyricScroll.hasClients && current >= 0) {
          final target = current * 40.0;
          if ((_lyricScroll.offset - target).abs() > 40) {
            _lyricScroll.animateTo(target,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut);
          }
        }
        return ListView.builder(
          controller: _lyricScroll,
          padding: EdgeInsets.symmetric(vertical: pad),
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
                  fontWeight:
                      isCurrent ? FontWeight.bold : FontWeight.normal,
                  color: isCurrent
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey,
                ),
              ),
            );
          },
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
