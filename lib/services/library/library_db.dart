/// 本地曲库数据库：手写 DAO + sqlite3（MVP 阶段不用 drift codegen）。
///
/// 纯 Dart（不 import Flutter），测试用 [LibraryDatabase.memory] 内存库。
library;

import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// 下载状态（downloads.status 文本值）。
class DownloadStatus {
  static const downloading = 'downloading';
  static const completed = 'completed';
  static const failed = 'failed';
}

class Playlist {
  const Playlist({required this.id, required this.name, required this.createdAt});

  final int id;
  final String name;
  final DateTime createdAt;
}

/// 歌单 + 曲目数（列表页用）。
class PlaylistSummary {
  const PlaylistSummary({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.trackCount,
  });

  final int id;
  final String name;
  final DateTime createdAt;
  final int trackCount;
}

class PlaylistTrack {
  const PlaylistTrack({
    required this.id,
    required this.playlistId,
    required this.sourceId,
    required this.trackId,
    required this.title,
    required this.artist,
    required this.cover,
    required this.durationSec,
    required this.cid,
    required this.addedAt,
  });

  final int id;
  final int playlistId;
  final String sourceId;

  /// 曲目 id（B站即 bvid）。
  final String trackId;
  final String title;
  final String artist;
  final String cover;
  final int durationSec;

  /// 分 P cid；未知（收藏夹导入）时为 0，播放时再经 pagelist 解析。
  final int cid;
  final DateTime addedAt;
}

class DownloadEntry {
  const DownloadEntry({
    required this.trackId,
    required this.sourceId,
    required this.title,
    required this.filePath,
    required this.coverPath,
    required this.quality,
    required this.status,
    required this.size,
    required this.createdAt,
  });

  final String trackId;
  final String sourceId;
  final String title;
  final String filePath;
  final String coverPath;

  /// 音质 id（如 30251）。
  final int quality;

  /// [DownloadStatus] 之一。
  final String status;

  /// 字节数；下载中为已收字节数。
  final int size;
  final DateTime createdAt;

  DownloadEntry copyWith({
    String? filePath,
    String? coverPath,
    String? status,
    int? size,
  }) =>
      DownloadEntry(
        trackId: trackId,
        sourceId: sourceId,
        title: title,
        filePath: filePath ?? this.filePath,
        coverPath: coverPath ?? this.coverPath,
        quality: quality,
        status: status ?? this.status,
        size: size ?? this.size,
        createdAt: createdAt,
      );
}

class LibraryDatabase {
  LibraryDatabase._(this._db) {
    _migrate();
  }

  /// App 内使用：落盘到 [path]。
  factory LibraryDatabase.file(String path) {
    final parent = File(path).parent;
    if (!parent.existsSync()) parent.createSync(recursive: true);
    return LibraryDatabase._(sqlite3.open(path));
  }

  /// 测试使用：内存库。
  factory LibraryDatabase.memory() => LibraryDatabase._(sqlite3.openInMemory());

  final Database _db;

