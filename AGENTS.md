# musicbox

个人自用的跨平台（Win/macOS/iOS/Android）聚合音乐播放器。第一版只接 B站音源：
扫码登录自己的 B站大会员账号，搜索视频/音乐稿件，优先拉取 Hi-Res 无损音频流。

## 架构（已定，不要偏离）

1. **本地 HTTP 流代理**（`lib/services/player/audio_proxy.dart`）
   - media_kit 不直接播 B站 CDN URL，而是播 `http://127.0.0.1:<port>/stream/<bvid>/<cid>`。
   - 内嵌 shelf 服务收到请求时才做 取流→选流，然后 **302 重定向** 到真实 URL（真实 URL 已带 upsig 签名）。
   - 流 URL 约 120 分钟过期（`deadline` 参数），代理层缓存并在临近过期（60s 余量）时自动重新解析，播放器无感。
   - **CDN 故障切换**（`CdnProber`）：重定向前先对候选（主 URL + backupUrls，已按 upos-sz- 优先）
     做 HEAD 探测（405 降级 GET，带 Referer/UA，5s 超时），403/404/超时即切下一个；
     全部失效才重新走一次 playurl 解析换新候选，仍失败返回 502。
   - 播放器请求真实 CDN 需要 `Referer: https://www.bilibili.com` 和桌面 Chrome UA —— 通过 media_kit `Media(httpHeaders:)` 传入，mpv 跟随 302 时保留 header。
2. **音源编译期内置**：`MusicSource` 抽象接口在 `lib/services/sources/music_source.dart`
   （id/name/login/search/getStream/pagelist），B站为第一个实现（`bilibili/bilibili_source.dart`）。不做运行时插件。
3. **WBI 签名纯 Dart 实现**（`lib/services/sources/bilibili/api/wbi_sign.dart`）
   - 64 位重排表 + wts(秒) + 参数按 key 排序 + 大写百分号编码（空格 %20，过滤 `!'()*`）+ MD5(query+mixin_key)。
   - img_key/sub_key 从 `x/web-interface/nav` 的 `data.wbi_img` 取（未登录也有），缓存 12h。
   - 响应 data 里出现 `v_voucher` 视为风控，抛 `RiskControlException`。
4. **凭据安全存储**：SESSDATA 等 cookie 用 PersistCookieJar（path_provider 应用目录下 `cookies/`）；
   refresh_token 必须进 flutter_secure_storage。
5. **Cookie 自动刷新**（`lib/services/auth/cookie_refresh.dart`，纯 Dart）
   - 拦截器挂在 `client.api` 上（main.dart 接线）：仅登录态、成功后续 2 天节流
     （nextCheckRefreshTime 持久化在 secure_storage）、30 秒单飞窗口防并发，失败绝不阻塞请求。
   - 流程：固定 RSA 公钥（1024 位，OAEP/SHA-256，pointycastle）加密 `refresh_<毫秒时间戳>`
     → GET `www.bilibili.com/correspond/1/<hex>` 抠 `<div id="1-name">` 得 refresh_csrf
     → POST passport `web/cookie/refresh`（新 cookie 由 CookieManager 入库，新 refresh_token 落盘）
     → POST `web/confirm/refresh`（refresh_token 传**旧**值）。
6. **不用 build_runner/freezed/drift codegen**：手写不可变模型 + fromJson（`bilibili/models.dart`），
   本地数据库手写 DAO + sqlite3（`services/library/library_db.dart`）。后续再评估 codegen。
7. **本地曲库 / 歌单 / 下载**（`lib/services/library/`，纯 Dart）
   - `library_db.dart`：手写 DAO + sqlite3，三表 `playlists` / `playlist_tracks` / `downloads`；
     曲目以 `(sourceId, trackId=bvid, cid)` 去重，收藏夹导入的条目 cid=0，播放时再经 pagelist 解析。
   - `download_service.dart`：选最优流（Hi-Res 优先）→ 带 Referer/UA 逐个候选 URL 下载原始流
     （**不转码**）到 文档目录 `downloads/<bvid>_<音质id>.<flac|m4a>`，封面存 `<bvid>.jpg`，
     进度经 `progressStream` 广播，记录写 `downloads` 表（downloading/completed/failed）。
     ffmpeg 转码与 ID3 标签写入**留待后续**。
8. **收藏夹导入**：`endpoints.dart` 的 `favFolders`（`/x/v3/fav/folder/created/list-all`，WBI）
   / `favFolderContent`（`/x/v3/fav/resource/list` 分页，WBI），登录态下把收藏夹一键导入为本地歌单。

## 音质选择降级链（`stream_select.dart`）

`dash.flac.audio`(Hi-Res 30251) → `dash.dolby.audio[0]`(30250) → `dash.audio` 按 bandwidth 降序，
同码率按音质 id 表 `[30257,30216,30259,30260,30232,30280,30250,30251]` 靠后者优先。
backup_url 中 host 含 `upos-sz-` 的优先于 mcdn。
匿名只能拿到 192K 及以下；Hi-Res 需要大会员登录态。

## 目录约定

