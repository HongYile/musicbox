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
    this.subReplies = const [],
  });

  final String author;
  final String avatar;
  final String message;
  final int like;
  final int timeSec;
  final int replyCount;

  /// 楼中楼预览（B站接口自带，最多 3 条）。
  final List<_CommentItem> subReplies;
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
              subReplies: [
                for (final s in c.subReplies)
                  _CommentItem(
                    author: s.author,
                    avatar: s.avatar,
                    message: s.message,
                    like: s.like,
                    timeSec: s.timeSec,
                  ),
              ],
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
                    _ExpandableText(
                        text: c.message,
                        style: const TextStyle(fontSize: 13)),
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
                    // 楼中楼预览（最多 3 条，B站风格灰底缩进）
                    if (c.subReplies.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(top: 6),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final s in c.subReplies)
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 2),
                                child: Text.rich(
                                  TextSpan(children: [
                                    TextSpan(
                                        text: '${s.author}：',
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary)),
                                    TextSpan(
                                        text: s.message,
                                        style: const TextStyle(fontSize: 12)),
                                  ]),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            if (c.replyCount > c.subReplies.length)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text('共 ${c.replyCount} 条回复',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary)),
                              ),
                          ],
                        ),
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

/// 超长文本折叠/展开：超过 3 行时底部显示「展开 / 收起」。
class _ExpandableText extends StatefulWidget {
  const _ExpandableText({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  static const _maxLines = 3;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: _maxLines,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: constraints.maxWidth);
        final overflow = painter.didExceedMaxLines;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              style: widget.style,
              maxLines: _expanded ? null : _maxLines,
              overflow: _expanded ? null : TextOverflow.ellipsis,
            ),
            if (overflow)
              GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    _expanded ? '收起' : '展开',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.primary),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
