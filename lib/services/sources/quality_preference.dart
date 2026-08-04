/// 全局音质偏好：'lossless' 最高（默认）/ '320k' / '128k'。
///
/// 各源选流器读取；无会员/未登录时本就沿降级链走到可用最高档。
/// 持久化在 SharedPreferences（键 app_quality，main 启动载入）。
library;

class QualityPreference {
  static String current = 'lossless';

  /// B站音质 id 上限（0 = 不限制）。
  static int get biliCapId => switch (current) {
        '320k' => 30280, // 192K AAC
        '128k' => 30232, // 132K AAC
        _ => 0,
      };

  /// 展示名。
  static String get label => switch (current) {
        '320k' => '320K',
        '128k' => '128K',
        _ => '无损优先',
      };
}