```
lib/
  main.dart                       # 引导：MediaKit/path_provider/BiliClient/AudioProxy/PlayerService/
                                  #   LibraryDatabase/DownloadService 注入 ProviderScope
  providers.dart                  # Riverpod providers（登录态/搜索/播放流/歌单/下载）
  pages/                          # login / search / player / favorites / library（功能性 UI）
  widgets/add_to_playlist_dialog.dart  # "加入歌单"对话框（搜索/收藏/播放页复用）
  services/
    auth/bili_auth.dart           # 扫码登录 + 登录态恢复
    auth/cookie_refresh.dart      # cookie 自动刷新（拦截器 + 节流/单飞，纯 Dart）
    library/library_db.dart       # 手写 DAO + sqlite3：playlists/playlist_tracks/downloads
    library/download_service.dart # 最优流原始文件下载 + 封面 + 进度广播（纯 Dart）
    player/audio_proxy.dart       # 本地流代理（shelf，302 + CDN 故障切换 CdnProber）
    player/player_service.dart    # media_kit 封装 + 顺序队列（playQueue/next）+ 本地文件播放
    player/musicbox_audio_handler.dart  # audio_service 系统媒体控制接线（Now Playing/媒体键）
    sources/
      music_source.dart           # 音源抽象
      bilibili/
        api/wbi_sign.dart         # WBI 签名（纯 Dart）
        api/client.dart           # api./passport. 两个 dio + CookieJar + UA/Referer + WBI 拦截器
        api/endpoints.dart        # nav/pagelist/wbi·playurl/search/qrcode
        stream_select.dart        # 选流降级链（纯 Dart）
        models.dart               # 手写模型
        bilibili_source.dart      # MusicSource 实现
tool/smoke_test.dart              # 无界面联调脚本（纯 Dart，dart run 可执行）
test/                             # wbi_sign_test / stream_select_test
```

- `api/` 与 `stream_select.dart`、`models.dart`、`auth/cookie_refresh.dart`、`services/library/` 必须保持**纯 Dart**
  （不 import Flutter），以便 `tool/smoke_test.dart` 用 `dart run` 直接跑。

## 许可证红线

**只参考思想，禁止复制代码**：biu（PolyForm-NC 非商业）、QQMusicApi（GPL）、MusicFree（AGPL）。
本仓所有代码均为 Dart 重写。

## 常用命令

```bash
export PATH="/opt/homebrew/bin:$PATH"
# 本机 pub.dev 被 DNS 污染（解析到 0.0.0.0），装包需走镜像：
export PUB_HOSTED_URL="https://mirrors.tuna.tsinghua.edu.cn/dart-pub"   # 仅 pub get/add 时需要
flutter pub get
flutter analyze
flutter test                        # WBI/选流/cookie 刷新/CDN 切换/library_db 单测
dart run tool/smoke_test.dart       # 匿名全链路：nav→签名→搜索→pagelist→playurl→选流
dart run tool/smoke_test.dart 关键词
flutter build macos --debug         # 需要完整 Xcode（CLT 不够）
```

## 已知事项

- macOS 沙盒需要 `network.client`（API 请求）+ `network.server`（localhost 代理）entitlement，两个 .entitlements 文件都已加。
- **不要**手动给客户端种 `buvid3` cookie（`x/frontend/finger/spi`）：实测会把匿名搜索带进风控
  （v_voucher）。匿名不带 cookie 反而正常；如需 buvid3 应由响应 Set-Cookie 自然写入。
- nav 接口匿名返回 `code=-101` 但 data 仍有效（isLogin=false），属正常。
- macOS 后台播放 / 系统媒体控制已用 audio_service + audio_session 接线
  （main.dart：`AudioSession.configure(music)` + `AudioService.init(MusicboxAudioHandler)`；
  audio_service macOS 要求部署目标 ≥10.12.2，本项目 10.15 满足，Podfile 无需改动）。
  **⚠ 未经构建验证**：本机无 Xcode，以上仅保证 `flutter analyze` 零告警，
  首次 `flutter build macos` 时如遇插件问题再补记。Windows SMTC（smtc_windows 已在依赖中）仍是后续工作。
- 数据库用 `sqlite3`（FFI）+ `sqlite3_flutter_libs`（为 Win/Android/iOS 打包原生库；macOS 走系统 libsqlite3）。
  单测用 `LibraryDatabase.memory()` 内存库，无需插件。
- 收藏夹两个接口（favFolders/favFolderContent）都走 WBI 签名且需登录态；
  匿名 smoke test 覆盖不到，登录后若报 -403/-101 先确认 SESSDATA 有效。
- 下载**不做** ffmpeg 转码与 ID3 标签写入（后续 Phase 再做）；downloads 表不存 cid，
  失败重下需回搜索/收藏/歌单页重新发起。

## macOS Keychain 说明（2026-07-30 实测）

- macOS 沙盒下 flutter_secure_storage 会报 -34018（缺 keychain-access-groups entitlement）；
  该 entitlement 又要求 Apple 开发证书签名，与"本地运行（免签名）"冲突，故**不加该 entitlement**。
