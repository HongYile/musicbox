import 'dart:async';
import 'dart:convert';

import '../library/library_db.dart';
import 'webdav_client.dart';

/// 曲库同步服务（坚果云 WebDAV，仅元数据）。
///
/// 同步内容：歌单+曲目、下载记录、主题/音源设置 → 单个 `musicbox/library.json`。
/// 策略（MVP）：启动时拉取（远程较新则合并覆盖）；本地变更后 3s 防抖推送；
/// 冲突按 updatedAt 最后写入胜。音乐文件本身不同步（坚果云免费流量有限）。
class LibrarySyncService {
  LibrarySyncService(this._db, this._client,
      {this.extrasExporter, this.extrasImporter});

  final LibraryDatabase _db;
  final WebDavClient? _client;

  /// 附加字段导出（如加密后的 AI 配置）；返回值并入载荷的 `extras` 键。
  final Future<Map<String, dynamic>?> Function()? extrasExporter;

  /// 附加字段导入（拉取时应用 extras）。
  final Future<void> Function(Map<String, dynamic> extras)? extrasImporter;

  static const remoteDir = '/musicbox';
  static const remoteFile = '/musicbox/library.json';

  Timer? _pushTimer;
  DateTime? _lastPushAt;

  bool get configured => _client != null;
  DateTime? get lastPushAt => _lastPushAt;

  // ---------- 导出 / 导入 ----------

  Map<String, dynamic> exportJson({
    int themeModeIndex = 0,
    String selectedSource = 'bilibili',
  }) {
    final playlists = _db.listPlaylists();
    return {
      'version': 1,
      'updatedAt': DateTime.now().toIso8601String(),
      'settings': {
        'themeMode': themeModeIndex,
        'selectedSource': selectedSource,
      },
      'playlists': [
        for (final p in playlists)
          {
            'name': p.name,
            'createdAt': p.createdAt.toIso8601String(),
            'tracks': [
              for (final t in _db.tracksOf(p.id))
                {
                  'sourceId': t.sourceId,
                  'trackId': t.trackId,
                  'title': t.title,
                  'artist': t.artist,
                  'cover': t.cover,
                  'durationSec': t.durationSec,
                  'cid': t.cid,
                  'addedAt': t.addedAt.toIso8601String(),
                },
            ],
          },
      ],
      'downloads': [
        for (final d in _db.listDownloads())
          {
            'sourceId': d.sourceId,
            'trackId': d.trackId,
            'title': d.title,
            'filePath': d.filePath,
            'coverPath': d.coverPath,
            'quality': d.quality,
            'status': d.status,
            'size': d.size,
            'createdAt': d.createdAt.toIso8601String(),
          },
      ],
    };
  }

  /// 导入（合并语义）：歌单按名字匹配或新建；曲目按自然去重键合并；
  /// 下载记录 upsert。返回导入的歌单数。
  /// 全程单事务：逐行自动提交在 Windows 上会因磁盘/杀毒扫描卡死 UI。
  int importJson(Map<String, dynamic> json) => _db.inTransaction(() {
    final playlists = (json['playlists'] as List? ?? const []);
    var count = 0;
    for (final p in playlists.whereType<Map>()) {
      final name = (p['name'] ?? '') as String;
      if (name.isEmpty) continue;
      var playlistId = _db.findPlaylistIdByName(name);
      playlistId ??= _db.createPlaylist(name);
      count++;
      final tracks = (p['tracks'] as List? ?? const []);
      for (final t in tracks.whereType<Map>()) {
        _db.addTrack(
          playlistId: playlistId,
          sourceId: (t['sourceId'] ?? 'bilibili') as String,
          trackId: (t['trackId'] ?? '') as String,
          title: (t['title'] ?? '') as String,
          artist: (t['artist'] ?? '') as String,
          cover: (t['cover'] ?? '') as String,
          durationSec: (t['durationSec'] as num?)?.toInt() ?? 0,
          cid: (t['cid'] as num?)?.toInt() ?? 0,
        );
      }
    }
    final downloads = (json['downloads'] as List? ?? const []);
    for (final d in downloads.whereType<Map>()) {
      _db.upsertDownload(DownloadEntry(
        trackId: (d['trackId'] ?? '') as String,
        sourceId: (d['sourceId'] ?? 'bilibili') as String,
        title: (d['title'] ?? '') as String,
        filePath: (d['filePath'] ?? '') as String,
        coverPath: (d['coverPath'] ?? '') as String,
        quality: (d['quality'] as num?)?.toInt() ?? 0,
        status: (d['status'] ?? '') as String,
        size: (d['size'] as num?)?.toInt() ?? 0,
        createdAt:
            DateTime.tryParse((d['createdAt'] ?? '') as String) ??
                DateTime.now(),
      ));
    }
    return count;
  });

  /// 远程 JSON 的 updatedAt（无则 epoch）。
  DateTime remoteUpdatedAt(Map<String, dynamic> json) =>
      DateTime.tryParse((json['updatedAt'] ?? '') as String) ??
      DateTime.fromMillisecondsSinceEpoch(0);

  // ---------- 推送 / 拉取 ----------

  /// 推送本地曲库到坚果云。
  Future<void> push({
    int themeModeIndex = 0,
    String selectedSource = 'bilibili',
  }) async {
    final client = _requireClient();
    await client.mkcol(remoteDir);
    final payload = exportJson(
        themeModeIndex: themeModeIndex, selectedSource: selectedSource);
    final extras = await extrasExporter?.call();
    if (extras != null) payload['extras'] = extras;
    final bytes = utf8.encode(jsonEncode(payload));
    final ok = await client.put(remoteFile, bytes);
    if (!ok) throw StateError('WebDAV 推送失败');
    _lastPushAt = DateTime.now();
  }

  /// 防抖推送（曲库变更后调用）。
  void pushDebounced({
    int themeModeIndex = 0,
    String selectedSource = 'bilibili',
  }) {
    if (!configured) return;
    _pushTimer?.cancel();
    _pushTimer = Timer(const Duration(seconds: 3), () {
      push(themeModeIndex: themeModeIndex, selectedSource: selectedSource)
          .catchError((_) => false);
    });
  }

  /// 拉取远程曲库。返回 (是否导入, 远程 updatedAt)。
  Future<(bool, DateTime?)> pull({DateTime? localUpdatedAt}) async {
    final client = _requireClient();
    final bytes = await client.get(remoteFile);
    if (bytes == null || bytes.isEmpty) return (false, null);
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map<String, dynamic>) return (false, null);
    final remoteAt = remoteUpdatedAt(json);
    if (localUpdatedAt != null && !remoteAt.isAfter(localUpdatedAt)) {
      return (false, remoteAt); // 本地已是最新
    }
    importJson(json);
    final extras = json['extras'];
    if (extras is Map && extrasImporter != null) {
      await extrasImporter!(extras.cast<String, dynamic>());
    }
    return (true, remoteAt);
  }

  WebDavClient _requireClient() {
    final c = _client;
    if (c == null) throw StateError('未配置坚果云账号');
    return c;
  }

  Future<void> dispose() async {
    _pushTimer?.cancel();
  }
}
