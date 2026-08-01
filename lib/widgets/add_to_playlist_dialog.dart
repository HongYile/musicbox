import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

/// "加入歌单"对话框：选已有歌单或新建。供搜索结果/收藏夹/歌单条目复用。
Future<void> showAddToPlaylistDialog(
  BuildContext context,
  WidgetRef ref, {
  required String trackId,
  required String title,
  String artist = '',
  String cover = '',
  int durationSec = 0,
  int cid = 0,
  String sourceId = 'bilibili',
}) async {
  final playlists = ref.read(playlistsProvider);

  Future<void> addTo(int playlistId) async {
    final added = ref.read(playlistsProvider.notifier).addTrack(
          playlistId: playlistId,
          sourceId: sourceId,
          trackId: trackId,
          title: title,
          artist: artist,
          cover: cover,
          durationSec: durationSec,
          cid: cid,
        );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(added ? '已加入歌单' : '歌单里已有这首')));
    }
  }

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: const Text('加入歌单'),
      children: [
        SimpleDialogOption(
          onPressed: () async {
            Navigator.of(dialogContext).pop();
            final name = await _askPlaylistName(context);
            if (name == null || name.isEmpty) return;
            final id = ref.read(playlistsProvider.notifier).create(name);
            await addTo(id);
          },
          child: const Row(children: [
            Icon(Icons.add),
            SizedBox(width: 8),
            Text('新建歌单'),
          ]),
        ),
        for (final p in playlists)
          SimpleDialogOption(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              addTo(p.id);
            },
            child: Row(children: [
              const Icon(Icons.queue_music),
              const SizedBox(width: 8),
              Expanded(
                  child: Text('${p.name}（${p.trackCount}）',
                      overflow: TextOverflow.ellipsis)),
            ]),
          ),
      ],
    ),
  );
}

/// 弹出输入框询问新歌单名；取消返回 null。
Future<String?> _askPlaylistName(BuildContext context) async {
  final controller = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('新建歌单'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: '歌单名'),
        onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(controller.text),
          child: const Text('创建'),
        ),
      ],
    ),
  );
  return result?.trim();
}

/// 供歌单页"新建歌单"按钮复用。
Future<String?> askPlaylistName(BuildContext context) => _askPlaylistName(context);