  void _migrate() {
    _db.execute('PRAGMA foreign_keys = ON');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS playlists (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS playlist_tracks (
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
        UNIQUE(playlist_id, source_id, track_id, cid)
      )''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS downloads (
        track_id TEXT NOT NULL,
        source_id TEXT NOT NULL,
        title TEXT NOT NULL,
        file_path TEXT NOT NULL,
        cover_path TEXT NOT NULL DEFAULT '',
        quality INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL,
        size INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        PRIMARY KEY(source_id, track_id)
      )''');
    // 歌单自定义排序（后加的列，老库补列）。
    try {
      _db.execute(
          'ALTER TABLE playlists ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0');
    } catch (_) {
      // 列已存在。
    }
    // 老数据回填：保持原"新建在前"的展示顺序。
    _db.execute('''
      UPDATE playlists SET sort_order = (
        SELECT COUNT(*) FROM playlists p2 WHERE p2.created_at > playlists.created_at
           OR (p2.created_at = playlists.created_at AND p2.id > playlists.id)
      ) WHERE sort_order = 0 AND NOT EXISTS (
        SELECT 1 FROM playlists p3 WHERE p3.sort_order != 0
      )''');
    // 修复脏数据：播放页加歌单曾把 CurrentTrack.bvid 的前缀（qq:/ncm:）
    // 原样入库且 source_id 记成 bilibili，导致播放时按 B站查 pagelist 报 -400。
    _db.execute('''
      UPDATE playlist_tracks SET source_id = 'qqmusic',
        track_id = substr(track_id, 4)
      WHERE source_id = 'bilibili' AND track_id LIKE 'qq:%' ''');
    _db.execute('''
      UPDATE playlist_tracks SET source_id = 'netease',
        track_id = substr(track_id, 5)
      WHERE source_id = 'bilibili' AND track_id LIKE 'ncm:%' ''');
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  static DateTime _fromMs(Object? v) =>
      DateTime.fromMillisecondsSinceEpoch((v as num?)?.toInt() ?? 0);

  // ---------- playlists ----------

  /// 在单个事务里执行批量写（同步导入等），避免逐行自动提交拖慢/卡 UI。
  T inTransaction<T>(T Function() body) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final r = body();
      _db.execute('COMMIT');
      return r;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  int createPlaylist(String name) {
    // 新歌单排最上面（sort_order 越小越靠前）。
    _db.execute(
      '''INSERT INTO playlists(name, created_at, sort_order)
         VALUES (?, ?, COALESCE((SELECT MIN(sort_order) FROM playlists), 1) - 1)''',
      [name, _now()],
    );
    return _db.lastInsertRowId;
  }

  /// 按名字查歌单 id（同步导入匹配合并用）；不存在返回 null。
  int? findPlaylistIdByName(String name) {
    final rows = _db.select(
        'SELECT id FROM playlists WHERE name = ? LIMIT 1', [name]);
    if (rows.isEmpty) return null;
    return rows.first['id'] as int;
  }

  List<Playlist> listPlaylists() => _db
      .select('SELECT * FROM playlists ORDER BY sort_order ASC, id ASC')
      .map(_playlistFromRow)
      .toList();

  List<PlaylistSummary> listPlaylistSummaries() => _db
      .select('''
        SELECT p.*, (SELECT COUNT(*) FROM playlist_tracks t
                     WHERE t.playlist_id = p.id) AS track_count
        FROM playlists p ORDER BY p.sort_order ASC, p.id ASC''')
      .map((row) => PlaylistSummary(
            id: (row['id'] as num).toInt(),
            name: row['name'] as String,
            createdAt: _fromMs(row['created_at']),
            trackCount: (row['track_count'] as num).toInt(),
          ))
      .toList();

  void renamePlaylist(int id, String name) => _db.execute(
      'UPDATE playlists SET name = ? WHERE id = ?', [name, id]);

  /// 按给定 id 顺序重写歌单排序（数组下标即新 sort_order）。
  void reorderPlaylists(List<int> orderedIds) {
    final stmt = _db.prepare(
        'UPDATE playlists SET sort_order = ? WHERE id = ?');
    for (var i = 0; i < orderedIds.length; i++) {
      stmt.execute([i, orderedIds[i]]);
    }
    stmt.close();
  }

  void deletePlaylist(int id) =>
      _db.execute('DELETE FROM playlists WHERE id = ?', [id]);

  // ---------- playlist_tracks ----------

  /// 加入歌单；同 (playlistId, sourceId, trackId, cid) 重复时忽略，返回 false。
  bool addTrack({
    required int playlistId,
    required String sourceId,
    required String trackId,
    required String title,
    String artist = '',
    String cover = '',
    int durationSec = 0,
    int cid = 0,
  }) {
    _db.execute(
      '''INSERT OR IGNORE INTO playlist_tracks
         (playlist_id, source_id, track_id, title, artist, cover, duration, cid, added_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [playlistId, sourceId, trackId, title, artist, cover, durationSec, cid,
        _now()],
    );
    return _db.updatedRows > 0;
  }

  void removeTrack(int id) =>
      _db.execute('DELETE FROM playlist_tracks WHERE id = ?', [id]);

  List<PlaylistTrack> tracksOf(int playlistId) => _db
      .select(
        'SELECT * FROM playlist_tracks WHERE playlist_id = ? ORDER BY added_at ASC, id ASC',
        [playlistId],
      )
      .map((row) => PlaylistTrack(
            id: (row['id'] as num).toInt(),
            playlistId: (row['playlist_id'] as num).toInt(),
            sourceId: row['source_id'] as String,
            trackId: row['track_id'] as String,
            title: row['title'] as String,
            artist: row['artist'] as String,
            cover: row['cover'] as String,
            durationSec: (row['duration'] as num).toInt(),
            cid: (row['cid'] as num).toInt(),
            addedAt: _fromMs(row['added_at']),
          ))
      .toList();

  // ---------- downloads ----------

  /// 写入/覆盖下载记录（按 sourceId+trackId 主键）。
  void upsertDownload(DownloadEntry e) {
    _db.execute(
      '''INSERT OR REPLACE INTO downloads
         (track_id, source_id, title, file_path, cover_path, quality, status, size, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [e.trackId, e.sourceId, e.title, e.filePath, e.coverPath, e.quality,
        e.status, e.size, e.createdAt.millisecondsSinceEpoch],
    );
  }

  void updateDownloadStatus({
    required String sourceId,
    required String trackId,
    required String status,
    int? size,
  }) {
    _db.execute(
      'UPDATE downloads SET status = ?, size = COALESCE(?, size) '
      'WHERE source_id = ? AND track_id = ?',
      [status, size, sourceId, trackId],
    );
  }

  DownloadEntry? getDownload(String sourceId, String trackId) {
    final rows = _db.select(
      'SELECT * FROM downloads WHERE source_id = ? AND track_id = ?',
      [sourceId, trackId],
    );
    if (rows.isEmpty) return null;
    return _downloadFromRow(rows.first);
  }

  List<DownloadEntry> listDownloads() => _db
      .select('SELECT * FROM downloads ORDER BY created_at DESC')
      .map(_downloadFromRow)
      .toList();

  void deleteDownload(String sourceId, String trackId) => _db.execute(
      'DELETE FROM downloads WHERE source_id = ? AND track_id = ?',
      [sourceId, trackId]);

  DownloadEntry _downloadFromRow(Row row) => DownloadEntry(
        trackId: row['track_id'] as String,
        sourceId: row['source_id'] as String,
        title: row['title'] as String,
        filePath: row['file_path'] as String,
        coverPath: row['cover_path'] as String,
        quality: (row['quality'] as num).toInt(),
        status: row['status'] as String,
        size: (row['size'] as num).toInt(),
        createdAt: _fromMs(row['created_at']),
      );

  Playlist _playlistFromRow(Row row) => Playlist(
        id: (row['id'] as num).toInt(),
        name: row['name'] as String,
        createdAt: _fromMs(row['created_at']),
      );

  void close() => _db.close();
}
