import 'package:dio/dio.dart';

/// 应用内更新检查：对比 GitHub Releases 最新版本。
class AppRelease {
  const AppRelease({
    required this.tag,
    required this.name,
    required this.notes,
    required this.htmlUrl,
    this.dmgUrl,
  });

  final String tag;
  final String name;
  final String notes;
  final String htmlUrl;

  /// macOS DMG 附件直链（无则 null）。
  final String? dmgUrl;
}

class UpdateChecker {
  UpdateChecker([Dio? dio])
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 10),
              headers: {'User-Agent': 'musicbox-update-checker'},
            ));

  /// 当前应用版本（发版时与 pubspec.yaml、git tag 同步 bump）。
  static const currentVersion = '0.1.0';

  static const _repo = 'HongYile/musicbox';

  final Dio _dio;

  /// 拉取最新 Release；失败返回 null（静默，不影响使用）。
  Future<AppRelease?> checkLatest() async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
          'https://api.github.com/repos/$_repo/releases/latest');
      final data = resp.data;
      if (data == null) return null;
      String? dmgUrl;
      for (final a in (data['assets'] as List? ?? const [])) {
        if (a is Map && (a['name'] ?? '').toString().endsWith('.dmg')) {
          dmgUrl = (a['browser_download_url'] ?? '') as String;
          break;
        }
      }
      return AppRelease(
        tag: (data['tag_name'] ?? '') as String,
        name: (data['name'] ?? '') as String,
        notes: (data['body'] ?? '') as String,
        htmlUrl: (data['html_url'] ?? '') as String,
        dmgUrl: dmgUrl,
      );
    } catch (_) {
      return null;
    }
  }

  /// semver 三段比较：latest 是否比 current 新（忽略前导 v 与后缀）。
  static bool isNewer(String latest, String current) {
    List<int> parse(String v) {
      final core =
          v.replaceFirst(RegExp(r'^[vV]'), '').split('-').first.split('+').first;
      final parts = core.split('.').map((s) => int.tryParse(s) ?? 0).toList();
      while (parts.length < 3) {
        parts.add(0);
      }
      return parts.take(3).toList();
    }

    final l = parse(latest), c = parse(current);
    for (var i = 0; i < 3; i++) {
      if (l[i] != c[i]) return l[i] > c[i];
    }
    return false;
  }
}