- 解决方案：`lib/services/auth/token_store.dart`（TokenStore）——Keychain 优先、抛错自动降级为
  应用支持目录下 chmod 600 的文件。Phase 5 配置 Personal Team 签名后可重新评估启用 Keychain。

## 迭代（2026-07-30 第二轮）

- 移除"收藏夹"tab（用户不需要账号收藏夹）；导航：搜索/曲库/播放/我的。
- `pages/track_list_page.dart`：分P曲目列表页（搜索结果点击进入）——播放全部/全部收录/单曲播放·收录·下载；歌单表 UNIQUE(playlist_id, source_id, track_id, cid) 天然支持同 bvid 多 P。
- `services/sources/bilibili/hires_probe.dart`：Hi-Res 探测（复用 selectStream，bvid:cid 缓存、并发限 3、失败不缓存），列表条目徽章 `widgets/quality_badge.dart`（compact）。
- 播放器：PlayMode（顺序/单曲/随机，`nextQueueIndex` 纯函数）、队列编辑（playAt/removeAt）、queueStream/modeStream；播放页队列面板 + 模式切换。
- 歌词：`services/lyrics/`（LRCLib 搜索 API + 手写 LRC 解析器，与音源解耦），播放页封面/歌词切换。
- TODO：合集（ugc_season，多独立视频组成的合集）未支持——需 /x/web-interface/view 拿 ugc_season + seasons_archives_list 拉各集（参考 biu src/service/web-interface-view.ts、space-seasons-series-list.ts）。

## 打包分发（2026-08-01）

- macOS：`flutter build macos --release` → `create-dmg` 出 `dist/musicbox-x.y.z.dmg`（已验证可挂载）。
  未签名/未公证：本机直接可用；其他 Mac 首次需右键"打开"。
- Windows：`.github/workflows/build-windows.yml`（GitHub Actions windows-latest），
  推 tag 或手动触发，产物 musicbox-windows-x64.zip 便携包。
- iOS：`flutter build ios --release --no-codesign`（⚠️ 必须用 flutter 命令构建——
  直接调 xcodebuild 不会刷新版本号（FLUTTER_BUILD_NAME），且产物落在 DerivedData，
  曾因此把 0.2.1 的旧包当新版连发好几个版本）。产物 `build/ios/iphoneos/Runner.app`
  → 打 Payload/Unison.app zip 成 IPA 挂 Gitee release。
  或免费 Apple ID（Personal Team）插线装机（7 天签名）。

## Phase A/B（2026-08-01）：QQ 音乐 + 坚果云同步

- QQ 音乐音源：`services/sources/qqmusic/`（api/qq_client 双域 dio+CookieJar、endpoints 搜索 client_search_cp 与 vkey.GetVkeyServer 取流、stream_select F000→M800→M500 降级）。登录=`services/auth/qq_auth.dart` 内嵌 desktop_webview_window 轮询 getAllCookies 抓 qqmusic_key+uin（注意：包 API 是 webview.getAllCookies()，无 WebviewCookieManager）。QQ 接口偶发 text/plain 响应需手动 jsonDecode。
- 网易云收尾暂停（xeapi crypto 完成待用）。
- 坚果云同步：`services/sync/`（webdav_client 最小 WebDAV、library_sync 元数据导出/导入/推拉/防抖）。凭证存 TokenStore；启动时拉取、曲库变更 3s 防抖推送（main.dart HomeShell ref.listen）。不同步音乐文件。
- 存储策略见 docs/storage-guide.md（FLAC=无损压缩本身，不转码；云曲库下一步 R2）。

## 凭证安全红线（2026-08-01 确立）

- 一切账号凭证（cookie/token/应用密码）只允许经 TokenStore 写入系统目录
  （macOS: ~/Library/Application Support/com.krelar.musicbox/secure_store/），
  **严禁写入仓库内任何文件**（含代码、配置、文档、测试数据）。
- 远程地址不得内嵌 token（github 用 gh 凭证助手，gitee 用 SSH key）。
- 每次发版/批量提交前跑一遍敏感串扫描：
  `git ls-files | xargs grep -l -E 'ghp_|SESSDATA=|qqmusic_key=|MUSIC_U=|appPassword'`
  输出必须为空。真实凭证值（即使测试用）也不写进单测。

## 发版纪律（2026-08-03 确立）

- **每次出包必须 bump 版本号**（pubspec、UpdateChecker.currentVersion、git tag、
  appsrc 四处同步），**禁止在旧 release 上替换附件**——否则各端更新检测失效。
- Release 只保留最近 2 个版本，旧的定期删除（GitHub `gh release delete`、
  Gitee API DELETE），tags 可保留。
- appsrc 的 sourceUpdateTime/appUpdateTime 必须随版本更新（GBox 靠它刷新）。
- **Windows 便携 zip 两端都要挂**：tag 触发的 CI 只会自动挂 GitHub，
  Gitee 需手动 attach（先从 CI artifact 或 GitHub asset 取 zip）。
  zip 内已含 VC++ CRT，全新系统解压即用。
