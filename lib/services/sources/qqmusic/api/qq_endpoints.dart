import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

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

class QqPlaylistSummary {
  const QqPlaylistSummary({
    required this.tid,
    required this.name,
    required this.songCount,
    required this.coverUrl,
  });

  final int tid;
  final String name;
  final int songCount;
  final String coverUrl;
}

class QqApi {
  QqApi(this.client);

  final QqClient client;

  Map<String, dynamic> _expectMap(Object? data, String tag) {
    // QQ 接口有时返回 text/plain 或 JSONP 包裹（jsonCallback({...})），
    // dio 不会自动解码，需要手动处理。
    if (data is String) {
      var text = data.trim();
      // JSONP 去壳：剥掉外层 callback( ... )
      if (!text.startsWith('{') && text.contains('(') && text.endsWith(')')) {
        final start = text.indexOf('(');
        final end = text.lastIndexOf(')');
        if (end > start) text = text.substring(start + 1, end);
      }
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {}
    }
    if (data is Map<String, dynamic>) return data;
    throw StateError('$tag 返回异常: $data');
  }

  /// 用户自建歌单列表（含"我喜欢" dirid=201）。需登录。
  Future<List<QqPlaylistSummary>> userPlaylists(String uin) async {
    final resp = await client.search.get(
      '/rsc/fcgi-bin/fcg_user_created_diss',
      queryParameters: {
        'hostUin': 0,
        'hostuin': uin,
        'sin': 0,
        'size': 200,
        'g_tk': 5381,
        'loginUin': 0,
        'format': 'json',
        'inCharset': 'utf8',
        'outCharset': 'utf-8',
        'notice': 0,
        'platform': 'yqq.json',
        'needNewCode': 0,
      },
      options: Options(headers: {'Referer': 'https://y.qq.com/portal/profile.html'}),
    );
    final body = _expectMap(resp.data, 'userPlaylists');
    if ((body['code'] as num?) == 4000) {
      throw StateError('该账号未公开歌单');
    }
    final data = body['data'];
    if (data is! Map<String, dynamic>) {
      throw StateError('获取歌单失败（需要登录）');
    }
    final list = (data['disslist'] as List? ?? const []);
    return [
      for (final d in list.whereType<Map>())
        QqPlaylistSummary(
          tid: (d['tid'] as num).toInt(),
          name: (d['diss_name'] ?? '') as String,
          songCount: (d['song_cnt'] as num?)?.toInt() ?? 0,
          coverUrl: (d['diss_cover'] ?? '') as String,
        ),
    ];
  }

  /// 歌单详情（全量曲目）。公开歌单无需登录。
  Future<List<QqSong>> playlistTracks(int tid) async {
    final resp = await client.search.get(
      '/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg',
      queryParameters: {'type': 1, 'utf8': 1, 'disstid': tid, 'loginUin': 0},
      options: Options(headers: {'Referer': 'https://y.qq.com/n/yqq/playlist'}),
    );
    final body = _expectMap(resp.data, 'playlistTracks');
    final cdlist = (body['cdlist'] as List? ?? const []);
    if (cdlist.isEmpty || cdlist.first is! Map) return const [];
    final songlist = (cdlist.first['songlist'] as List? ?? const []);
    return [
      for (final item in songlist.whereType<Map>())
        QqSong.fromSearchJson(item.cast<String, dynamic>()),
    ];
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
