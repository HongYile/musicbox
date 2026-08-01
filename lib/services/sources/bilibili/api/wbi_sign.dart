import 'dart:convert';

import 'package:crypto/crypto.dart';

/// B站 WBI 请求签名（纯 Dart 实现）。
///
/// 算法参考 B站 web 端公开行为：
/// 1. img_key + sub_key 拼接后按 64 位重排表取前 32 位得 mixin_key；
/// 2. 参数加 wts（秒级时间戳），按 key 排序，过滤 value 中的 !'()* ，
///    以 RFC3986 大写百分号编码（空格 %20）拼成 query；
/// 3. w_rid = MD5(query + mixin_key)。
class WbiSign {
  WbiSign._();

  static const List<int> mixinKeyEncTab = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, //
    33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
    61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
    36, 20, 34, 44, 52,
  ];

  /// 从 nav 接口 wbi_img 的 url 中提取 key（文件名去掉扩展名）。
  static String keyFromUrl(String url) {
    final fileName = url.substring(url.lastIndexOf('/') + 1);
    final dot = fileName.indexOf('.');
    return dot == -1 ? fileName : fileName.substring(0, dot);
  }

  /// img_key + sub_key 重排取前 32 位。
  static String mixinKey(String imgKey, String subKey) {
    final orig = imgKey + subKey;
    final buf = StringBuffer();
    for (final i in mixinKeyEncTab) {
      buf.write(orig[i]);
    }
    return buf.toString().substring(0, 32);
  }

  /// 对单个分量做百分号编码：大写 hex、空格 %20，与 JS encodeURIComponent 对齐。
  static String encodeComponent(String s) {
    // Dart 的 Uri.encodeComponent 即 UTF-8 + 大写 hex + 空格 %20，
    // 但不编码 !'()* —— 这些字符在 value 中已提前过滤，key 不会出现。
    return Uri.encodeComponent(s);
  }

  /// 生成签名后的参数（新 map，不改入参）。返回含 wts 与 w_rid。
  static Map<String, dynamic> sign(
    Map<String, dynamic> params,
    String mixin, {
    int? wts,
  }) {
    final full = Map<String, dynamic>.from(params)
      ..['wts'] = wts ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;

    final keys = full.keys.toList()..sort();
    final query = keys.map((k) {
      final value = full[k].toString().replaceAll(RegExp(r"[!'()*]"), '');
      return '${encodeComponent(k)}=${encodeComponent(value)}';
    }).join('&');

    full['w_rid'] = md5.convert(utf8.encode(query + mixin)).toString();
    return full;
  }
}
