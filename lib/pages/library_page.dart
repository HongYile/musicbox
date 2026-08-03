import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../services/library/library_db.dart';
import '../services/player/player_service.dart';
import '../services/sources/bilibili/api/client.dart';
import '../services/sources/bilibili/stream_select.dart';
import '../widgets/add_to_playlist_dialog.dart';
import '../widgets/eq_bars.dart';

/// 曲库页：本地歌单 + 下载两个 tab。
///
/// 歌单详情采用内嵌视图切换（不整页 push），保持左侧导航栏与
/// 底部通栏播放器常驻——常规桌面播放器的结构。
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  (int, String)? _open; // (playlistId, name)

  @override
  Widget build(BuildContext context) {
    final open = _open;
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(tabs: [Tab(text: '歌单'), Tab(text: '下载')]),
          Expanded(
            child: TabBarView(
              physics: open == null
                  ? null
                  : const NeverScrollableScrollPhysics(),
              children: [
                open == null
                    ? _PlaylistsTab(onOpen: (id, name) =>
                        setState(() => _open = (id, name)))
                    : PlaylistDetailView(
                        playlistId: open.$1,
                        name: open.$2,
                        onBack: () => setState(() => _open = null),
                      ),
                _DownloadsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaylistsTab extends ConsumerWidget {
  const _PlaylistsTab({required this.onOpen});

  final void Function(int id, String name) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistsProvider);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: playlists.isEmpty
          ? const Center(child: Text('还没有歌单，点右下角新建'))
          : ListView.builder(
              itemCount: playlists.length,
              itemBuilder: (context, i) {
                final p = playlists[i];
                return ListTile(
                  leading: const Icon(Icons.queue_music),
                  title: Text(p.name),
                  subtitle: Text('${p.trackCount} 首'),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'delete') {
                        ref.read(playlistsProvider.notifier).delete(p.id);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'delete', child: Text('删除歌单')),
                    ],
                  ),
                  onTap: () => onOpen(p.id, p.name),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.small(
        tooltip: '新建歌单',
        onPressed: () async {
          final name = await askPlaylistName(context);
          if (name != null && name.isNotEmpty) {
            ref.read(playlistsProvider.notifier).create(name);
          }
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// 歌单详情（内嵌视图）：曲目列表，点击播放/暂停切换，支持下载/移除。
class PlaylistDetailView extends ConsumerStatefulWidget {
  const PlaylistDetailView({
    super.key,
    required this.playlistId,
    required this.name,
    required this.onBack,
  });

  final int playlistId;
  final String name;
  final VoidCallback onBack;

  @override
  ConsumerState<PlaylistDetailView> createState() => _PlaylistDetailViewState();
}

class _PlaylistDetailViewState extends ConsumerState<PlaylistDetailView> {
  bool _starting = false;

  /// 组装播放队列：分源处理——B站 cid=0 的条目先经 pagelist 解析；
  /// QQ/网易云直接用各自 id，不查 pagelist（否则 B站 API 报 -400）。
  Future<List<QueueItem>> _buildQueue(List<PlaylistTrack> tracks) async {
    final api = ref.read(biliApiProvider);
    final items = <QueueItem>[];
    for (final t in tracks) {
      if (t.sourceId == 'bilibili') {
        var cid = t.cid;
        if (cid == 0) {
          final pages = await api.pagelist(t.trackId);
          if (pages.isEmpty) continue; // 无分 P 的跳过
          cid = pages.first.cid;
        }
        items.add(QueueItem(
          bvid: t.trackId,
          cid: cid,
          title: t.title,
          artist: t.artist,
          coverUrl: t.cover,
        ));
      } else {
        items.add(QueueItem(
          bvid: t.trackId,
          cid: 0,
          title: t.title,
          artist: t.artist,
          coverUrl: t.cover,
          sourceId: t.sourceId, // qqmusic / netease 原样进队列
        ));
      }
    }
    return items;
  }

  Future<void> _playAll(List<PlaylistTrack> tracks, int startIndex) async {
    setState(() => _starting = true);
    try {
      final items = await _buildQueue(tracks);
      if (items.isEmpty) throw StateError('歌单里没有可播放的曲目');
      // startIndex 可能因跳过无效曲目而偏移，按 bvid 重新定位
      final target = tracks[startIndex].trackId;
      var index = items.indexWhere((e) => e.bvid == target);
      if (index < 0) index = 0;
      await ref.read(playerServiceProvider).playQueue(items, startIndex: index);
      
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('播放失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _download(PlaylistTrack t) async {
    try {
      var cid = t.cid;
      if (cid == 0) {
        final pages = await ref.read(biliApiProvider).pagelist(t.trackId);
        if (pages.isEmpty) throw StateError('该稿件没有分 P');
        cid = pages.first.cid;
      }
      await ref.read(downloadsProvider.notifier).start(
            bvid: t.trackId,
            cid: cid,
            title: t.title,
            artist: t.artist,
            coverUrl: t.cover,
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

  @override
  Widget build(BuildContext context) {
    final tracksAsync = ref.watch(playlistTracksProvider(widget.playlistId));
    final current = ref.watch(currentTrackProvider).value;
    final playingNow = ref.watch(playingProvider).value ?? false;
    return Column(
      children: [
        // 内嵌头部（不整页 push，导航栏/通栏播放器常驻）
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
                child: Text(widget.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              if (_starting)
                const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
              else
                IconButton(
                  tooltip: '播放全部',
                  icon: const Icon(Icons.play_arrow),
                  onPressed: () {
                    final tracks = tracksAsync.value;
                    if (tracks != null && tracks.isNotEmpty) {
                      _playAll(tracks, 0);
                    }
                  },
                ),
            ],
          ),
        ),
        Expanded(
          child: tracksAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('加载失败: $e')),
            data: (tracks) => tracks.isEmpty
                ? const Center(child: Text('歌单为空'))
                : ListView.builder(
                    itemCount: tracks.length,
                    itemBuilder: (context, i) {
                      final t = tracks[i];
                      final isCurrent = current != null &&
                          current.bvid == t.trackId &&
                          (t.cid == 0 || current.cid == t.cid);
                      return ListTile(
                        selected: isCurrent,
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: SizedBox(
                            width: 64,
                            height: 40,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                CachedNetworkImage(
                                  imageUrl: t.cover,
                                  fit: BoxFit.cover,
                                  httpHeaders: const {'Referer': kBiliReferer},
                                  placeholder: (_, _) =>
                                      const ColoredBox(color: Colors.black12),
                                  errorWidget: (_, _, _) => const Center(
                                      child: Icon(Icons.music_note)),
                                ),
                                // 播放中：封面叠加半透明层 + 白色跳动均衡器
                                if (isCurrent)
                                  ColoredBox(
                                    color: Colors.black.withValues(alpha: 0.45),
                                    child: Center(
                                      child: EqBars(
                                        color: Colors.white,
                                        size: 20,
                                        animate: playingNow,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        title: Text(
                          t.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: isCurrent
                              ? TextStyle(
                                  color:
                                      Theme.of(context).colorScheme.primary,
                                  fontWeight: FontWeight.w600)
                              : null,
                        ),
                        subtitle: Text(
                            '${t.artist} · ${formatDuration(t.durationSec)}'),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) async {
                            switch (v) {
                              case 'download':
                                await _download(t);
                              case 'remove':
                                ref.read(libraryDbProvider).removeTrack(t.id);
                                ref.invalidate(
                                    playlistTracksProvider(widget.playlistId));
                                ref.read(playlistsProvider.notifier).refresh();
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'download', child: Text('下载')),
                            PopupMenuItem(
                                value: 'remove', child: Text('从歌单移除')),
                          ],
                        ),
                        // 同一首再点 = 暂停/继续；点其他 = 从该首开始连播
                        onTap: () {
                          if (isCurrent) {
                            ref.read(playerServiceProvider).playOrPause();
                          } else {
                            _playAll(tracks, i);
                          }
                        },
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

class _DownloadsTab extends ConsumerWidget {
  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var v = bytes.toDouble();
    var u = 0;
    while (v >= 1024 && u < units.length - 1) {
      v /= 1024;
      u++;
    }
    return '${v.toStringAsFixed(v >= 100 || u == 0 ? 0 : 1)} ${units[u]}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(downloadsProvider);
    if (state.entries.isEmpty && state.progress.isEmpty) {
      return const Center(child: Text('还没有下载，去歌单或播放页下载吧'));
    }
    return ListView.builder(
      itemCount: state.entries.length,
      itemBuilder: (context, i) {
        final e = state.entries[i];
        final progress = state.progress[e.trackId];
        final label = kAudioQualityLabels[e.quality] ?? '${e.quality}';
        final (statusText, statusColor) = switch (e.status) {
          DownloadStatus.downloading => ('下载中', Colors.blue),
          DownloadStatus.completed => ('已完成', Colors.green),
          _ => ('失败', Colors.red),
        };
        return ListTile(
          leading: e.coverPath.isNotEmpty && File(e.coverPath).existsSync()
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.file(File(e.coverPath),
                      width: 64, height: 40, fit: BoxFit.cover),
                )
              : const SizedBox(
                  width: 64, height: 40, child: Icon(Icons.music_note)),
          title: Text(e.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$label · ${_formatBytes(e.size)} · $statusText',
                  style: TextStyle(color: statusColor, fontSize: 12)),
              if (progress != null)
                LinearProgressIndicator(value: progress.ratio),
            ],
          ),
          onTap: e.status == DownloadStatus.completed
              ? () async {
                  if (!File(e.filePath).existsSync()) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('文件已被移动或删除')));
                    return;
                  }
                  await ref.read(playerServiceProvider).playLocalFile(
                        filePath: e.filePath,
                        title: e.title,
                        coverPath: e.coverPath,
                        qualityId: e.quality,
                      );
                  
                }
              : null,
        );
      },
    );
  }
}
