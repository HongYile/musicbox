import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher_string.dart';

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
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('稍后'),
        ),
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
