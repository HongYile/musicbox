import 'dart:convert';
import 'dart:math';

import 'qq_client.dart';
import '../models.dart';

/// 音质前缀表（蓝本 typeMap）：flac/ape/320/128/m4a。
const Map<String, (String ext, int qualityId)> kQqFileTypes = {
  'F000': ('flac', 99200), // 无损（需绿钻）
  'A000': ('ape', 99204), // ape（少见）
  'M800': ('mp3', 99201), // 320K
  'M500': ('mp3', 99202), // 128K
  'C400': ('m4a', 99203), // m4a
};

/// 降级链：无损 → 320K → 128K。
const List<String> kQqQualityChain = ['F000', 'M800', 'M500'];

class QqApi {
  QqApi(this.client);

  final QqClient client;

  Map<String, dynamic> _expectMap(Object? data, String tag) {
    // QQ 接口有时返回 text/plain，dio 不会自动解码，需要手动 jsonDecode。
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {}
    }
    if (data is Map<String, dynamic>) return data;
    throw StateError('$tag 返回异常: $data');
  }

  /// 单曲搜索（client_search_cp，t=0）。
  Future<List<QqSong>> searchSongs(String keyword, {int page = 1}) async {
    final resp = await client.search.get(
      '/soso/fcgi-bin/client_search_cp',
      queryParameters: {
        'format': 'json',
        'n': 20,
        'p': page,
        'w': keyword,
        'cr': 1,
        'g_tk': 5381,
        't': 0,
      },
    );
    final body = _expectMap(resp.data, 'search');
    final list = ((body['data']?['song']?['list']) as List? ?? const []);
    return [
      for (final item in list)
        if (item is Map<String, dynamic> &&
            (item['songmid'] ?? '') != '')
          QqSong.fromSearchJson(item),
    ];
  }

  String _guid() =>
      (Random().nextInt(900000000) + 100000000).toString();

  /// 取流：vkey.GetVkeyServer。
  ///
  /// 返回完整播放 URL；`purl` 为空（无权限/VIP 限定）返回 null。
  /// 参考蓝本 routes/song.js（GPL-3.0，仅参考参数自写）。
  Future<String?> songUrl(QqSong song, String prefix) async {
    final type = kQqFileTypes[prefix];
    if (type == null) throw ArgumentError('未知音质前缀: $prefix');
    final uin = await client.uin();
    final key = await client.musicKey();
    final filename = '$prefix${song.songMid}${song.mediaMid}.${type.$1}';

    final resp = await client.musicu.post(
      '/cgi-bin/musicu.fcg',
      data: {
        'req_0': {
          'module': 'vkey.GetVkeyServer',
          'method': 'CgiGetVkey',
          'param': {
            'filename': [filename],
            'guid': _guid(),
            'songmid': [song.songMid],
            'songtype': [0],
            'uin': uin,
            'loginflag': 1,
            'platform': '20',
          },
        },
        'comm': {
          'uin': uin,
          'format': 'json',
          'ct': 19,
          'cv': 0,
          'authst': ?key,
        },
      },
    );
    final body = _expectMap(resp.data, 'vkey');
    final data = body['req_0']?['data'];
    if (data is! Map<String, dynamic>) return null;
    final midurlinfo = (data['midurlinfo'] as List? ?? const []);
    if (midurlinfo.isEmpty || midurlinfo.first is! Map) return null;
    final purl = (midurlinfo.first['purl'] ?? '') as String;
    if (purl.isEmpty) return null; // 无权限 / 仅试听

    // sip 节点：避开蓝本中不稳定的 ws- 前缀节点
    final sips = (data['sip'] as List? ?? const []).whereType<String>();
    final host = sips.firstWhere((s) => !s.startsWith('http://ws'),
        orElse: () => sips.isNotEmpty ? sips.first : '');
    if (host.isEmpty) return null;
    return '$host$purl';
  }
}
