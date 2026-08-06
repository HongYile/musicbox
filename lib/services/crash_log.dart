/// 运行时崩溃/异常日志：Dart 层异常（FlutterError/未捕获异常）+
/// 播放失败等关键事件，带时间戳落盘。
///
/// 日志文件：应用支持目录/unison_runtime.log（超 2MB 截断保留尾部）。
/// macOS 原生崩溃（段错误等 Dart 抓不到的）由系统在
/// ~/Library/Logs/DiagnosticReports/Unison-*.ips 记录，
/// 启动时检测到新的 .ips 会把路径写进我们的日志。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

class CrashLog {
  CrashLog._();

  static File? _file;

  /// 日志文件完整路径（未初始化返回 null）。
  static String? get path => _file?.path;

  static Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    final f = File('${dir.path}/unison_runtime.log');
    // 超 2MB 截断（保留尾部 1MB）
    try {
      if (await f.exists() && await f.length() > 2 * 1024 * 1024) {
        final bytes = await f.readAsBytes();
        final tail = bytes.sublist(bytes.length - 1024 * 1024);
        await f.writeAsBytes(tail, flush: true);
      }
    } catch (_) {}
    _file = f;
    log('════ 应用启动（v$appVersionMarker）════');
    await _scanNativeCrashReports();
  }

  /// 版本标记由 main 设置（日志里好对上版本）。
  static String appVersionMarker = '';

  /// 追加一条日志（带时间戳；err/stack 可选）。永不抛异常。
  static void log(String msg, [Object? err, StackTrace? st]) {
    final f = _file;
    if (f == null) return;
    final buf = StringBuffer('[${DateTime.now().toIso8601String()}] $msg');
    if (err != null) buf.write('\n  错误: $err');
    if (st != null) buf.write('\n$st');
    try {
      f.writeAsStringSync('$buf\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  /// macOS：扫描系统原生崩溃报告，有上次启动后新生成的就记录路径。
  static Future<void> _scanNativeCrashReports() async {
    if (!Platform.isMacOS) return;
    try {
      final home = Platform.environment['HOME'] ?? '';
      final dir = Directory('$home/Library/Logs/DiagnosticReports');
      if (!await dir.exists()) return;
      final cutoff = DateTime.now().subtract(const Duration(days: 1));
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        if (!name.startsWith('Unison') || !name.endsWith('.ips')) continue;
        final mtime = await e.lastModified();
        if (mtime.isAfter(cutoff)) {
          log('检测到系统崩溃报告: ${e.path}（$mtime）');
        }
      }
    } catch (_) {}
  }
}
