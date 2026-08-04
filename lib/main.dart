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
import 'services/player/smtc_bridge.dart';
import 'services/sources/bilibili/api/client.dart';
import 'services/sources/bilibili/api/endpoints.dart';
import 'services/sources/netease/api/ncm_client.dart';
import 'services/sources/netease/api/ncm_endpoints.dart';
import 'services/sources/qqmusic/api/qq_client.dart';
import 'services/sources/qqmusic/api/qq_endpoints.dart';
import 'services/sync/webdav_client.dart';
import 'services/update/update_prompt.dart';

/// 全局导航 key（应用内更新弹窗用）。
final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await _bootstrap();
  } catch (e, st) {
    // 启动即崩（缺组件/端口占用/存储失败等）以前是无声退出的"闪一下就没"，
    // 现在落日志 + 显示错误窗口，可直接定位。
    await _writeStartupCrash(e, st);
    runApp(_StartupErrorApp(error: '$e'));
  }
}

/// 启动崩溃日志：优先写到 exe 同目录（便携包可读写），失败退到临时目录。
Future<void> _writeStartupCrash(Object error, StackTrace stack) async {
  final content = 'Unison 启动失败\n'
      '时间: ${DateTime.now()}\n'
      '系统: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}\n'
      '错误: $error\n\n$stack\n';
  final sep = Platform.pathSeparator;
  final paths = [
    '${File(Platform.resolvedExecutable).parent.path}${sep}unison_startup_error.log',
    '${Directory.systemTemp.path}${sep}unison_startup_error.log',
  ];
  for (final p in paths) {
    try {
      await File(p).writeAsString(content);
      return;
    } catch (_) {}
  }
}

/// 启动失败兜底窗口：让用户看到错误而不是无声闪退。
class _StartupErrorApp extends StatelessWidget {
  const _StartupErrorApp({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Unison',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.red),
                const SizedBox(height: 16),
                const Text('启动失败',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                SelectableText(error, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                const Text(
                    '详细日志已写入程序目录下的 unison_startup_error.log，'
                    '请把它发给开发者。',
                    style: TextStyle(color: Colors.grey)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _bootstrap() async {
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

  // 播放模式持久化：启动恢复上次选择，切换时写回（默认列表循环）。
  final prefs = await SharedPreferences.getInstance();
  final savedMode = PlayMode.values.asNameMap()[prefs.getString('play_mode')];
  if (savedMode != null) playerService.setMode(savedMode);
  playerService.onModeChanged =
      (mode) => prefs.setString('play_mode', mode.name);

  // 本地曲库（歌单/下载记录）与下载服务。
  final docsDir = await getApplicationDocumentsDirectory();
  final libraryDb = LibraryDatabase.file('${docsDir.path}/library.db');
  final downloadService = DownloadService(
    BiliApi(client),
    libraryDb,
    dir: '${docsDir.path}/downloads',
  );

  // 坚果云同步：读取已保存凭证（拉取在 ProviderScope 就绪后进行，见 Builder）。
  final nutstoreEmail = await tokenStore.read(key: kNutstoreEmailKey);
  final nutstorePassword = await tokenStore.read(key: kNutstorePasswordKey);
  WebDavClient? webDavClient;
  if (nutstoreEmail != null &&
      nutstoreEmail.isNotEmpty &&
      nutstorePassword != null &&
      nutstorePassword.isNotEmpty) {
    webDavClient = WebDavClient(
        email: nutstoreEmail, appPassword: nutstorePassword);
  }

  // 后台播放 + 系统媒体控制：macOS/iOS/Android/Linux 走 audio_service；
  // Windows 走 smtc_windows（audio_service/audio_session 无 Windows 实现，
  // 直接调用会 MissingPluginException 导致启动崩溃）。
  if (Platform.isWindows) {
    final smtc = SmtcBridge(playerService);
    await smtc.init();
  } else {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    await AudioService.init(
      builder: () => MusicboxAudioHandler(playerService),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.krelar.unison.audio',
        androidNotificationChannelName: 'musicbox 播放',
        androidNotificationOngoing: true,
      ),
    );
  }

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
      child: Builder(
        builder: (context) {
          final container = ProviderScope.containerOf(context);

          // 启动拉取（配置了才执行）：完成后才打开防抖推送闸门，
          // 杜绝"未拉先推"把空库覆盖到云端。
          if (webDavClient != null) {
            unawaited(() async {
              try {
                final prefs = await SharedPreferences.getInstance();
                final lastSyncMs = prefs.getInt('nutstore_last_sync_ms');
                final (imported, _) = await container
                    .read(syncServiceProvider)
                    .pull(
                        localUpdatedAt: lastSyncMs == null
                            ? null
                            : DateTime.fromMillisecondsSinceEpoch(lastSyncMs));
                if (imported) {
                  await prefs.setInt('nutstore_last_sync_ms',
                      DateTime.now().millisecondsSinceEpoch);
                  container.read(playlistsProvider.notifier).refresh();
                }
              } catch (_) {
                // 同步失败不阻塞启动（闸门保持关闭）
                return;
              }
              container.read(syncPulledOnceProvider.notifier).state = true;
            }());
          }

          // 曲库变化 → 防抖推送（必须已成功拉取过一次才允许）
          container.listen(playlistsProvider, (prev, next) {
            if (container.read(syncPulledOnceProvider)) {
              container.read(syncServiceProvider).pushDebounced();
            }
          });

          // 启动后自动检查更新（各端都查；移动端弹窗引导去 GBox/下载页）
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final ctx = navigatorKey.currentContext;
            if (ctx != null) checkAndPromptUpdate(ctx);
          });
          return const MusicboxApp();
        },
      ),
    ),
  );
}

class MusicboxApp extends ConsumerWidget {
  const MusicboxApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'Unison',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      theme: _buildTheme(),
      darkTheme: _buildDarkTheme(),
      themeMode: mode,
      home: const HomeShell(),
    );
  }
}

/// 亮色主题：紫罗兰族（与暗色紫韵同族）。
///
/// 浅紫底 #F7F4FB、白卡、主色紫 #7C4DFF、点缀洋红 #EC407A、细边 #E6DFF2。
ThemeData _buildTheme() {
  const violet = Color(0xFF7C4DFF);
  const pink = Color(0xFFEC407A);
  const paper = Color(0xFFF7F4FB);
  const line = Color(0xFFE6DFF2);

  final scheme = ColorScheme.fromSeed(
    seedColor: violet,
    primary: violet,
    secondary: pink,
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
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Colors.white.withValues(alpha: 0.72),
      indicatorColor: violet.withValues(alpha: 0.14),
      selectedIconTheme: const IconThemeData(color: violet),
      selectedLabelTextStyle: const TextStyle(color: violet),
    ),
    dividerColor: line,
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  );
}

/// 暗色主题：紫韵（参考 UI 世界音乐播放器设计）。
///
/// 底 #14101F、面 #221A33、主色洋红 #EC407A、辅色紫 #9C7CFF；
/// 细边白 8%，与亮色共用同一套圆角体系。
ThemeData _buildDarkTheme() {
  const pink = Color(0xFFEC407A);
  const violet = Color(0xFF9C7CFF);
  const surface = Color(0xFF221A33);
  final line = Colors.white.withValues(alpha: 0.08);

  final scheme = ColorScheme.dark(
    primary: pink,
    secondary: violet,
    surface: surface,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFF14101F),
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
      backgroundColor: const Color(0xB31B1428),
      indicatorColor: pink.withValues(alpha: 0.20),
      selectedIconTheme: const IconThemeData(color: pink),
      selectedLabelTextStyle: const TextStyle(color: pink),
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
