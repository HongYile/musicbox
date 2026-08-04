import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../services/player/player_service.dart';
import '../services/sources/bilibili/models.dart';
import '../services/sources/qqmusic/models.dart';
import 'eq_bars.dart';

/// 换源试听：把当前曲目拿到全部音源搜一遍，逐条试听对比，
/// 用耳朵和音质徽章决定哪个源最好。
class SourceAuditionSheet extends ConsumerStatefulWidget {
  const SourceAuditionSheet({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const FractionallySizedBox(
          heightFactor: 0.75, child: SourceAuditionSheet()),
    );
  }

  @override
  ConsumerState<SourceAuditionSheet> createState() =>
      _SourceAuditionSheetState();
}

class _SourceAuditionSheetState extends ConsumerState<SourceAuditionSheet> {
  /// 各音源搜索结果：'bilibili'/'netease'/'qqmusic' → (加载中?, 结果/错误)。
  final _state = <String, (bool loading, Object? result)>{
    'bilibili': (true, null),
    'netease': (true, null),
    'qqmusic': (true, null),
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _searchAll());
  }

  String get _keyword {
    final track = ref.read(playerServiceProvider).current;
    if (track == null) return '';
    // B站标题常带【】和 UP 主前缀，网易云/QQ 搜索用纯标题更准
    var t = track.title
        .replaceAll(RegExp(r'【[^】]*】'), '')
        .replaceAll(RegExp(r'[《》|｜\-—_].*$'), '')
        .trim();
    if (t.isEmpty) t = track.title;
    return track.artist.isEmpty ? t : '$t ${track.artist}';
  }

  /// AI 提炼后的搜索词（配置了 AI 且提取成功时非空，用于界面展示）。
  String? _aiKeyword;

  Future<void> _searchAll() async {
    var kw = _keyword;
    final track = ref.read(playerServiceProvider).current;
    // 配置了 AI：先提炼干净歌名（B站标题噪声多，直接搜命中率低）
    if (track != null) {
      final extracted = await ref.read(aiTitleServiceProvider).extract(
          rawTitle: track.title, uploader: track.artist);
      if (extracted != null && mounted) {
        kw = extracted.keyword;
        setState(() => _aiKeyword = kw);
      }
    }
    if (kw.isEmpty) return;
    // 三源并行，各自容错
    for (final id in _state.keys) {
      () async {
        try {
          final result = switch (id) {
            'bilibili' => await ref.read(biliApiProvider).searchVideos(kw),
            'netease' =>
              await ref.read(neteaseSourceProvider).search(kw),
            _ => await ref.read(qqMusicSourceProvider).searchSongs(kw),
          };
          if (mounted) setState(() => _state[id] = (false, result));
        } catch (e) {
          if (mounted) setState(() => _state[id] = (false, e));
        }
      }();
    }
  }

  Future<void> _audition(String sourceId, Object item) async {
    final player = ref.read(playerServiceProvider);
    try {
      switch (sourceId) {
        case 'bilibili':
          final r = item as BiliSearchResult;
          final pages = await ref.read(biliApiProvider).pagelist(r.bvid);
          if (pages.isEmpty) throw StateError('该稿件没有分P');
          await player.playTrack(
              bvid: r.bvid,
              cid: pages.first.cid,
              title: r.title,
              artist: r.author,
              coverUrl: r.coverUrl);
        case 'netease':
          final r = item as BiliSearchResult;
          await player.playNeteaseTrack(
              songId: r.bvid,
              title: r.title,
              artist: r.author,
              coverUrl: r.coverUrl);
        case 'qqmusic':
          await player.playQqTrack(item as QqSong);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('试听失败: $e')));
      }
    }
  }

  Widget _section(String id, String label) {
    final (loading, result) = _state[id]!;
    final current = ref.watch(currentTrackProvider).value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(label, style: Theme.of(context).textTheme.labelLarge),
        ),
        if (loading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
                child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))),
          )
        else if (result is Exception || result is StateError || result == null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text('搜索失败: $result',
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
          )
        else
          for (final item in (result as List).take(3))
            _itemTile(id, item, current),
      ],
    );
  }

  Widget _itemTile(String id, Object item, CurrentTrack? current) {
    final (title, artist, isCurrent) = switch (id) {
      'bilibili' => (
          (item as BiliSearchResult).title,
          (item).author,
          current != null && current.bvid == (item).bvid,
        ),
      'netease' => (
          (item as BiliSearchResult).title,
          (item).author,
          current != null && current.bvid == 'ncm:${(item).bvid}',
        ),
      _ => (
          (item as QqSong).name,
          (item).singer,
          current != null && current.bvid == 'qq:${(item).songMid}',
        ),
    };
    return ListTile(
      dense: true,
      leading: isCurrent ? const EqBars(size: 16) : null,
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle:
          Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: isCurrent && current != null
          ? Tooltip(
              message: '当前音源',
              child: Text(current.quality.qualityLabel,
                  style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.primary)),
            )
          : const Icon(Icons.play_arrow, size: 18),
      onTap: () => _audition(id, item),
    );
  }

  @override
  Widget build(BuildContext context) {
    final track = ref.watch(currentTrackProvider).value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text('换源试听', style: Theme.of(context).textTheme.titleMedium),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            track == null
                ? ''
                : _aiKeyword != null
                    ? 'AI 识别为「$_aiKeyword」，各音源 Top3，点按试听对比'
                    : '「${track.title}」各音源 Top3，点按试听对比',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const Divider(),
        Expanded(
          child: ListView(
            children: [
              _section('bilibili', '哔哩哔哩'),
              _section('qqmusic', 'QQ音乐'),
              _section('netease', '网易云音乐'),
            ],
          ),
        ),
      ],
    );
  }
}
