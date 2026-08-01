import 'dart:io';

import 'package:dio/dio.dart';

/// 应用内自动更新（macOS）：下载 DMG → 挂载 → 替换 .app（备份+回滚）→ 去隔离 → 重启。
///
/// 前置：App 需关闭沙盒（沙盒内无权 hdiutil/替换 /Applications）。
class SelfUpdater {
  SelfUpdater([Dio? dio]) : _dio = dio ?? Dio();

  final Dio _dio;

  /// 下载 DMG 到 [destPath]，[onProgress](received, total)。
  Future<String> download(
      String url, String destPath, void Function(int, int)? onProgress) async {
    await _dio.download(url, destPath, onReceiveProgress: onProgress);
    return destPath;
  }

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
