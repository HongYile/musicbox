import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'self_updater.dart';
import 'update_checker.dart';

const _kSkipVersionKey = 'update_skip_version';

/// 检查更新并在有新版本时弹窗提示。
///
/// [manual]=true（手动点击）时额外给出"已是最新/检查失败"反馈；
/// [manual]=false（启动自动检查）时静默，且尊重"不再提醒此版本"。
Future<void> checkAndPromptUpdate(BuildContext context,
    {bool manual = false}) async {
  void toast(String msg) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  final release = await UpdateChecker().checkLatest();
  if (release == null) {
    if (manual) toast('检查更新失败，请稍后再试');
    return;
  }
  if (!UpdateChecker.isNewer(release.tag, UpdateChecker.currentVersion)) {
    if (manual) toast('已是最新版本（${UpdateChecker.currentVersion}）');
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  if (!manual && prefs.getString(_kSkipVersionKey) == release.tag) return;

  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('发现新版本 ${release.tag}'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Text(release.notes.isEmpty ? '（无更新说明）' : release.notes,
              style: const TextStyle(fontSize: 13)),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await prefs.setString(_kSkipVersionKey, release.tag);
            if (dialogContext.mounted) Navigator.of(dialogContext).pop();
          },
          child: const Text('不再提醒此版本'),
        ),
        TextButton(
          onPressed: () {
            launchUrlString(release.htmlUrl);
            Navigator.of(dialogContext).pop();
          },
          child: const Text('去下载页'),
        ),
        if (release.dmgUrl != null && Platform.isMacOS)
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _runSelfUpdate(context, release);
            },
            child: const Text('自动更新'),
          )
        else
          FilledButton(
            onPressed: () {
              launchUrlString(release.dmgUrl ?? release.htmlUrl);
              Navigator.of(dialogContext).pop();
            },
            child: const Text('去下载'),
          ),
      ],
    ),
  );
}

/// 自动更新流程：进度弹窗 → 下载 → 安装 → 重启提示。
Future<void> _runSelfUpdate(BuildContext context, AppRelease release) async {
  final progress = ValueNotifier<(double, String)>((0, '准备下载…'));

  // 进度弹窗（不可手动关闭，防止中途打断）
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => ValueListenableBuilder<(double, String)>(
      valueListenable: progress,
      builder: (context, value, _) {
        final (p, status) = value;
        return AlertDialog(
          title: const Text('正在自动更新'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: p > 0 ? p : null),
              const SizedBox(height: 12),
              Text(status, style: const TextStyle(fontSize: 13)),
            ],
          ),
        );
      },
    ),
  ));

  void closeProgress() {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }

  try {
    final updater = SelfUpdater();
    final dmg =
        '${Directory.systemTemp.path}/musicbox-${release.tag}.dmg';
    progress.value = (0, '下载 ${release.tag}…');
    await updater.download(release.dmgUrl!, dmg, (received, total) {
      progress.value = (
        total > 0 ? received / total : -1,
        '下载中 ${(received / 1024 / 1024).toStringAsFixed(1)} MB'
            '${total > 0 ? ' / ${(total / 1024 / 1024).toStringAsFixed(1)} MB' : ''}'
      );
    });
    progress.value = (1, '安装中（替换旧版本）…');
    await updater.installFromDmg(dmg);
    closeProgress();

    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('更新完成'),
        content: Text('${release.tag} 已安装，重启后生效。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(),
              child: const Text('稍后重启')),
          FilledButton(
            onPressed: () => SelfUpdater().restartApp(),
            child: const Text('立即重启'),
          ),
        ],
      ),
    );
  } catch (e) {
    closeProgress();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('自动更新失败: $e（可改用「去下载页」手动安装）')));
    }
  }
}
