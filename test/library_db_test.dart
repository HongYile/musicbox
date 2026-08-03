import 'package:unison/services/library/library_db.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late LibraryDatabase db;

  setUp(() => db = LibraryDatabase.memory());
  tearDown(() => db.close());

  group('playlists', () {
    test('创建 / 列表 / 删除', () {
      final id = db.createPlaylist('我的歌单');
      expect(id, greaterThan(0));
      db.createPlaylist('第二个');

      final list = db.listPlaylists();
      expect(list.length, 2);
      expect(list.map((p) => p.name), containsAll(['我的歌单', '第二个']));

      db.deletePlaylist(id);
      expect(db.listPlaylists().length, 1);
    });

    test('renamePlaylist 改名', () {
      final id = db.createPlaylist('旧名');
      db.renamePlaylist(id, '新名');
      expect(db.listPlaylists().single.name, '新名');
    });

    test('新歌单排最上，reorderPlaylists 自定义顺序', () {
      final a = db.createPlaylist('A');
      final b = db.createPlaylist('B');
      final c = db.createPlaylist('C');

      // 新建排最上：C, B, A
      expect(db.listPlaylists().map((p) => p.id), [c, b, a]);

      // 拖拽重排：A, C, B
      db.reorderPlaylists([a, c, b]);
      expect(db.listPlaylists().map((p) => p.id), [a, c, b]);
      // summaries 同序
      expect(db.listPlaylistSummaries().map((p) => p.id), [a, c, b]);
    });
  });

  group('playlist_tracks', () {
    test('添加 / 查询 / 移除', () {
      final pid = db.createPlaylist('p');
      final added = db.addTrack(
        playlistId: pid,
        sourceId: 'bilibili',
        trackId: 'BV1xx',
        title: '歌',
        artist: 'up',
        cover: 'https://x/c.jpg',
        durationSec: 200,
        cid: 123,
      );
      expect(added, isTrue);

      db.addTrack(
        playlistId: pid,
        sourceId: 'bilibili',
        trackId: 'BV1yy',
        title: '歌2',
      );

      final tracks = db.tracksOf(pid);
      expect(tracks.length, 2);
      final t = tracks.first;
      expect(t.trackId, 'BV1xx');
      expect(t.title, '歌');
      expect(t.artist, 'up');
      expect(t.cover, 'https://x/c.jpg');
      expect(t.durationSec, 200);
      expect(t.cid, 123);
      expect(tracks[1].cid, 0); // 默认 0（播放时再解析）

      db.removeTrack(t.id);
      expect(db.tracksOf(pid).length, 1);
    });

    test('重复添加被忽略', () {
      final pid = db.createPlaylist('p');
      expect(
        db.addTrack(
            playlistId: pid, sourceId: 'bilibili', trackId: 'BV1', title: 'a'),
        isTrue,
      );
      expect(
        db.addTrack(
            playlistId: pid, sourceId: 'bilibili', trackId: 'BV1', title: 'a'),
        isFalse,
      );
      expect(db.tracksOf(pid).length, 1);
    });

    test('删歌单级联删曲目 + summary 计数', () {
      final pid = db.createPlaylist('p');
      db.addTrack(
          playlistId: pid, sourceId: 'bilibili', trackId: 'BV1', title: 'a');
      db.addTrack(
          playlistId: pid, sourceId: 'bilibili', trackId: 'BV2', title: 'b');

      final summary = db.listPlaylistSummaries().single;
      expect(summary.trackCount, 2);

      db.deletePlaylist(pid);
      expect(db.tracksOf(pid), isEmpty);
    });
  });

  group('downloads', () {
    DownloadEntry entry({String status = DownloadStatus.downloading}) =>
        DownloadEntry(
          trackId: 'BV1dl',
          sourceId: 'bilibili',
          title: '下载曲目',
          filePath: '/tmp/dl/BV1dl_30251.flac',
          coverPath: '/tmp/dl/BV1dl.jpg',
          quality: 30251,
          status: status,
          size: 1024,
          createdAt: DateTime(2026, 1, 1),
        );

    test('upsert / get / list / delete', () {
      db.upsertDownload(entry());
      final e = db.getDownload('bilibili', 'BV1dl');
      expect(e, isNotNull);
      expect(e!.quality, 30251);
      expect(e.status, DownloadStatus.downloading);
      expect(e.filePath, endsWith('.flac'));

      // 同主键覆盖
      db.upsertDownload(entry(status: DownloadStatus.completed));
      expect(db.getDownload('bilibili', 'BV1dl')!.status,
          DownloadStatus.completed);
      expect(db.listDownloads().length, 1);

      db.deleteDownload('bilibili', 'BV1dl');
      expect(db.listDownloads(), isEmpty);
    });

    test('updateDownloadStatus 只改状态/大小', () {
      db.upsertDownload(entry());
      db.updateDownloadStatus(
        sourceId: 'bilibili',
        trackId: 'BV1dl',
        status: DownloadStatus.failed,
        size: 2048,
      );
      final e = db.getDownload('bilibili', 'BV1dl')!;
      expect(e.status, DownloadStatus.failed);
      expect(e.size, 2048);
      expect(e.title, '下载曲目'); // 其他字段不动
    });
  });
}
