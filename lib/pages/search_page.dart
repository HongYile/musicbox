import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../services/sources/bilibili/api/client.dart';
import '../services/sources/qqmusic/models.dart';
import '../widgets/add_to_playlist_dialog.dart';
import '../widgets/glass_card.dart';
import 'track_list_page.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _controller = TextEditingController();
  bool _opening = false;

  Future<void> _play(String bvid, String title, String author, String cover,
      int durationSec) async {
    setState(() => _opening = true);
    try {
      final source = ref.read(selectedSourceProvider);
      if (source == 'netease') {
        await ref.read(playerServiceProvider).playNeteaseTrack(
              songId: bvid,
              title: title,
              artist: author,
              coverUrl: cover,
            );
      } else if (source == 'qqmusic') {
        await ref.read(playerServiceProvider).playQqTrack(
              QqSong(
                songMid: bvid,
                mediaMid: bvid, // 缺失时回退 songMid（蓝本允许）
                name: title,
                singer: author,
                album: '',
                intervalSec: durationSec,
                coverUrl: cover,
              ),
            );
      } else {
        final api = ref.read(biliApiProvider);
        final pages = await api.pagelist(bvid);
        if (pages.isEmpty) throw StateError('该稿件没有分 P');
        await ref.read(playerServiceProvider).playTrack(
              bvid: bvid,
              cid: pages.first.cid,
              title: title,
              artist: author,
              coverUrl: cover,
            );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('播放失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  /// B站稿件进入曲目列表页（分P 展开/收录/下载/Hi-Res 标识）；网易云/QQ 直接播。
  void _open(String bvid, String title, String author, String cover,
      int durationSec) {
    final source = ref.read(selectedSourceProvider);
    if (source == 'netease' || source == 'qqmusic') {
      _play(bvid, title, author, cover, durationSec);
      return;
    }
    // 平滑过场：右侧滑入 + 淡入（风格指南回弹曲线）
    Navigator.of(context).push(PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 320),
      reverseTransitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (context, anim, secondary) => TrackListPage(
        bvid: bvid,
        title: title,
        author: author,
        cover: cover,
      ),
      transitionsBuilder: (context, anim, secondary, child) {
        final curved =
            CurvedAnimation(parent: anim, curve: const Cubic(.2, .9, .3, 1.15));
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(begin: const Offset(0.06, 0), end: Offset.zero)
                .animate(curved),
            child: child,
          ),
        );
      },
    ));
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(searchResultsProvider);
    final source = ref.watch(selectedSourceProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'bilibili', label: Text('哔哩哔哩')),
              ButtonSegment(value: 'netease', label: Text('网易云音乐')),
              ButtonSegment(value: 'qqmusic', label: Text('QQ音乐')),
            ],
            selected: {source},
            onSelectionChanged: (s) =>
                ref.read(selectedSourceProvider.notifier).state = s.first,
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _controller,
            decoration: InputDecoration(
              hintText: switch (source) {
                'netease' => '搜索网易云单曲',
                'qqmusic' => '搜索 QQ 音乐（绿钻可播无损）',
                _ => '搜索 B站视频/音乐稿件',
              },
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
              suffixIcon: _opening
                  ? const Padding(
                      padding: EdgeInsets.all(10),
                      child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : null,
            ),
            onSubmitted: (kw) =>
                ref.read(searchResultsProvider.notifier).search(kw),
          ),
        ),
        Expanded(
          child: results.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('搜索失败: $e')),
            data: (list) => list.isEmpty
                ? const Center(child: Text('输入关键词开始搜索'))
                : ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final r = list[i];
                      return GlassCard(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                        child: ListTile(
                          leading: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: CachedNetworkImage(
                            imageUrl: r.coverUrl,
                            width: 64,
                            height: 40,
                            fit: BoxFit.cover,
                            httpHeaders: const {'Referer': kBiliReferer},
                            placeholder: (_, _) => const SizedBox(
                                width: 64,
                                height: 40,
                                child: ColoredBox(color: Colors.black12)),
                            errorWidget: (_, _, _) => const SizedBox(
                                width: 64,
                                height: 40,
                                child: Icon(Icons.music_note)),
                          ),
                        ),
                        title: Text(r.title,
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(source == 'bilibili'
                            ? '${r.author} · ${formatDuration(r.durationSec)} · 播放${r.play}'
                            : '${r.author} · ${formatDuration(r.durationSec)}'),
                        trailing: IconButton(
                          tooltip: '加入歌单',
                          icon: const Icon(Icons.playlist_add),
                          onPressed: () => showAddToPlaylistDialog(
                            context,
                            ref,
                            trackId: r.bvid,
                            title: r.title,
                            artist: r.author,
                            cover: r.coverUrl,
                            durationSec: r.durationSec,
                            sourceId: source,
                          ),
                        ),
                        onTap: () => _open(r.bvid, r.title, r.author, r.coverUrl, r.durationSec),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}
