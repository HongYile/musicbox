import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../services/player/player_service.dart';

/// 评论面板：B站（bvid→aid→reply）/ QQ音乐（songmid→songid→comment）。
///
/// 滚动到底自动续页；由外层包裹渐变遮罩与滚动条隐藏。
class CommentsPanel extends ConsumerStatefulWidget {
  const CommentsPanel({super.key, required this.track});

  final CurrentTrack track;

  @override
  ConsumerState<CommentsPanel> createState() => _CommentsPanelState();
}

class _CommentItem {
  const _CommentItem({
    required this.author,
    required this.avatar,
    required this.message,
    required this.like,
    required this.timeSec,
    this.replyCount = 0,
  });

  final String author;
  final String avatar;
  final String message;
  final int like;
  final int timeSec;
  final int replyCount;
}

class _CommentsPanelState extends ConsumerState<CommentsPanel> {
  final _scroll = ScrollController();
  final List<_CommentItem> _items = [];
  int _page = 1;
  bool _loading = true;
  bool _isEnd = false;
  String? _error;

  /// 解析后的评论目标（B站 aid / QQ songid）。
  int? _targetId;
  String? _source; // 'bilibili' / 'qqmusic' / null（不支持）

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    _bootstrap();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final bvid = widget.track.bvid;
    try {
      if (bvid.startsWith('BV')) {
        _source = 'bilibili';
        _targetId = await ref.read(biliApiProvider).aidOf(bvid);
      } else if (bvid.startsWith('qq:')) {
        _source = 'qqmusic';
        _targetId =
            await ref.read(qqApiProvider).songIdByMid(bvid.substring(3));
      } else {
        setState(() {
          _loading = false;
          _error = '该音源暂不支持评论';
        });
        return;
      }
      await _loadMore();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '评论加载失败: $e';
        });
      }
    }
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients || _loading || _isEnd) return;
    if (_scroll.position.extentAfter > 160) return;
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_targetId == null || _source == null) return;
    setState(() => _loading = true);
    try {
      if (_source == 'bilibili') {
        final page =
            await ref.read(biliApiProvider).replies(_targetId!, pn: _page);
        _items.addAll([
          for (final c in page.items)
            _CommentItem(
              author: c.author,
              avatar: c.avatar,
              message: c.message,
              like: c.like,
              timeSec: c.timeSec,
              replyCount: c.replyCount,
            ),
        ]);
        _isEnd = page.isEnd;
      } else {
        final page = await ref
            .read(qqApiProvider)
            .comments(_targetId!, page: _page - 1);
        _items.addAll([
          for (final c in page.items)
            _CommentItem(
              author: c.author,
              avatar: c.avatar,
              message: c.message,
              like: c.like,
              timeSec: c.timeSec,
            ),
        ]);
        _isEnd = page.isEnd;
      }
      _page++;
    } catch (e) {
      _error = '评论加载失败: $e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _fmtTime(int sec) {
    if (sec <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null && _items.isEmpty) {
      return Center(
          child: Text(_error!, style: const TextStyle(color: Colors.grey)));
    }
    if (_items.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      itemCount: _items.length + 1,
      itemBuilder: (context, i) {
        if (i == _items.length) {
          if (_loading) {
            return const Padding(
              padding: EdgeInsets.all(12),
              child: Center(
                  child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))),
            );
          }
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Center(
                child: Text(_isEnd ? '没有更多评论了' : '',
                    style: const TextStyle(color: Colors.grey, fontSize: 12))),
          );
        }
        final c = _items[i];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 16,
                backgroundImage: c.avatar.isNotEmpty
                    ? CachedNetworkImageProvider(c.avatar)
                    : null,
                child: c.avatar.isEmpty ? const Icon(Icons.person, size: 16) : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(c.author,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.color)),
                        ),
                        const SizedBox(width: 8),
                        Text(_fmtTime(c.timeSec),
                            style: const TextStyle(
                                fontSize: 11, color: Colors.grey)),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(c.message, style: const TextStyle(fontSize: 13)),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        const Icon(Icons.thumb_up_alt_outlined,
                            size: 12, color: Colors.grey),
                        const SizedBox(width: 4),
                        Text('${c.like}',
                            style: const TextStyle(
                                fontSize: 11, color: Colors.grey)),
                        if (c.replyCount > 0) ...[
                          const SizedBox(width: 12),
                          const Icon(Icons.chat_bubble_outline,
                              size: 12, color: Colors.grey),
                          const SizedBox(width: 4),
                          Text('${c.replyCount}',
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.grey)),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
