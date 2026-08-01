import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// 轻量 WebDAV 客户端（坚果云）。
///
/// 认证：HTTP Basic（邮箱 + 应用密码，坚果云 安全选项→第三方应用管理 生成）。
/// 只实现同步所需的最小操作集：MKCOL / PUT / GET / PROPFIND(存在性与修改时间)。
class WebDavClient {
  WebDavClient({
    required this.email,
    required this.appPassword,
    String baseUrl = 'https://dav.jianguoyun.com/dav',
    Dio? dio,
  }) : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: baseUrl,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
              headers: {
                'Authorization':
                    'Basic ${base64Encode(utf8.encode('$email:$appPassword'))}',
              },
              // 坚果云对不存在路径返回 404、MKCOL 已存在返回 405，均为正常流
              validateStatus: (_) => true,
            ));

  final String email;
  final String appPassword;
  final Dio _dio;

  /// 创建目录（已存在/父级缺失都不视为错误）。
  Future<void> mkcol(String path) async {
    await _dio.request<void>(path, options: Options(method: 'MKCOL'));
  }

  /// 上传文件（覆盖写）。成功返回 true。
  Future<bool> put(String path, List<int> bytes) async {
    final resp = await _dio.put<void>(path,
        data: Stream.fromIterable([bytes]),
        options: Options(headers: {'Content-Length': bytes.length}));
    final code = resp.statusCode ?? 0;
    return code >= 200 && code < 300;
  }

  /// 下载文件；不存在返回 null。
  Future<Uint8List?> get(String path) async {
    final resp = await _dio.get<List<int>>(path,
        options: Options(responseType: ResponseType.bytes));
    if (resp.statusCode == 404) return null;
    if ((resp.statusCode ?? 0) >= 400) {
      throw StateError('WebDAV GET $path 失败: ${resp.statusCode}');
    }
    return Uint8List.fromList(resp.data ?? const []);
  }

  /// 文件最后修改时间（PROPFIND getlastmodified）；不存在返回 null。
  Future<DateTime?> lastModified(String path) async {
    final resp = await _dio.request<String>(
      path,
      data: '''<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:"><d:prop><d:getlastmodified/></d:prop></d:propfind>''',
      options: Options(
        method: 'PROPFIND',
        headers: {'Depth': '0', 'Content-Type': 'application/xml'},
      ),
    );
    if (resp.statusCode == 404) return null;
    final body = resp.data ?? '';
    final match =
        RegExp(r'getlastmodified[^>]*>([^<]+)<').firstMatch(body);
    if (match == null) return null;
    return DateTime.tryParse(match.group(1)!);
  }
}
