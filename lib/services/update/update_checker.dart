import 'package:dio/dio.dart';

/// 更新源（Gitee 国内更快，默认；GitHub 备用）。
enum UpdateSource { gitee, github }

extension UpdateSourceX on UpdateSource {
  String get label => switch (this) {
        UpdateSource.gitee => 'Gitee（国内推荐）',
        UpdateSource.github => 'GitHub',
      };
}

/// 应用内更新检查：对比最新 Release。
class AppRelease {
  const AppRelease({
    required this.tag,
    required this.name,
    required this.notes,
    required this.htmlUrl,
    this.dmgUrl,
    this.ipaUrl,
  });

  final String tag;
  final String name;
  final String notes;
  final String htmlUrl;

  /// macOS DMG 附件直链（无则 null）。
  final String? dmgUrl;

  /// iOS IPA 附件直链（无则 null）。
  final String? ipaUrl;
}

class UpdateChecker {
  UpdateChecker({this.source = UpdateSource.gitee, Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 10),
              headers: {'User-Agent': 'musicbox-update-checker'},
            ));

  /// 当前应用版本（发版时与 pubspec.yaml、git tag 同步 bump）。
  static const currentVersion = '0.2.21';

  static const _repos = {
    UpdateSource.github: 'HongYile/unison',
    UpdateSource.gitee: 'Qq2454292378/unison',
  };

  final UpdateSource source;
  final Dio _dio;

  /// 拉取最新 Release；失败返回 null（静默，不影响使用）。
  Future<AppRelease?> checkLatest() async {
    return switch (source) {
      UpdateSource.github => _checkGithub(),
      UpdateSource.gitee => _checkGitee(),
    };
  }

  Future<AppRelease?> _checkGithub() async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
          'https://api.github.com/repos/${_repos[UpdateSource.github]}/releases/latest');
      final data = resp.data;
      if (data == null) return null;
      return AppRelease(
        tag: (data['tag_name'] ?? '') as String,
        name: (data['name'] ?? '') as String,
        notes: (data['body'] ?? '') as String,
        htmlUrl: (data['html_url'] ?? '') as String,
        dmgUrl: _findAsset(data['assets'] as List? ?? const [], '.dmg'),
        ipaUrl: _findAsset(data['assets'] as List? ?? const [], '.ipa'),
      );
    } catch (_) {
      return null;
    }
  }

  Future<AppRelease?> _checkGitee() async {
    try {
      final resp = await _dio.get<List<dynamic>>(
        'https://gitee.com/api/v5/repos/${_repos[UpdateSource.gitee]}/releases',
        queryParameters: {'direction': 'desc', 'limit': 1},
      );
      final list = resp.data;
      if (list == null || list.isEmpty || list.first is! Map) return null;
      final data = list.first as Map<String, dynamic>;
      return AppRelease(
        tag: (data['tag_name'] ?? '') as String,
        name: (data['name'] ?? '') as String,
        notes: (data['body'] ?? '') as String,
        htmlUrl: (data['html_url'] ?? '') as String,
        dmgUrl: _findAsset(data['assets'] as List? ?? const [], '.dmg'),
        ipaUrl: _findAsset(data['assets'] as List? ?? const [], '.ipa'),
      );
    } catch (_) {
      return null;
    }
  }

  String? _findAsset(List<dynamic> assets, String suffix) {
    for (final a in assets) {
      if (a is Map && (a['name'] ?? '').toString().endsWith(suffix)) {
        // GitHub 用 browser_download_url；Gitee attach_files 同名字段，
        // 部分版本用 download_url，做个兼容。
        final url = a['browser_download_url'] ?? a['download_url'];
        if (url != null && '$url'.isNotEmpty) return '$url';
      }
    }
    return null;
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
