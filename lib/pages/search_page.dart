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
  final _scroll = ScrollController();
  bool _opening = false;

  /// 内嵌打开的稿件（不整页 push，左侧导航与通栏播放器常驻）。
  ({String bvid, String title, String author, String cover})? _opened;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// 距底 200px 内自动续页。
  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter > 200) return;
    final notifier = ref.read(searchResultsProvider.notifier);
    if (notifier.loadingMore || notifier.noMore) return;
    notifier.loadMore().then((_) {
      if (mounted) setState(() {}); // 刷新底部指示器
    });
    setState(() {});
  }

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

  /// B站稿件内嵌展开曲目列表（分P 展开/收录/下载/Hi-Res 标识）；网易云/QQ 直接播。
  void _open(String bvid, String title, String author, String cover,
      int durationSec) {
    final source = ref.read(selectedSourceProvider);
    if (source == 'netease' || source == 'qqmusic') {
      _play(bvid, title, author, cover, durationSec);
      return;
    }
    setState(() => _opened = (bvid: bvid, title: title, author: author, cover: cover));
  }

  @override
  Widget build(BuildContext context) {
    // 内嵌曲目列表：点搜索结果后整列替换为 TrackListPage，导航栏常驻。
    final opened = _opened;
    if (opened != null) {
      return TrackListPage(
        bvid: opened.bvid,
        title: opened.title,
        author: opened.author,
        cover: opened.cover,
        embedded: true,
        onBack: () => setState(() => _opened = null),
      );
    }

    final results = ref.watch(searchResultsProvider);
    final source = ref.watch(selectedSourceProvider);

    // 各音源登录态：未登录的音源禁止搜索/切换（灰阶不可用）
    final biliLogged = ref.watch(loginStateProvider).isLogin;
    final qqLogged = ref.watch(qqLoginStateProvider).value ?? false;
    final ncmLogged = ref.watch(ncmLoginStateProvider).isLogin;
    bool loggedInFor(String id) => switch (id) {
          'bilibili' => biliLogged,
          'qqmusic' => qqLogged,
          'netease' => ncmLogged,
          _ => false,
        };
    final sourceLogged = loggedInFor(source);

    Widget segmentLabel(String id, String text) => Text(
          text,
          style: loggedInFor(id)
              ? null
              : TextStyle(
                  color: Theme.of(context).disabledColor,
                  decoration: TextDecoration.none,
                ),
        );

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: SegmentedButton<String>(
            segments: [
              ButtonSegment(
                  value: 'bilibili', label: segmentLabel('bilibili', '哔哩哔哩')),
              ButtonSegment(
                  value: 'netease', label: segmentLabel('netease', '网易云音乐')),
              ButtonSegment(
                  value: 'qqmusic', label: segmentLabel('qqmusic', 'QQ音乐')),
            ],
            selected: {source},
            onSelectionChanged: (s) {
              final target = s.first;
              if (!loggedInFor(target)) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('该音源未登录，请先到「我的」页登录')));
                return;
              }
              ref.read(selectedSourceProvider.notifier).state = target;
              // 已登录则切换：当前关键词自动在新音源重搜
              final kw = _controller.text.trim();
              if (kw.isNotEmpty) {
                ref.read(searchResultsProvider.notifier).search(kw);
              }
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _controller,
            enabled: sourceLogged,
            decoration: InputDecoration(
              hintText: !sourceLogged
                  ? '该音源未登录，请到「我的」页登录后搜索'
                  : switch (source) {
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
                    controller: _scroll,
                    itemCount: list.length + 1,
                    itemBuilder: (context, i) {
                      // 末尾：续页指示器 / 到底提示
                      if (i == list.length) {
                        final notifier =
                            ref.read(searchResultsProvider.notifier);
                        if (notifier.loadingMore) {
                          return const Padding(
                            padding: EdgeInsets.all(16),
                            child: Center(
                                child: SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))),
                          );
                        }
                        if (notifier.noMore) {
                          return const Padding(
                            padding: EdgeInsets.all(16),
                            child: Center(
                                child: Text('没有更多了',
                                    style: TextStyle(color: Colors.grey))),
                          );
                        }
                        return const SizedBox(height: 16);
                      }
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
