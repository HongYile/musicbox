import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../services/player/player_service.dart';
import '../services/sources/bilibili/api/client.dart';
import '../services/sources/bilibili/models.dart';
import '../widgets/add_to_playlist_dialog.dart';
import '../widgets/eq_bars.dart';
import '../widgets/glass_card.dart';
import '../widgets/quality_badge.dart';
import '../widgets/tech_background.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// 分P/列表型稿件的曲目列表页。
///
/// 交互模型：点击曲目（或右侧播放键）立即播放并回到播放页；
/// 「+」加入播放队列；下载/加入歌单收在「···」菜单。
///
/// [embedded] 为 true 时作为内嵌视图渲染（无自带 Scaffold/AppBar，
/// 顶部为返回行），用于搜索页内嵌打开——左侧导航栏与通栏播放器常驻。
class TrackListPage extends ConsumerStatefulWidget {
  const TrackListPage({
    super.key,
    required this.bvid,
    required this.title,
    required this.author,
    required this.cover,
    this.embedded = false,
    this.onBack,
  });

  final String bvid;
  final String title;
  final String author;
  final String cover;

  /// 内嵌模式：不铺 TechBackground/Scaffold，由调用方提供容器。
  final bool embedded;

  /// 内嵌模式的返回回调（整页 push 时为 null，用系统返回）。
  final VoidCallback? onBack;

  @override
  ConsumerState<TrackListPage> createState() => _TrackListPageState();
}

class _TrackListPageState extends ConsumerState<TrackListPage> {
  late final Future<List<BiliVideoPage>> _partsFuture =
      ref.read(biliApiProvider).pagelist(widget.bvid);

  String _trackTitle(BiliVideoPage p) =>
      p.part.isNotEmpty ? p.part : widget.title;

  QueueItem _queueItem(BiliVideoPage p) => QueueItem(
        bvid: widget.bvid,
        cid: p.cid,
        title: _trackTitle(p),
        artist: widget.author,
        coverUrl: widget.cover,
      );

  /// 点击单首：整个合集进队列，从该首开始连播（配合默认列表循环）。
  /// 同一首再点 = 暂停/继续。
  Future<void> _playOne(List<BiliVideoPage> parts, int index) async {
    final player = ref.read(playerServiceProvider);
    final p = parts[index];
    final cur = player.current;
    if (cur != null && cur.bvid == widget.bvid && cur.cid == p.cid) {
      await player.playOrPause();
      return;
    }
    try {
      // B站合集：默认列表循环（仅会话内，不覆盖用户记忆的模式）
      await player.playQueue([for (final x in parts) _queueItem(x)],
          startIndex: index, mode: PlayMode.loopAll);
    } catch (e) {
      _toast('播放失败: $e');
    }
  }

  Future<void> _playAll(List<BiliVideoPage> parts) async {
    try {
      await ref
          .read(playerServiceProvider)
          .playQueue([for (final p in parts) _queueItem(p)],
              mode: PlayMode.loopAll);
      _toast('开始播放全部（共 ${parts.length} 首）');
    } catch (e) {
      _toast('播放失败: $e');
    }
  }

  Future<void> _enqueueOne(BiliVideoPage p) async {
    await ref.read(playerServiceProvider).enqueue(_queueItem(p));
    _toast('已加入播放队列：${_trackTitle(p)}');
  }

  Future<void> _playNextOne(BiliVideoPage p) async {
    await ref.read(playerServiceProvider).playNext(_queueItem(p));
    _toast('将于下一首播放：${_trackTitle(p)}');
  }

  Future<void> _enqueueAll(List<BiliVideoPage> parts) async {
    await ref
        .read(playerServiceProvider)
        .enqueueAll([for (final p in parts) _queueItem(p)]);
    _toast('已把 ${parts.length} 首加入播放队列');
  }

  /// 全部收录到歌单（DB 级去重自动跳过已存在条目）。
  Future<void> _collectAll(List<BiliVideoPage> parts) async {
    final playlistId = await _pickPlaylist();
    if (playlistId == null) return;
    var added = 0, skipped = 0;
    final notifier = ref.read(playlistsProvider.notifier);
    for (final p in parts) {
      final ok = notifier.addTrack(
        playlistId: playlistId,
        sourceId: 'bilibili',
        trackId: widget.bvid,
        title: _trackTitle(p),
        artist: widget.author,
        cover: widget.cover,
        durationSec: p.durationSec,
        cid: p.cid,
      );
      ok ? added++ : skipped++;
    }
    _toast('已收录 $added 首${skipped > 0 ? '，$skipped 首已存在跳过' : ''}');
  }

