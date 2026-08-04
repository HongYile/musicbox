import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../services/library/library_db.dart';
import '../services/player/player_service.dart';
import '../services/sources/bilibili/api/client.dart';
import '../services/sources/bilibili/stream_select.dart';
import '../services/sources/qqmusic/api/qq_endpoints.dart';
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
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(44),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              const Spacer(),
              TextButton.icon(
                onPressed: () => showQqImportSheet(context, ref),
                icon: const Icon(Icons.download_for_offline, size: 18),
                label: const Text('导入 QQ 歌单'),
              ),
            ],
          ),
        ),
      ),
      body: playlists.isEmpty
          ? const Center(child: Text('还没有歌单，点右下角新建'))
          : ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: playlists.length,
              onReorderItem: (oldIndex, newIndex) {
                // onReorderItem 的 newIndex 已按移除 oldIndex 调整过
                final ids = playlists.map((p) => p.id).toList();
                ids.insert(newIndex, ids.removeAt(oldIndex));
                ref.read(playlistsProvider.notifier).reorder(ids);
              },
              itemBuilder: (context, i) {
                final p = playlists[i];
                return ListTile(
                  key: ValueKey(p.id),
                  leading: ReorderableDragStartListener(
                    index: i,
                    child: const Icon(Icons.drag_indicator),
                  ),
                  title: Text(p.name),
                  subtitle: Text('${p.trackCount} 首'),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) async {
                      if (v == 'rename') {
                        final name = await _askRename(context, p.name);
                        if (name != null && name.isNotEmpty) {
                          ref.read(playlistsProvider.notifier).rename(p.id, name);
                        }
                      } else if (v == 'delete') {
                        ref.read(playlistsProvider.notifier).delete(p.id);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rename', child: Text('重命名')),
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

/// 重命名歌单对话框（带初始值）。
Future<String?> _askRename(BuildContext context, String current) async {
  final controller = TextEditingController(text: current);
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('重命名歌单'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: '歌单名称'),
        onSubmitted: (v) => Navigator.of(dialogContext).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(controller.text.trim()),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
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
  ///
  /// 单首解析失败（脏数据/已失效稿件）只跳过并计数，不拖垮整个队列。
  Future<(List<QueueItem>, int)> _buildQueue(List<PlaylistTrack> tracks) async {
    final api = ref.read(biliApiProvider);
    final items = <QueueItem>[];
    var skipped = 0;
    for (final t in tracks) {
      try {
        if (t.sourceId == 'bilibili') {
          var cid = t.cid;
          if (cid == 0) {
            final pages = await api.pagelist(t.trackId);
            if (pages.isEmpty) {
              skipped++;
              continue; // 无分 P 的跳过
            }
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
      } catch (e) {
        // 单首失败跳过（如 trackId 无效的脏数据），不中断整个歌单
        skipped++;
        debugPrint('跳过无法解析的曲目: ${t.title} (${t.sourceId}:${t.trackId}) $e');
      }
    }
    return (items, skipped);
  }

  Future<void> _playAll(List<PlaylistTrack> tracks, int startIndex) async {
    setState(() => _starting = true);
    try {
      final (items, skipped) = await _buildQueue(tracks);
      if (items.isEmpty) throw StateError('歌单里没有可播放的曲目');
      // startIndex 可能因跳过无效曲目而偏移，按 bvid 重新定位
      final target = tracks[startIndex].trackId;
      var index = items.indexWhere((e) => e.bvid == target);
      if (index < 0) index = 0;
      // 自己的歌单：恢复用户记忆的播放模式（合集强制循环只是会话级的）
      final savedMode = await readSavedPlayMode();
      if (!mounted) return;
      await ref
          .read(playerServiceProvider)
          .playQueue(items, startIndex: index, mode: savedMode);
      if (skipped > 0 && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已跳过 $skipped 首无法解析的曲目')));
      }
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
                      return GestureDetector(
                        // 鼠标右键 → 同"…"菜单（QQ音乐桌面端交互）
                        onSecondaryTapDown: (d) =>
                            _showTrackMenu(t, tracks, i, d.globalPosition),
                        child: ListTile(
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
                        trailing: IconButton(
                          tooltip: '更多',
                          icon: const Icon(Icons.more_horiz),
                          onPressed: () {
                            final box = context.findRenderObject() as RenderBox?;
                            final pos = box?.localToGlobal(
                                    Offset(box.size.width - 40, 24)) ??
                                Offset.zero;
                            _showTrackMenu(t, tracks, i, pos);
                          },
                        ),
                        // 同一首再点 = 暂停/继续；点其他 = 从该首开始连播
                        onTap: () {
                          if (isCurrent) {
                            ref.read(playerServiceProvider).playOrPause();
                          } else {
                            _playAll(tracks, i);
                          }
                        },
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  /// 单首曲目 → 播放队列条目（B站 cid=0 的先经 pagelist 解析）。
  Future<QueueItem?> _queueItemOf(PlaylistTrack t) async {
    try {
      if (t.sourceId == 'bilibili') {
        var cid = t.cid;
        if (cid == 0) {
          final pages =
              await ref.read(biliApiProvider).pagelist(t.trackId);
          if (pages.isEmpty) return null;
          cid = pages.first.cid;
        }
        return QueueItem(
            bvid: t.trackId,
            cid: cid,
            title: t.title,
            artist: t.artist,
            coverUrl: t.cover);
      }
      return QueueItem(
          bvid: t.trackId,
          cid: 0,
          title: t.title,
          artist: t.artist,
          coverUrl: t.cover,
          sourceId: t.sourceId);
    } catch (_) {
      return null;
    }
  }

  /// 曲目操作菜单（"…"按钮与鼠标右键共用）：QQ音乐式完整操作集。
  Future<void> _showTrackMenu(PlaylistTrack t, List<PlaylistTrack> tracks,
      int index, Offset position) async {
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          position.dx, position.dy, position.dx, position.dy),
      items: const [
        PopupMenuItem(value: 'play', child: Text('播放')),
        PopupMenuItem(value: 'playNext', child: Text('下一首播放')),
        PopupMenuItem(value: 'collect', child: Text('收藏到其他歌单')),
        PopupMenuItem(value: 'download', child: Text('下载')),
        PopupMenuItem(value: 'remove', child: Text('从歌单移除')),
      ],
    );
    if (v == null || !mounted) return;
    switch (v) {
      case 'play':
        await _playAll(tracks, index);
      case 'playNext':
        final item = await _queueItemOf(t);
        if (item == null) {
          _toast('该曲目无法解析，可能已失效');
          return;
        }
        await ref.read(playerServiceProvider).playNext(item);
        _toast('将于下一首播放：${t.title}');
      case 'collect':
        await showAddToPlaylistDialog(
          context,
          ref,
          trackId: t.trackId,
          title: t.title,
          artist: t.artist,
          cover: t.cover,
          durationSec: t.durationSec,
          cid: t.cid,
          sourceId: t.sourceId,
        );
      case 'download':
        await _download(t);
      case 'remove':
        ref.read(libraryDbProvider).removeTrack(t.id);
        ref.invalidate(playlistTracksProvider(widget.playlistId));
        ref.read(playlistsProvider.notifier).refresh();
    }
  }

  void _toast(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
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

/// QQ 音乐歌单批量导入：列出用户自建歌单 → 选一个 → 全量导入为本地歌单。
Future<void> showQqImportSheet(BuildContext context, WidgetRef ref) async {
  final uin = await ref.read(qqAuthServiceProvider).uin();
  if (uin == '0' || uin.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先在「我的」页登录 QQ 音乐')));
    }
    return;
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => _QqImportSheet(uin: uin),
  );
}

class _QqImportSheet extends ConsumerStatefulWidget {
  const _QqImportSheet({required this.uin});

  final String uin;

  @override
  ConsumerState<_QqImportSheet> createState() => _QqImportSheetState();
}

class _QqImportSheetState extends ConsumerState<_QqImportSheet> {
  late final Future<List<QqPlaylistSummary>> _future = _load();
  String? _importing;

  Future<List<QqPlaylistSummary>> _load() =>
      ref.read(qqApiProvider).userPlaylists(widget.uin);

  Future<void> _import(QqPlaylistSummary p) async {
    setState(() => _importing = p.name);
    try {
      final tracks = await ref.read(qqApiProvider).playlistTracks(p.tid);
      if (tracks.isEmpty) throw StateError('歌单为空或不可访问');
      final playlistId =
          ref.read(playlistsProvider.notifier).create('QQ · ${p.name}');
      var added = 0;
      final notifier = ref.read(playlistsProvider.notifier);
      for (final s in tracks) {
        final ok = notifier.addTrack(
          playlistId: playlistId,
          sourceId: 'qqmusic',
          trackId: s.songMid,
          title: s.name,
          artist: s.singer,
          cover: s.coverUrl,
          durationSec: s.intervalSec,
          cid: 0,
        );
        if (ok) added++;
      }
      ref.read(playlistsProvider.notifier).refresh();
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('已导入「${p.name}」：$added/${tracks.length} 首')));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _importing = null);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 420,
      child: FutureBuilder<List<QqPlaylistSummary>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('加载失败: ${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final list = snap.data!;
          if (list.isEmpty) return const Center(child: Text('没有自建歌单'));
          return ListView.builder(
            itemCount: list.length,
            itemBuilder: (context, i) {
              final p = list[i];
              final busy = _importing == p.name;
              return ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: p.coverUrl.isNotEmpty
                      ? Image.network(p.coverUrl,
                          width: 44,
                          height: 44,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const Icon(Icons.music_note))
                      : const Icon(Icons.queue_music),
                ),
                title: Text(p.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${p.songCount} 首'),
                trailing: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.download, size: 20),
                onTap: busy || _importing != null ? null : () => _import(p),
              );
            },
          );
        },
      ),
    );
  }
}
