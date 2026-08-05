<div align="center">

<img src="docs/unison-logo-1024.png" width="120" alt="Unison logo"/>

# Unison 同度

**同首歌，多源听。**

一套 Flutter 代码覆盖 macOS / Windows / iOS / Android，
聚合 B站 · QQ音乐 · 网易云，Hi-Res 无损 · 逐字歌词 · 多端同步。

[![Release](https://img.shields.io/github/v/release/HongYile/unison?display_name=tag&color=7C4DFF)](https://github.com/HongYile/unison/releases/latest)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20iOS%20%7C%20Android-EC407A)](https://github.com/HongYile/unison/releases/latest)
[![Flutter](https://img.shields.io/badge/Flutter-3.44%2B-02569B?logo=flutter)](https://flutter.dev)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

</div>

---

## ✨ 功能特性

**🎧 音源与音质**
- **三源聚合**：哔哩哔哩（大会员 Hi-Res）、QQ音乐（绿钻无损）、网易云（xeapi 自研加密移植）
- **无损优先**：各源按降级链自动选最高可用音质，列表内音质徽章（Hi-Res / 杜比 / 无损 / 320K）
- **音质偏好**：无损优先（默认）/ 320K / 128K 可选，无会员自动落到可用最高档
- **换源试听**：同首歌一键对比三源 Top3，逐条试听选最佳；可配 AI（DeepSeek）提炼 B站脏标题再搜，命中率倍增

**🎵 播放体验**
- **分P/合集**：B站合集展开为曲目列表，点一首即整集连播；播放模式（列表循环/单曲/随机/顺序）可切换且记忆
- **队列操作**：下一首播放、入队、队列面板；右键/「⋯」完整菜单（播放 / 下一首 / 收藏 / 下载 / 移除）
- **系统媒体控制**：播放/暂停/上一首/下一首（macOS Now Playing、Windows SMTC、iOS 锁屏）；暂停即释放声卡，不抢蓝牙
- **本地流代理**：播放器只访问 localhost，URL 过期重取、CDN 切换、请求头注入全在代理层

**📝 歌词与评论**
- **真·逐字歌词**：QQ QRC 逐字时间戳（自研 3DES+zlib 解密），当前行到字点亮
- **翻译 / 音译**：原词 → 翻译 → 音译循环切换（有内容时出现）
- **评论区**：B站 / QQ音乐热评，楼中楼展开收起、分页加载；滚动到底自动续页
- B站视频不做跨源歌词匹配（变速/剪辑版时间轴必然错位，宁缺毋错）

**📚 曲库与同步**
- **本地曲库**：歌单（重命名 / 拖拽排序）、QQ歌单一键批量导入、下载管理（原始流不转码，Hi-Res FLAC 直存）
- **坚果云同步**：歌单/设置经 WebDAV 多端同步；DeepSeek Key 可选 AES-256 加密随行（密钥由坚果云密码派生）
- **应用内更新**：Gitee（默认）/ GitHub 双源，可暂停续传、失败回滚；版本号驱动，旧 release 定期清理

**📱 跨端**
- macOS（含 26 Tahoe）/ Windows 10+ / iOS（GBox 侧载）/ Android
- 明暗双主题跟随系统；移动端官方网页授权登录（无需第二部手机扫码）

---

## 📦 下载安装

到 [**Releases**](https://github.com/HongYile/unison/releases/latest)（或 [Gitee 发行版](https://gitee.com/Qq2454292378/unison/releases)，国内更快）下载对应包：

| 平台 | 文件 | 安装方式 |
|---|---|---|
| **macOS** | `unison-x.y.z.dmg` | 拖入「应用程序」；首次打开如被拦截：`系统设置 → 隐私与安全性 → 仍要打开` |
| **Windows（安装版）** | `unison-windows-setup.exe` | 双击按向导安装（免管理员权限），桌面/开始菜单快捷方式 |
| **Windows（绿色版）** | `unison-windows-x64.zip` | 解压进 `Unison` 文件夹，双击 `unison.exe`（已含 VC++ 运行库，免装环境） |
| **iOS** | GBox 订阅源 / `unison-ios-unsigned.ipa` | GBox 添加订阅源后一键安装与更新（见下） |
| **Android** | 自行构建 | `flutter build apk --release` |

**iOS GBox 订阅源**：GBox → 源管理 → 添加
`https://gitee.com/Qq2454292378/unison/raw/main/docs/unison.appsrc`
之后每次发版在 GBox 内直接更新。

**升级**：macOS / Windows 在 App 内「我的 → 检查更新」即可自更新；iOS 走 GBox。

## 🚀 快速上手

1. **登录**：「我的」页分别登录 B站（扫码/网页）与 QQ音乐（网页授权，手机端为官方手机版授权页）——解锁各源无损音质
2. **同步**：填入坚果云邮箱 + 应用密码（坚果云官网 → 账户信息 → 安全选项 → 第三方应用管理生成），曲库元数据多端同步
3. **AI 歌名识别**（可选）：填入 DeepSeek API Key（仅本机存储，可选加密同步），换源试听/歌词匹配更准

## 🛠 自行构建

需要 Flutter 3.44+。

```bash
flutter pub get

flutter build macos --release      # macOS
flutter build windows --release    # Windows（推 tag 触发 CI：zip + Inno Setup 安装包）
flutter build ios --no-codesign    # iOS（自行签名或侧载）
```

## 🏗 技术架构

```
lib/
  services/
    sources/          # 音源层（统一接口）
      bilibili/       #   WBI 签名、Hi-Res 选流降级链、评论(reply)
      qqmusic/        #   vkey 取流、QRC 歌词解密(3DES+zlib)、评论、歌单导入
      netease/        #   weapi/eapi/xeapi 加密（Dart 移植）
    auth/             # 登录与凭证（Keychain 优先的安全存储）
    player/           # media_kit 封装、本地流代理(shelf)、队列与播放模式
    library/          # sqlite 歌单/下载
    sync/             # 坚果云 WebDAV 同步（AES-256 敏感字段加密）
    lyrics/           # QRC 逐字解析、LRCLib、OpenCC 繁简转换
    update/           # 应用内自更新（双源、断点续传、备份回滚）
  providers.dart      # Riverpod 状态层
  pages/ widgets/     # 页面与组件
```

关键设计：

- **不转码**：B站 Hi-Res 服务器直出 FLAC 原样保存；AAC 存 m4a
- **凭证安全**：系统 Keychain 优先，明文文件兜底（个人自用场景）；启动崩溃写 `unison_startup_error.log`
- **可测试**：选流/加密/解析/同步全部纯 Dart 可单测

## ✅ 测试

```bash
flutter test        # 98 项单元测试（WBI 签名、选流降级、加密对拍、QRC 解析、迁移等）
flutter analyze     # 零告警
```

## ⚠️ 免责声明

本项目为个人学习项目。所有音源能力均基于**用户自己账号的既有权益**（如大会员/绿钻），不包含也不鼓励任何形式的破解；请仅用于个人非商业用途，并遵守各平台服务条款。

## License

[MIT](LICENSE)
