/// 缓存下载：取最优流（Hi-Res 优先）→ 带 Referer/UA 下载原始流到本地
/// （不转码、不写 ID3），同时下载封面，记录写入 downloads 表。
///
/// 纯 Dart（不 import Flutter）。
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import '../sources/bilibili/api/client.dart';
import '../sources/bilibili/api/endpoints.dart';
import 'library_db.dart';

/// 流扩展名：flac 流存 .flac，其余（mp4a）存 .m4a。
String downloadExt({required bool isLossless}) => isLossless ? 'flac' : 'm4a';

/// 下载文件名：`<bvid>_<音质id>.<ext>`。
String downloadFileName(String bvid, int qualityId, {required bool isLossless}) =>
    '${bvid}_$qualityId.${downloadExt(isLossless: isLossless)}';

/// 下载进度事件。
class DownloadProgress {
  const DownloadProgress({
    required this.trackId,
    required this.received,
    required this.total,
    required this.status,
  });

  final String trackId;
  final int received;
  final int total;
  final String status;

  double get ratio => total > 0 ? received / total : 0;
}

class DownloadService {
  DownloadService(this._api, this._db, {required String dir})
      : _dir = Directory(dir);

  final BiliApi _api;
  final LibraryDatabase _db;
  final Directory _dir;

  final _progressController = StreamController<DownloadProgress>.broadcast();

  /// 下载进度流（供 UI 监听）。
  Stream<DownloadProgress> get progressStream => _progressController.stream;

  Dio? _dio;
  Dio get _client => _dio ??= Dio(BaseOptions(headers: const {
        'User-Agent': kBiliUserAgent,
        'Referer': kBiliReferer,
      }));

  /// 下载一曲：选最优流 → 逐个候选 URL 尝试 → 写 downloads 表。
  Future<DownloadEntry> downloadTrack({
    required String bvid,
    required int cid,
    required String title,
    String artist = '',
    String coverUrl = '',
    String sourceId = 'bilibili',
  }) async {
    await _dir.create(recursive: true);
    final choice = await _api.selectStream(bvid, cid);
    final fileName =
        downloadFileName(bvid, choice.qualityId, isLossless: choice.isLossless);
    final file = File('${_dir.path}/$fileName');

    var entry = DownloadEntry(
      trackId: bvid,
      sourceId: sourceId,
      title: title,
      filePath: file.path,
      coverPath: '',
      quality: choice.qualityId,
      status: DownloadStatus.downloading,
      size: 0,
      createdAt: DateTime.now(),
    );
    _db.upsertDownload(entry);
    _emit(bvid, 0, 0, DownloadStatus.downloading);

    try {
      Object? lastError;
      var ok = false;
      for (final url in choice.allUrls) {
        try {
          await _client.download(
            url,
            file.path,
            onReceiveProgress: (received, total) =>
                _emit(bvid, received, total, DownloadStatus.downloading),
          );
          ok = true;
          break;
        } on DioException catch (e) {
          lastError = e;
          if (file.existsSync()) file.deleteSync();
        }
      }
      if (!ok) throw lastError ?? StateError('所有候选流地址均下载失败');

      final size = await file.length();

      // 封面（失败不阻塞主流程）
      var coverPath = '';
      if (coverUrl.isNotEmpty) {
        coverPath = '${_dir.path}/$bvid.jpg';
        try {
          await _client.download(coverUrl, coverPath);
        } catch (_) {
          coverPath = '';
        }
      }

      entry = entry.copyWith(
        status: DownloadStatus.completed,
        size: size,
        coverPath: coverPath,
      );
      _db.upsertDownload(entry);
      _emit(bvid, size, size, DownloadStatus.completed);
      return entry;
    } catch (e) {
      entry = entry.copyWith(status: DownloadStatus.failed);
      _db.upsertDownload(entry);
      _emit(bvid, 0, 0, DownloadStatus.failed);
      rethrow;
    }
  }

  void _emit(String trackId, int received, int total, String status) {
    if (_progressController.isClosed) return;
    _progressController.add(DownloadProgress(
      trackId: trackId,
      received: received,
      total: total,
      status: status,
    ));
  }

  Future<void> dispose() async {
    await _progressController.close();
  }
}
