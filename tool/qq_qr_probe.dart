/// QQ 扫码登录链路探针：生成二维码 → 打开图片 → 轮询 → 打印每步结果。
/// 运行：dart run tool/qq_qr_probe.dart（然后用手机 QQ 扫描弹出的图片）
library;

// ignore_for_file: avoid_print
import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:unison/services/sources/qqmusic/api/qq_login.dart';

Future<void> main() async {
  final jar = CookieJar();
  final login = QqQrLogin(jar);

  print('[1] 申请二维码...');
  final session = await login.generate();
  final png = File('/Users/krelar/Documents/kimi/tmp/qq_qr.png');
  await png.writeAsBytes(session.qrPng);
  print('    二维码已保存 ${png.path}（${session.qrPng.length} bytes），正在打开...');
  await Process.run('open', [png.path]);

  print('[2] 请用手机 QQ 扫码（等待 5 分钟）...');
  await for (final r in login.poll(session)) {
    print('    [${r.step.name}] ${r.message} ${r.uin}');
    if (r.step == QqQrStep.success ||
        r.step == QqQrStep.error ||
        r.step == QqQrStep.expired) {
      break;
    }
  }

  final cookies = await jar.loadForRequest(Uri.parse('https://y.qq.com'));
  print('[3] jar 中的 cookie: ${cookies.map((c) => c.name).join(', ')}');
  final key = cookies
      .where((c) => c.name == 'qqmusic_key' || c.name == 'qm_keyst')
      .map((c) => c.name)
      .firstOrNull;
  print(key != null ? 'PASS: 已换到音乐票据 $key' : 'FAIL: 未换到音乐票据');
}