  Future<int?> _pickPlaylist() async {
    final playlists = ref.read(playlistsProvider);
    return showDialog<int>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('全部收录到歌单'),
        children: [
          SimpleDialogOption(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              final name = await _askName();
              if (name == null || name.isEmpty) return;
              final id = ref.read(playlistsProvider.notifier).create(name);
              if (mounted) Navigator.of(context).pop(id);
            },
            child: const Row(children: [
              Icon(Icons.add),
              SizedBox(width: 8),
              Text('新建歌单'),
            ]),
          ),
          for (final p in playlists)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(p.id),
              child: Text('${p.name}（${p.trackCount} 首）'),
            ),
        ],
      ),
    );
  }

  Future<String?> _askName() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('新建歌单'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '歌单名称'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(c).pop(controller.text.trim()),
              child: const Text('创建')),
        ],
      ),
    );
  }

  Future<void> _download(BiliVideoPage p) async {
    try {
      await ref.read(downloadServiceProvider).downloadTrack(
            bvid: widget.bvid,
            cid: p.cid,
            title: _trackTitle(p),
            artist: widget.author,
            coverUrl: widget.cover,
          );
      _toast('下载完成：${_trackTitle(p)}');
    } catch (e) {
      _toast('下载失败: $e');
    }
  }

  void _toast(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = ref.watch(loginStateProvider).isLogin;
    final body = _buildBody(context, loggedIn);
    if (widget.embedded) return body;
    // push 路由会遮盖底层 TechBackground（opaque），本页需自铺背景。
    return TechBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: const Text('曲目列表'),
          actions: [
            IconButton(
              tooltip: '在浏览器打开',
              icon: const Icon(Icons.open_in_new),
              onPressed: () => launchUrlString(
                  'https://www.bilibili.com/video/${widget.bvid}'),
            ),
          ],
        ),
        body: body,
      ),
    );
  }

  Widget _buildBody(BuildContext context, bool loggedIn) {
    return Column(
      children: [
        if (widget.embedded)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 12, 0),
            child: Row(
              children: [
                IconButton(
                  tooltip: '返回',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: widget.onBack,
                ),
                Expanded(
                  child: Text('曲目列表',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                IconButton(
                  tooltip: '在浏览器打开',
                  icon: const Icon(Icons.open_in_new),
                  onPressed: () => launchUrlString(
                      'https://www.bilibili.com/video/${widget.bvid}'),
                ),
              ],
            ),
          ),
        Expanded(
          child: FutureBuilder<List<BiliVideoPage>>(
        future: _partsFuture,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('加载分P失败: ${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final parts = snap.data!;
          if (parts.isEmpty) return const Center(child: Text('该稿件没有分P'));
          return Column(
            children: [
              GlassCard(
                margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImage(
                      imageUrl: widget.cover,
                      width: 80,
                      height: 50,
                      fit: BoxFit.cover,
                      httpHeaders: const {'Referer': kBiliReferer},
                      errorWidget: (_, _, _) => const SizedBox(
                          width: 80, height: 50, child: Icon(Icons.music_note)),
                    ),
                  ),
                  title: Text(widget.title,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${widget.author} · 共 ${parts.length} 首'),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => _playAll(parts),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('播放全部'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _enqueueAll(parts),
                        icon: const Icon(Icons.playlist_play),
                        label: const Text('全部入队'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton(
                      onPressed: () => _collectAll(parts),
                      child: const Text('收录到歌单'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: parts.length,
                  itemBuilder: (context, i) {
                    final p = parts[i];
                    final current = ref.watch(currentTrackProvider).value;
                    final isPlaying = current != null &&
                        current.bvid == widget.bvid &&
                        current.cid == p.cid;
                    final playingNow = isPlaying &&
                        (ref.watch(playingProvider).value ?? false);
                    // 入场动画：逐条上浮淡入（间隔 30ms，回弹曲线）
                    return TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: 1),
                      duration: Duration(milliseconds: 260 + (i * 30).clamp(0, 450)),
                      curve: const Cubic(.2, .9, .3, 1.15),
                      builder: (context, t, child) => Opacity(
                        opacity: t.clamp(0.0, 1.0),
                        child: Transform.translate(
                            offset: Offset(0, 14 * (1 - t)), child: child),
                      ),
                      child: _TrackRow(
                        index: i,
                        bvid: widget.bvid,
                        page: p,
                        title: _trackTitle(p),
                        showBadge: loggedIn,
                        isPlaying: isPlaying,
                        playingNow: playingNow,
                        onPlay: () => _playOne(parts, i),
                        onPlayNext: () => _playNextOne(p),
                        onEnqueue: () => _enqueueOne(p),
                        onDownload: () => _download(p),
                        onAddToPlaylist: () => showAddToPlaylistDialog(
                          context,
                          ref,
                          trackId: widget.bvid,
                          title: _trackTitle(p),
                          artist: widget.author,
                          cover: widget.cover,
                          durationSec: p.durationSec,
                          cid: p.cid,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
          ),
        ),
      ],
    );
  }
}

/// 单行曲目：序号 / 标题 / 时长+徽章 / 播放键 / 入队 / 更多（下载·歌单）。
class _TrackRow extends ConsumerWidget {
  const _TrackRow({
    required this.index,
    required this.bvid,
    required this.page,
    required this.title,
    required this.showBadge,
    required this.isPlaying,
    required this.playingNow,
    required this.onPlay,
    required this.onPlayNext,
    required this.onEnqueue,
    required this.onDownload,
    required this.onAddToPlaylist,
  });

  final int index;
  final String bvid;
  final BiliVideoPage page;
  final String title;
  final bool showBadge;
  final bool isPlaying;
  final bool playingNow;
  final VoidCallback onPlay;
  final VoidCallback onPlayNext;
  final VoidCallback onEnqueue;
  final VoidCallback onDownload;
  final VoidCallback onAddToPlaylist;

  void _showMenu(BuildContext context, Offset position) async {
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          position.dx, position.dy, position.dx, position.dy),
      items: const [
        PopupMenuItem(value: 'playNext', child: Text('下一首播放')),
        PopupMenuItem(value: 'enqueue', child: Text('加入播放队列')),
        PopupMenuItem(value: 'playlist', child: Text('加入歌单')),
        PopupMenuItem(value: 'download', child: Text('下载（最优音质）')),
      ],
    );
    switch (v) {
      case 'playNext':
        onPlayNext();
      case 'enqueue':
        onEnqueue();
      case 'download':
        onDownload();
      case 'playlist':
        onAddToPlaylist();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final primary = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      // 鼠标右键 → 完整操作菜单
      onSecondaryTapDown: (d) => _showMenu(context, d.globalPosition),
      child: ListTile(
      dense: true,
      selected: isPlaying,
      leading: isPlaying
          ? EqBars(animate: playingNow)
          : SizedBox(
              width: 28,
              child: Text('${index + 1}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey))),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: isPlaying
            ? TextStyle(color: primary, fontWeight: FontWeight.w600)
            : null,
      ),
      subtitle: Row(
        children: [
          Text(formatDuration(page.durationSec)),
          const SizedBox(width: 8),
          if (showBadge) _ProbeBadge(bvid: bvid, cid: page.cid),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '立即播放',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.play_circle_outline, size: 22),
            onPressed: onPlay,
          ),
          IconButton(
            tooltip: '加入播放队列',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.playlist_add, size: 20),
            onPressed: onEnqueue,
          ),
          IconButton(
            tooltip: '更多',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.more_horiz, size: 20),
            onPressed: () {
              final box = context.findRenderObject() as RenderBox?;
              final pos = box?.localToGlobal(
                  Offset((box.size.width) - 36, 30)) ??
                  Offset.zero;
              _showMenu(context, pos);
            },
          ),
        ],
      ),
      onTap: onPlay,
      ),
    );
  }
}

/// 单条目的 Hi-Res 探测徽章：异步探测完成后显示，未知/无权限不显示。
class _ProbeBadge extends ConsumerWidget {
  const _ProbeBadge({required this.bvid, required this.cid});

  final String bvid;
  final int cid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final probe = ref.watch(hiResProbeProvider);
    final hit = probe.cached(bvid, cid);
    if (hit != null) return QualityBadge(choice: hit, compact: true);
    return FutureBuilder(
      future: probe.probe(bvid, cid),
      builder: (context, snap) {
        final choice = snap.data;
        if (choice == null) return const SizedBox.shrink();
        return QualityBadge(choice: choice, compact: true);
      },
    );
  }
}
