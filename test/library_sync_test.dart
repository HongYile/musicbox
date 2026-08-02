import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:unison/services/library/library_db.dart';
import 'package:unison/services/sync/library_sync.dart';
import 'package:unison/services/sync/webdav_client.dart';

void main() {
  group('LibrarySyncService 导出/导入', () {
    test('roundtrip：导出 → 导入到空库，歌单与曲目还原', () {
      final db1 = LibraryDatabase.memory();
      final id = db1.createPlaylist('测试歌单');
      db1.addTrack(
          playlistId: id,
          sourceId: 'bilibili',
          trackId: 'BV1xx',
          title: '歌A',
          artist: 'UP主',
          cover: 'http://c',
          durationSec: 100,
          cid: 123);
      db1.addTrack(
          playlistId: id,
          sourceId: 'qqmusic',
          trackId: 'mid1',
          title: '歌B',
          cid: 0);

      final sync1 = LibrarySyncService(db1, null);
      final json = sync1.exportJson(themeModeIndex: 2, selectedSource: 'qqmusic');
      expect(json['version'], 1);
      expect(json['settings']['themeMode'], 2);

      final db2 = LibraryDatabase.memory();
      final sync2 = LibrarySyncService(db2, null);
      final imported = sync2.importJson(
          jsonDecode(jsonEncode(json)) as Map<String, dynamic>);
      expect(imported, 1);

      final playlists = db2.listPlaylists();
      expect(playlists.single.name, '测试歌单');
      final tracks = db2.tracksOf(playlists.single.id);
      expect(tracks.length, 2);
      expect(tracks.first.title, '歌A');
      expect(tracks.first.cid, 123);
    });

    test('导入合并：同名人歌单不重复创建，曲目去重', () {
      final db = LibraryDatabase.memory();
      final sync = LibrarySyncService(db, null);
      final json = {
        'playlists': [
          {
            'name': 'A',
            'tracks': [
              {'sourceId': 'bilibili', 'trackId': 'BV1', 'title': 't', 'cid': 1},
            ],
          },
        ],
      };
      sync.importJson(json);
      sync.importJson(json); // 再次导入
      expect(db.listPlaylists().length, 1);
      expect(db.tracksOf(db.listPlaylists().first.id).length, 1);
    });
  });

  group('WebDavClient（本地 mock 服务器）', () {
    late HttpServer server;
    late WebDavClient client;
    final store = <String, List<int>>{};

    setUp(() async {
      store.clear();
      server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) async {
        final auth = req.headers.value('authorization');
        if (auth == null || !auth.startsWith('Basic ')) {
          req.response.statusCode = 401;
          await req.response.close();
          return;
        }
        switch (req.method) {
          case 'MKCOL':
            req.response.statusCode = 201;
          case 'PUT':
            final bytes = await req
                .fold<List<int>>([], (all, part) => all..addAll(part));
            store[req.uri.path] = bytes;
            req.response.statusCode = 204;
          case 'GET':
            final data = store[req.uri.path];
            if (data == null) {
              req.response.statusCode = 404;
            } else {
              req.response.add(data);
            }
          case 'PROPFIND':
            if (!store.containsKey(req.uri.path)) {
              req.response.statusCode = 404;
            } else {
              req.response.statusCode = 207;
              req.response.write(
                  '<d:getlastmodified>2026-08-01T00:00:00Z</d:getlastmodified>');
            }
          default:
            req.response.statusCode = 405;
        }
        await req.response.close();
      });
      client = WebDavClient(
        email: 'u@test.com',
        appPassword: 'pwd',
        baseUrl: 'http://127.0.0.1:${server.port}/dav',
      );
    });

    tearDown(() => server.close(force: true));

    test('MKCOL + PUT + GET roundtrip', () async {
      await client.mkcol('/musicbox');
      expect(await client.put('/musicbox/library.json', utf8.encode('{"a":1}')),
          isTrue);
      final got = await client.get('/musicbox/library.json');
      expect(utf8.decode(got!), '{"a":1}');
    });

    test('GET 不存在返回 null；PROPFIND 取修改时间', () async {
      expect(await client.get('/none.json'), isNull);
      expect(await client.lastModified('/none.json'), isNull);
      await client.put('/a.json', [1, 2, 3]);
      expect(await client.lastModified('/a.json'), isNotNull);
    });

    test('pull：远程不存在→不导入；存在且较新→导入', () async {
      final db = LibraryDatabase.memory();
      final sync = LibrarySyncService(db, client);
      expect((await sync.pull()).$1, isFalse);

      final src = LibrarySyncService(LibraryDatabase.memory(), null);
      final json = src.exportJson();
      json['playlists'] = [
        {
          'name': '云端歌单',
          'tracks': [
            {'sourceId': 'bilibili', 'trackId': 'BV9', 'title': '云歌', 'cid': 1}
          ]
        }
      ];
      await client.put('/musicbox/library.json',
          utf8.encode(jsonEncode(json)));
      final (imported, remoteAt) = await sync.pull();
      expect(imported, isTrue);
      expect(remoteAt, isNotNull);
      expect(db.listPlaylists().single.name, '云端歌单');
    });
  });
}
