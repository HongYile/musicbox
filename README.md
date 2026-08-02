# Unison 同度

一款个人自用的跨平台音乐播放器（Flutter）。一套代码覆盖 macOS / Windows / iOS / Android，聚合多个音源，支持无损音质、换源试听、歌单与云端同步。

## 功能

- **多音源聚合**：哔哩哔哩（大会员 Hi-Res 无损流）、QQ 音乐（绿钻无损）、网易云音乐（开发中）
- **无损优先**：各音源均按最高音质降级链选流（Hi-Res → 杜比/无损 → 320K → …），列表内显示音质徽章
- **换源试听**：同一首歌一键对比三个音源的 Top3 结果，逐条试听选最佳
- **分P/合集**：B站合集稿件展开为曲目列表，支持整单播放、全部入队、单曲/批量收录
- **播放体验**：本地 HTTP 流代理（URL 过期自动重取、CDN 故障切换）、播放队列（顺序/单曲/随机）、LRCLib 同步歌词、封面模糊环境背景
- **曲库**：本地歌单（sqlite）、下载管理（原始流保存不转码，Hi-Res FLAC 直存）
- **坚果云同步**：歌单/设置等元数据经 WebDAV 多端同步
- **双主题**：暗色（仿 QQ 音乐）/ 亮色（工程科技风），跟随系统
- **登录方式**：B站扫码登录、QQ 音乐官方网页登录（内嵌）、网易云扫码（开发中）

## 实测设备

| 设备 | 系统 | 状态 |
|---|---|---|
| MacBook Air（Apple M3，Mac15,12） | macOS 15.5 | ✅ 已实测（开发/主用机） |
| Windows x64 便携包 | Windows 10 1809+ / 11 | ⚙️ CI 自动构建；**Win10 需安装 [WebView2 Runtime](https://developer.microsoft.com/microsoft-edge/webview2/) 才能使用 QQ 音乐网页登录**（Win11 自带） |
| macOS 10.15+（含 macOS 26 Tahoe） | — | ✅ 向前兼容运行；本机构建 macOS 26 需 Xcode 26 |
| iPhone / Android | — | 计划侧载实测 |

## 构建

需要 Flutter 3.44+。

```bash
flutter pub get

# macOS
flutter build macos --release

# Windows（本仓库已配置 GitHub Actions：推 tag 自动构建，见 Actions 页产物）
flutter build windows --release

# iOS（自行签名或侧载）
flutter build ios --no-codesign
```

macOS 打包 DMG：

```bash
brew install create-dmg
create-dmg dist/musicbox.dmg build/macos/Build/Products/Release/musicbox.app
```

## 架构

```
lib/
  services/
    sources/          # 音源层（编译期内置，统一接口）
      bilibili/       #   WBI 签名、Hi-Res 选流降级链、Hi-Res 探测
      qqmusic/        #   vkey 取流、ptlogin 扫码（实验）、官方网页登录
      netease/        #   weapi/eapi/xeapi 加密（Dart 移植）
    auth/             # 登录与凭证（Keychain 优先的安全存储）
    player/           # media_kit 封装、本地流代理(shelf)、队列
    library/          # sqlite 歌单/下载
    sync/             # 坚果云 WebDAV 同步
    lyrics/           # LRCLib 歌词
  provider/           # Riverpod 状态层
  ui/                 # 页面与组件
```

关键设计：

- **本地流代理**：播放器只访问 `localhost`，真实音源 URL 的解析、过期重取、请求头注入、CDN 切换全部在代理层完成；
- **不转码**：B站 Hi-Res 服务器直出 FLAC 原样保存；AAC 存 m4a；
- **凭证安全**：系统 Keychain 优先，明文文件兜底（仅个人自用场景）。

## 测试

```bash
flutter test        # 78+ 单元测试（WBI 签名、选流降级、加密对拍、同步等）
flutter analyze     # 零告警
```

## 免责声明

本项目为个人学习项目。所有音源能力均基于**用户自己账号的既有权益**（如大会员/绿钻），不包含也不鼓励任何形式的破解；请仅用于个人非商业用途，并遵守各平台服务条款。

## License

[MIT](LICENSE)
