import 'dart:io';

import 'package:dio/dio.dart';

/// 可暂停/续传的下载器（Range 分块 + 超时重试）。
///
/// GitHub 附件 CDN 支持 Range；暂停即停止当前分块，
/// 继续时从已下载位置用 `Range: bytes=N-` 续传。
class ResumableDownload {
  ResumableDownload(this.url, this.destPath, {Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              headers: {'User-Agent': 'musicbox-updater'},
            ));

  final String url;
  final String destPath;
  final Dio _dio;

  var _received = 0;
  var _total = -1;
  var _paused = false;
  var _cancelled = false;

  int get received => _received;
  int get total => _total;
  bool get paused => _paused;
  bool get done => _total > 0 && _received >= _total;

  void pause() => _paused = true;
  void resume() => _paused = false;
  void cancel() => _cancelled = true;

  /// 执行下载直到完成/暂停/取消。[onProgress](received, total)。
  Future<void> run(void Function(int, int)? onProgress) async {
    const maxAttempts = 8;
    var attempts = 0;
    while (!_cancelled && !done) {
      if (_paused) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        continue;
      }
      attempts++;
      try {
        await _downloadOnce(onProgress);
        attempts = 0; // 一段成功则重置重试计数
      } catch (e) {
        if (_paused || _cancelled) continue;
        if (attempts >= maxAttempts) {
          throw StateError('下载失败（重试 $maxAttempts 次仍失败）: $e');
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    if (_cancelled) throw StateError('下载已取消');
  }

  Future<void> _downloadOnce(void Function(int, int)? onProgress) async {
    final headers = <String, dynamic>{};
    if (_received > 0) headers['Range'] = 'bytes=$_received-';

    final resp = await _dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        headers: headers,
        receiveTimeout: const Duration(seconds: 30), // 分块间停滞即断开重试
      ),
    );

    // 服务器忽略 Range 返回 200：从头重下
    if (_received > 0 && resp.statusCode == 200) _received = 0;

    if (_total < 0) {
      final range = resp.headers.value('content-range');
      if (range != null && range.contains('/')) {
        _total = int.tryParse(range.split('/').last) ?? -1;
      }
      _total = _total > 0
          ? _total
          : int.tryParse(resp.headers.value('content-length') ?? '') ?? -1;
    }

    final file = File(destPath);
    final sink = file.openWrite(
        mode: _received > 0 ? FileMode.append : FileMode.write);
    final body = resp.data;
    if (body == null) throw StateError('响应为空');
    await for (final chunk in body.stream) {
      if (_paused || _cancelled) break;
      sink.add(chunk);
      _received += chunk.length;
      onProgress?.call(_received, _total);
    }
    await sink.flush();
    await sink.close();
  }
}

/// 应用内自动更新（macOS）：下载 DMG → 挂载 → 替换 .app（备份+回滚）→ 去隔离 → 重启。
///
/// 前置：App 需关闭沙盒（沙盒内无权 hdiutil/替换 /Applications）。
class SelfUpdater {
  /// 当前运行的 .app 包路径（…/musicbox.app）。
  String currentAppPath() {
    final exe = Platform.resolvedExecutable;
    final idx = exe.indexOf('.app/');
    if (idx < 0) {
      throw StateError('当前不在 .app 包内运行，无法自动安装');
    }
    return exe.substring(0, idx + 4);
  }

  Future<String> _attach(String dmgPath) async {
    final r = await Process.run(
        'hdiutil', ['attach', '-nobrowse', '-readonly', dmgPath]);
    if (r.exitCode != 0) {
      throw StateError('挂载 DMG 失败: ${r.stderr}');
    }
    final mount = '${r.stdout}'
        .split('\n')
        .where((l) => l.contains('/Volumes/'))
        .map((l) => l.substring(l.indexOf('/Volumes/')).trim())
        .lastWhere((m) => m.isNotEmpty, orElse: () => '');
    if (mount.isEmpty) throw StateError('找不到 DMG 挂载点');
    return mount;
  }

  Future<void> _detach(String mount) =>
      Process.run('hdiutil', ['detach', mount, '-quiet']);

  /// 从 DMG 安装：备份旧版 → ditto 覆盖 → 去隔离；失败自动回滚。
  Future<void> installFromDmg(String dmgPath) async {
    final mount = await _attach(dmgPath);
    try {
      final src = '$mount/musicbox.app';
      if (!Directory(src).existsSync()) {
        throw StateError('DMG 内未找到 musicbox.app');
      }
      final target = currentAppPath();
      final backup = '${Directory.systemTemp.path}/musicbox_backup.app';

      await Process.run('rm', ['-rf', backup]);
      final mv = await Process.run('mv', [target, backup]);
      if (mv.exitCode != 0) {
        throw StateError('备份旧版本失败（权限不足）: ${mv.stderr}');
      }
      final ditto = await Process.run('ditto', [src, target]);
      if (ditto.exitCode != 0) {
        await Process.run('rm', ['-rf', target]);
        await Process.run('mv', [backup, target]); // 回滚
        throw StateError('安装失败，已回滚旧版本: ${ditto.stderr}');
      }
      await Process.run('rm', ['-rf', backup]);
      await Process.run('xattr', ['-dr', 'com.apple.quarantine', target]);
    } finally {
      await _detach(mount);
    }
  }

  /// 重启应用（新版本生效）。
  Future<void> restartApp() async {
    await Process.start(Platform.resolvedExecutable, const [],
        mode: ProcessStartMode.detached);
    exit(0);
  }
}
