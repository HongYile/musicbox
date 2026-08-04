import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:unison/services/library/library_db.dart';
import 'package:flutter_test/flutter_test.dart';

/// 老库迁移：qq:/ncm: 前缀脏行清理——与合法行冲突时删除脏行而不是崩启动。
void main() {
  test('脏行与合法行冲突时删脏行，剩余改写，且幂等', () {
    final dir = Directory.systemTemp.createTempSync('unison_mig');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/t.db';

    // 造老结构 + 三类数据：合法 QQ 行、与之冲突的脏行、仅存在的脏行
    final raw = sqlite3.open(path);
    raw.execute('''
      CREATE TABLE playlists (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL)''');
    raw.execute('''
      CREATE TABLE playlist_tracks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
        source_id TEXT NOT NULL,
        track_id TEXT NOT NULL,
        title TEXT NOT NULL,
        artist TEXT NOT NULL DEFAULT '',
        cover TEXT NOT NULL DEFAULT '',
        duration INTEGER NOT NULL DEFAULT 0,
        cid INTEGER NOT NULL DEFAULT 0,
        added_at INTEGER NOT NULL,
        UNIQUE(playlist_id, source_id, track_id, cid))''');
    raw.execute("INSERT INTO playlists(name, created_at) VALUES ('p', 1)");
    raw.execute(
        "INSERT INTO playlist_tracks(playlist_id, source_id, track_id, title, added_at) "
        "VALUES (1, 'qqmusic', 'ABC', '合法', 1)");
    raw.execute(
        "INSERT INTO playlist_tracks(playlist_id, source_id, track_id, title, added_at) "
        "VALUES (1, 'bilibili', 'qq:ABC', '冲突脏行', 2)");
    raw.execute(
        "INSERT INTO playlist_tracks(playlist_id, source_id, track_id, title, added_at) "
        "VALUES (1, 'bilibili', 'qq:DEF', '仅脏行', 3)");
    raw.close();

    final db = LibraryDatabase.file(path);
    final tracks = db.tracksOf(1);
    // 冲突脏行被删（保留合法行），仅脏行被改写归位
    expect(tracks.length, 2);
    expect(tracks.every((t) => t.sourceId == 'qqmusic'), isTrue);
    expect(tracks.map((t) => t.trackId).toSet(), {'ABC', 'DEF'});
    db.close();

    // 再开一次：迁移幂等，不崩
    final db2 = LibraryDatabase.file(path);
    expect(db2.tracksOf(1).length, 2);
    db2.close();
  });
}
