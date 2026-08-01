import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pages/login_page.dart';
import 'pages/library_page.dart';
import 'pages/search_page.dart';
import 'widgets/player_hub_bar.dart';
import 'widgets/tech_background.dart';
import 'providers.dart';
import 'services/auth/bili_auth.dart';
import 'services/auth/cookie_refresh.dart';
import 'services/auth/token_store.dart';
import 'services/library/download_service.dart';
import 'services/library/library_db.dart';
import 'services/player/audio_proxy.dart';
import 'services/player/musicbox_audio_handler.dart';
import 'services/player/player_service.dart';
import 'services/sources/bilibili/api/client.dart';
import 'services/sources/bilibili/api/endpoints.dart';
import 'services/sources/netease/api/ncm_client.dart';
import 'services/sources/netease/api/ncm_endpoints.dart';
import 'services/sources/qqmusic/api/qq_client.dart';
import 'services/sources/qqmusic/api/qq_endpoints.dart';
import 'services/sync/library_sync.dart';
import 'services/sync/webdav_client.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  // cookie 持久化目录（应用支持目录/cookies）
  final supportDir = await getApplicationSupportDirectory();
  final cookieDir = Directory('${supportDir.path}/cookies');
  await cookieDir.create(recursive: true);

  final client = BiliClient.persistent(cookieDir.path);

  // 密钥存储：Keychain 优先，macOS entitlement 未生效时自动降级为文件，
  // 避免 -34018 导致登录态无法持久化。
  final tokenStore = TokenStore(fallbackDir: supportDir.path);

  // 网易云客户端（独立 cookie 目录）。
  final ncmCookieDir = Directory('${supportDir.path}/cookies_ncm');
  await ncmCookieDir.create(recursive: true);
  final ncmClient = NcmClient.persistent(ncmCookieDir.path);

  // QQ 音乐客户端（独立 cookie 目录）。
  final qqCookieDir = Directory('${supportDir.path}/cookies_qq');
  await qqCookieDir.create(recursive: true);
  final qqClient = QqClient.persistent(qqCookieDir.path);

  // cookie 刷新：登录态下前置检查（2 天节流），SESSDATA 临期自动续期，
  // 避免过期后被迫重新扫码；失败不阻塞任何请求。
  final cookieRefresh = CookieRefreshService(
    client,
    readRefreshToken: () =>
        tokenStore.read(key: BiliAuthService.kRefreshTokenKey),
    writeRefreshToken: (token) => tokenStore.write(
        key: BiliAuthService.kRefreshTokenKey, value: token),
    loadNextCheckAt: () async {
      final raw = await tokenStore.read(
          key: BiliAuthService.kNextCookieRefreshKey);
      final ms = int.tryParse(raw ?? '');
      return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    },
    persistNextCheckAt: (at) => tokenStore.write(
        key: BiliAuthService.kNextCookieRefreshKey,
        value: at.millisecondsSinceEpoch.toString()),
  );
  client.api.interceptors.add(cookieRefresh.interceptor());

  final proxy = AudioProxy(BiliApi(client));
  await proxy.start();
  final playerService =
      PlayerService(proxy, ncmApi: NcmApi(ncmClient), qqApi: QqApi(qqClient));

  // 本地曲库（歌单/下载记录）与下载服务。
  final docsDir = await getApplicationDocumentsDirectory();
  final libraryDb = LibraryDatabase.file('${docsDir.path}/library.db');
  final downloadService = DownloadService(
    BiliApi(client),
    libraryDb,
    dir: '${docsDir.path}/downloads',
  );

  // 坚果云同步：读取已保存凭证，配置了就在启动时拉取一次。
  final nutstoreEmail = await tokenStore.read(key: kNutstoreEmailKey);
  final nutstorePassword = await tokenStore.read(key: kNutstorePasswordKey);
  WebDavClient? webDavClient;
  if (nutstoreEmail != null &&
      nutstoreEmail.isNotEmpty &&
      nutstorePassword != null &&
      nutstorePassword.isNotEmpty) {
    webDavClient = WebDavClient(
        email: nutstoreEmail, appPassword: nutstorePassword);
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final lastSyncMs = prefs.getInt('nutstore_last_sync_ms');
        final (imported, _) = await LibrarySyncService(libraryDb, webDavClient)
            .pull(
                localUpdatedAt: lastSyncMs == null
                    ? null
                    : DateTime.fromMillisecondsSinceEpoch(lastSyncMs));
        if (imported) {
          await prefs.setInt('nutstore_last_sync_ms',
              DateTime.now().millisecondsSinceEpoch);
        }
      } catch (_) {
        // 同步失败不阻塞启动
      }
    }());
  }

  // 后台播放 + 系统媒体控制（macOS Now Playing/媒体键）：
  // audio_session 配置音频会话，audio_service 同步播放状态与元数据。
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());
  await AudioService.init(
    builder: () => MusicboxAudioHandler(playerService),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.krelar.musicbox.audio',
      androidNotificationChannelName: 'musicbox 播放',
      androidNotificationOngoing: true,
    ),
  );

  runApp(
    ProviderScope(
      overrides: [
        biliClientProvider.overrideWithValue(client),
        ncmClientProvider.overrideWithValue(ncmClient),
        qqClientProvider.overrideWithValue(qqClient),
        tokenStoreProvider.overrideWithValue(tokenStore),
        audioProxyProvider.overrideWithValue(proxy),
        playerServiceProvider.overrideWithValue(playerService),
        libraryDbProvider.overrideWithValue(libraryDb),
        downloadServiceProvider.overrideWithValue(downloadService),
        webDavClientProvider.overrideWith((ref) => webDavClient),
      ],
      child: const MusicboxApp(),
    ),
  );
}

