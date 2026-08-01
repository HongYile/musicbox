import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'self_updater.dart';
import 'update_checker.dart';

const _kSkipVersionKey = 'update_skip_version';

/// shared_preferences 中更新源（'gitee' 默认 / 'github'）。
const kUpdateSourceKey = 'update_source';

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

  final prefs = await SharedPreferences.getInstance();
  final source = prefs.getString(kUpdateSourceKey) == 'github'
      ? UpdateSource.github
      : UpdateSource.gitee;
  final release = await UpdateChecker(source: source).checkLatest();
  if (release == null) {
    if (manual) toast('检查更新失败，请稍后再试');
    return;
  }
  if (!UpdateChecker.isNewer(release.tag, UpdateChecker.currentVersion)) {
    if (manual) toast('已是最新版本（${UpdateChecker.currentVersion}）');
    return;
  }

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
            child: const Text('更新'),
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

/// 自动更新流程：进度弹窗（百分比+暂停/继续/取消）→ 安装 → 重启提示。
Future<void> _runSelfUpdate(BuildContext context, AppRelease release) async {
  final dmg = '${Directory.systemTemp.path}/musicbox-${release.tag}.dmg';
  final dl = ResumableDownload(release.dmgUrl!, dmg);
  final progress = ValueNotifier<(int, int, String)>((0, -1, '准备下载…'));
  // 进度弹窗只许关闭一次（取消按钮与异常路径都会尝试关，防止把主页路由顶掉黑屏）
  var progressOpen = true;

  void closeProgress() {
    if (progressOpen && context.mounted) {
      progressOpen = false;
      Navigator.of(context, rootNavigator: true).pop();
    }
  }

  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => ValueListenableBuilder<(int, int, String)>(
      valueListenable: progress,
      builder: (context, value, _) {
        final (received, total, status) = value;
        final ratio = total > 0 ? received / total : null;
        final mb = (received / 1024 / 1024).toStringAsFixed(1);
        final totalMb =
            total > 0 ? ' / ${(total / 1024 / 1024).toStringAsFixed(1)}' : '';
        final percent =
            ratio != null ? '${(ratio * 100).toStringAsFixed(0)}%' : '';
        return AlertDialog(
          title: const Text('正在更新'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: ratio),
              const SizedBox(height: 12),
              Text('$status  $mb$totalMb MB  $percent',
                  style: const TextStyle(fontSize: 13)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                if (dl.paused) {
                  dl.resume();
                  progress.value = (dl.received, dl.total, '继续下载…');
                } else {
                  dl.pause();
                  progress.value = (dl.received, dl.total, '已暂停');
                }
              },
              child: Text(dl.paused ? '继续' : '暂停'),
            ),
            TextButton(
              onPressed: () {
                dl.cancel();
                closeProgress();
              },
              child: const Text('取消'),
            ),
          ],
        );
      },
    ),
  ).then((_) => progressOpen = false));

  try {
    await dl.run((received, total) {
      if (!dl.paused) {
        progress.value = (received, total, '下载 ${release.tag} 中…');
      }
    });
    progress.value = (dl.received, dl.total, '安装中（替换旧版本）…');
    await SelfUpdater().installFromDmg(dmg);
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
          SnackBar(content: Text('更新失败: $e（可改用「去下载页」手动安装）')));
    }
  }
}