class MusicboxApp extends ConsumerWidget {
  const MusicboxApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'musicbox',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      darkTheme: _buildDarkTheme(),
      themeMode: mode,
      home: const HomeShell(),
    );
  }
}

/// 主题：workspace/tech-style-guide.md 的浅色工程科技风。
///
/// 蓝 #2864F0 主色 / 青 #3CCBD9 点缀 / 纸蓝 #F5F8FC 底色；
/// 卡片 16px 圆角 + 细边 + 柔影；按钮 12px；胶囊徽章。
ThemeData _buildTheme() {
  const blue = Color(0xFF2864F0);
  const paper = Color(0xFFF5F8FC);
  const line = Color(0xFFDFE6EE);

  final scheme = ColorScheme.fromSeed(
    seedColor: blue,
    primary: blue,
    surface: Colors.white,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: paper,
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: line),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: const BorderSide(color: line),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: line),
      ),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: Colors.white,
      indicatorColor: Color(0x1A2864F0),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  );
}

/// 暗色主题：仿 QQ 音乐的深色高级感。
///
/// 底 #151518、面 #1F1F24、细边白 8%、主色青 #3CCBD9、辅色蓝紫 #8AAEFF；
/// 与亮色共用同一套圆角体系。
ThemeData _buildDarkTheme() {
  const cyan = Color(0xFF3CCBD9);
  const periwinkle = Color(0xFF8AAEFF);
  const surface = Color(0xFF1F1F24);
  final line = Colors.white.withValues(alpha: 0.08);

  final scheme = ColorScheme.dark(
    primary: cyan,
    secondary: periwinkle,
    surface: surface,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFF151518),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: line),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        side: BorderSide(color: line),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: line),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: const Color(0xB31A1A1E),
      indicatorColor: cyan.withValues(alpha: 0.18),
      selectedIconTheme: const IconThemeData(color: cyan),
      selectedLabelTextStyle: const TextStyle(color: cyan),
    ),
    dividerColor: line,
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  );
}

class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  static const _pages = [
    SearchPage(),
    LibraryPage(),
    LoginPage(),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(navIndexProvider);
    // 曲库变化 → 防抖推送坚果云（配置了才生效）
    ref.listen(playlistsProvider, (prev, next) {
      ref.read(syncServiceProvider).pushDebounced();
    });
    return Scaffold(
      backgroundColor: Colors.transparent, // 透出 TechBackground
      body: TechBackground(
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    // 左侧导航栏（QQ音乐/网易云桌面端布局）
                    NavigationRail(
                      backgroundColor:
                          Theme.of(context).brightness == Brightness.dark
                              ? const Color(0xB31A1A1E)
                              : Colors.white.withValues(alpha: 0.72),
                      selectedIndex: index,
                      onDestinationSelected: (i) =>
                          ref.read(navIndexProvider.notifier).state = i,
                      labelType: NavigationRailLabelType.all,
                      destinations: const [
                        NavigationRailDestination(
                            icon: Icon(Icons.search), label: Text('搜索')),
                        NavigationRailDestination(
                            icon: Icon(Icons.library_music), label: Text('曲库')),
                        NavigationRailDestination(
                            icon: Icon(Icons.person), label: Text('我的')),
                      ],
                    ),
                    VerticalDivider(
                        width: 1,
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.white.withValues(alpha: 0.08)
                            : const Color(0xFFDFE6EE)),
                    Expanded(
                        child: IndexedStack(index: index, children: _pages)),
                  ],
                ),
              ),
              // 底部通栏播放器（常驻，有播放内容时出现）
              const PlayerHubBar(),
            ],
          ),
        ),
      ),
    );
  }
}
