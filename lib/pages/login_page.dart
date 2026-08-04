import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../providers.dart';
import '../services/ai/ai_title_service.dart';
import '../services/auth/web_login_page.dart';
import '../services/sources/quality_preference.dart';
import '../widgets/glass_card.dart';
import '../services/sources/bilibili/models.dart';
import '../services/sources/qqmusic/api/qq_login.dart';
import '../services/sync/webdav_client.dart';
import '../services/update/update_checker.dart';
import '../services/update/update_prompt.dart';

/// 登录页 UI 状态。
class LoginUiState {
  const LoginUiState({
    this.session,
    this.status = QrcodeStatus.waiting,
    this.busy = false,
    this.message = '点击按钮生成二维码',
  });

  final QrcodeSession? session;
  final QrcodeStatus status;
  final bool busy;
  final String message;

  LoginUiState copyWith({
    QrcodeSession? session,
    QrcodeStatus? status,
    bool? busy,
    String? message,
  }) =>
      LoginUiState(
        session: session ?? this.session,
        status: status ?? this.status,
        busy: busy ?? this.busy,
        message: message ?? this.message,
      );
}

final loginUiProvider =
    StateNotifierProvider<LoginUiController, LoginUiState>((ref) {
  return LoginUiController(ref);
});

class LoginUiController extends StateNotifier<LoginUiState> {
  LoginUiController(this._ref) : super(const LoginUiState());

  final Ref _ref;
  StreamSubscription<QrcodePollResult>? _sub;

  Future<void> start() async {
    await _sub?.cancel();
    state = const LoginUiState(busy: true, message: '正在生成二维码…');
    try {
      final session = await _ref.read(authServiceProvider).startLogin();
      state = LoginUiState(session: session, message: '请用 B站 App 扫码');
      _sub = _ref
          .read(authServiceProvider)
          .pollLogin(session.qrcodeKey)
          .listen((result) {
        switch (result.status) {
          case QrcodeStatus.waiting:
            state = state.copyWith(
                status: result.status, message: '请用 B站 App 扫码');
          case QrcodeStatus.scanned:
            state = state.copyWith(
                status: result.status, message: '已扫码，请在手机上确认');
          case QrcodeStatus.expired:
            state = state.copyWith(
                status: result.status, message: '二维码已失效，请重新生成');
          case QrcodeStatus.confirmed:
            state = state.copyWith(
                status: result.status, message: '登录成功');
            _ref.read(loginStateProvider.notifier).onLoginSuccess();
        }
      }, onError: (Object e) {
        state = state.copyWith(message: '轮询出错: $e');
      });
    } catch (e) {
      state = LoginUiState(message: '生成二维码失败: $e');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

class LoginPage extends ConsumerWidget {
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
          // ---- 分组设置布局 ----
          _SettingsSection(
            title: '账号',
            children: [
              const _BiliLoginCard(),
              const Divider(height: 20),
              _QqLoginCard(),
            ],
          ),
          _SettingsSection(
            title: '同步',
            children: [
              _NutstoreCard(),
            ],
          ),
          _SettingsSection(
            title: 'AI 歌曲识别',
            children: [
              const _AiCard(),
            ],
          ),
          _SettingsSection(
            title: '常规',
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('外观', style: Theme.of(context).textTheme.bodyMedium),
                  SegmentedButton<ThemeMode>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                          value: ThemeMode.system,
                          label: Text('跟随系统')),
                      ButtonSegment(
                          value: ThemeMode.light, label: Text('亮色')),
                      ButtonSegment(value: ThemeMode.dark, label: Text('暗色')),
                    ],
                    selected: {ref.watch(themeModeProvider)},
                    onSelectionChanged: (s) =>
                        ref.read(themeModeProvider.notifier).set(s.first),
                  ),
                ],
              ),
              const Divider(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Tooltip(
                    message: '无损需绿钻/大会员；无权限时自动降到可用最高档',
                    child: Text('音质偏好',
                        style: Theme.of(context).textTheme.bodyMedium),
                  ),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'lossless', label: Text('无损优先')),
                      ButtonSegment(value: '320k', label: Text('320K')),
                      ButtonSegment(value: '128k', label: Text('128K')),
                    ],
                    selected: {ref.watch(qualityPrefProvider)},
                    onSelectionChanged: (s) {
                      final v = s.first;
                      QualityPreference.current = v;
                      ref.read(qualityPrefProvider.notifier).state = v;
                      SharedPreferences.getInstance().then(
                          (p) => p.setString('app_quality', v));
                    },
                  ),
                ],
              ),
              const Divider(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('更新源', style: Theme.of(context).textTheme.bodyMedium),
                  const _UpdateSourceSelector(),
                ],
              ),
              const Divider(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('版本更新',
                      style: Theme.of(context).textTheme.bodyMedium),
                  TextButton.icon(
                    onPressed: () =>
                        checkAndPromptUpdate(context, manual: true),
                    icon: const Icon(Icons.system_update_alt, size: 18),
                    label: const Text('检查更新'),
                  ),
                ],
              ),
            ],
          ),
          _SettingsSection(
            title: '关于',
            children: [
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.asset('assets/icon.png',
                    width: 56, height: 56,
                    errorBuilder: (_, _, _) =>
                        const Icon(Icons.music_note, size: 56)),
              ),
              const SizedBox(height: 8),
              Text('Unison 同度',
                  style: Theme.of(context).textTheme.titleMedium),
              Text('当前版本 ${UpdateChecker.currentVersion}',
                  style: const TextStyle(color: Colors.grey, fontSize: 12)),
              TextButton.icon(
                onPressed: () =>
                    launchUrlString('https://github.com/HongYile/unison'),
                icon: const Icon(Icons.code, size: 18),
                label: const Text('项目地址 github.com/HongYile/unison',
                    style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
        ),
      ),
    );
  }
}

/// QQ 音乐登录卡片：扫码登录（ptlogin2 链，与 B站同构）+ 内嵌网页兜底。
class _QqLoginCard extends ConsumerStatefulWidget {
  const _QqLoginCard();

  @override
  ConsumerState<_QqLoginCard> createState() => _QqLoginCardState();
}

class _QqLoginCardState extends ConsumerState<_QqLoginCard> {
  QqQrSession? _session;
  String _message = '点击生成二维码，用手机 QQ 扫码登录';
  bool _busy = false;
  bool _success = false;
  QqQrStep? _phase; // 当前扫码阶段（待确认时模糊二维码）
  StreamSubscription<QqQrResult>? _sub;
  final _cookieController = TextEditingController();

  @override
  void dispose() {
    _sub?.cancel();
    _cookieController.dispose();
    super.dispose();
  }

  /// 移动端 cookie 粘贴登录。
  Future<void> _loginByCookie() async {
    final raw = _cookieController.text.trim();
    if (raw.isEmpty) return;
    setState(() => _busy = true);
    try {
      await ref.read(qqClientProvider).importCookieString(raw);
      final ok = await ref.read(qqAuthServiceProvider).isLoggedIn();
      if (!mounted) return;
      if (ok) {
        ref.invalidate(qqLoginStateProvider);
        setState(() => _message = '登录成功');
      } else {
        setState(() => _message = 'Cookie 无效或缺少 qqmusic_key');
      }
    } catch (e) {
      if (mounted) setState(() => _message = '登录失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startQr() async {
    await _sub?.cancel();
    setState(() {
      _busy = true;
      _success = false;
      _message = '正在生成二维码…';
    });
    try {
      final login = QqQrLogin(ref.read(qqClientProvider).cookieJar);
      final session = await login.generate();
      if (!mounted) return;
      setState(() {
        _session = session;
        _message = '请用手机 QQ 扫码';
      });
      _sub = login.poll(session).listen((r) {
        if (!mounted) return;
        setState(() => _phase = r.step);
        switch (r.step) {
          case QqQrStep.waiting:
            setState(() => _message = '请用手机 QQ 扫码');
          case QqQrStep.scanned:
            setState(() => _message = '已扫码，请在手机上确认');
          case QqQrStep.exchanging:
            setState(() => _message = '已确认，正在换取登录态…');
          case QqQrStep.success:
            setState(() {
              _message = '登录成功';
              _success = true;
              _busy = false;
              _session = null;
            });
            ref.invalidate(qqLoginStateProvider);
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('QQ 音乐登录成功（uin=${r.uin}）')));
          case QqQrStep.expired:
            setState(() {
              _message = '二维码已失效，请重新生成';
              _busy = false;
            });
          case QqQrStep.error:
            setState(() {
              _message = r.message;
              _busy = false;
            });
        }
      }, onError: (Object e) {
        if (mounted) setState(() => _message = '轮询出错: $e');
      });
    } catch (e) {
      if (mounted) setState(() => _message = '生成失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loginWebView() async {
    setState(() => _message = '请在弹出的网页中登录 QQ 音乐…');
    try {
      final ok = await ref.read(qqAuthServiceProvider).loginViaWebView();
      if (!mounted) return;
      if (ok) {
        ref.invalidate(qqLoginStateProvider);
        setState(() => _message = '登录成功');
      } else {
        setState(() => _message = '登录已取消或超时');
      }
    } catch (e) {
      if (mounted) setState(() => _message = '登录失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = ref.watch(qqLoginStateProvider).value ?? false;
    return Column(
      children: [
        Text('QQ 音乐', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        if (loggedIn && !_success) ...[
          FutureBuilder(
            future: ref.read(qqAuthServiceProvider).uin(),
            builder: (context, snap) =>
                Text('已登录（uin=${snap.data ?? '…'}），绿钻账号可播无损'),
          ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: () async {
              await ref.read(qqAuthServiceProvider).logout();
              ref.invalidate(qqLoginStateProvider);
            },
            child: const Text('退出登录'),
          ),
        ] else ...[
          if (Platform.isIOS || Platform.isAndroid) ...[
            // 移动端：本机内嵌官方网页登录（cookie 粘贴为兜底）
            FilledButton(
              onPressed: _busy
                  ? null
                  : () async {
                      final result = await WebLoginPage.loginQqMusic(context);
                      if (result != null && result.success) {
                        await ref
                            .read(qqClientProvider)
                            .importCookieString(result.cookieString);
                        ref.invalidate(qqLoginStateProvider);
                        if (mounted && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('QQ 音乐登录成功')));
                        }
                      }
                    },
              child: const Text('本机网页登录 QQ 音乐'),
            ),
            const SizedBox(height: 10),
            const Text('或用 cookie 粘贴登录：浏览器打开 y.qq.com 登录后，'
                '从开发者工具复制整串 Cookie 粘贴到下方',
                style: TextStyle(color: Colors.grey, fontSize: 11),
                textAlign: TextAlign.center),
            const SizedBox(height: 6),
            SizedBox(
              width: 320,
              child: TextField(
                controller: _cookieController,
                maxLines: 2,
                decoration: const InputDecoration(
                    labelText: '粘贴 Cookie（含 qqmusic_key）', isDense: true),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: _busy ? null : _loginByCookie,
              child: const Text('用 Cookie 登录'),
            ),
          ] else ...[
            const Text('内嵌官方网页登录（扫码不稳定的账号也能用）',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _loginWebView,
              child: const Text('登录 QQ 音乐（官方网页）'),
            ),
          ],
          if (_session != null) ...[
            const SizedBox(height: 10),
            _QrWithBlur(
                png: _session!.qrPng,
                blurred: _phase != null && _phase != QqQrStep.waiting),
          ],
          const SizedBox(height: 6),
          Text(_message, style: const TextStyle(fontSize: 12)),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: _busy && _session != null ? null : _startQr,
                child: Text(_session == null ? '实验：试试扫码' : '刷新二维码',
                    style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// 坚果云同步卡片：配置账号（邮箱+应用密码）、手动同步、状态显示。
class _NutstoreCard extends ConsumerStatefulWidget {
  const _NutstoreCard();

  @override
  ConsumerState<_NutstoreCard> createState() => _NutstoreCardState();
}

class _NutstoreCardState extends ConsumerState<_NutstoreCard> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _message;
  bool _hasAccount = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = ref.read(tokenStoreProvider);
    final email = await store.read(key: kNutstoreEmailKey);
    final pwd = await store.read(key: kNutstorePasswordKey);
    if (!mounted) return;
    setState(() {
      _email.text = email ?? '';
      _password.text = pwd ?? '';
      _hasAccount = email != null && email.isNotEmpty;
    });
  }

  Future<void> _save() async {
    final store = ref.read(tokenStoreProvider);
    await store.write(key: kNutstoreEmailKey, value: _email.text.trim());
    await store.write(key: kNutstorePasswordKey, value: _password.text.trim());
    final client = _freshClient();
    ref.read(webDavClientProvider.notifier).state = client;
    setState(() => _hasAccount = true);
    // 保存即测连：PROPFIND 根目录验证凭证有效
    setState(() => _busy = true);
    try {
      await client.mkcol('/musicbox');
      setState(() => _message = '连接成功，账号有效');
    } catch (e) {
      setState(() => _message = '连接失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 用当前输入框的值构建全新客户端（避免用过期缓存凭证）。
  WebDavClient _freshClient() => WebDavClient(
      email: _email.text.trim(), appPassword: _password.text.trim());

  Future<void> _clear() async {
    final store = ref.read(tokenStoreProvider);
    await store.delete(key: kNutstoreEmailKey);
    await store.delete(key: kNutstorePasswordKey);
    ref.read(webDavClientProvider.notifier).state = null;
    setState(() {
      _hasAccount = false;
      _email.clear();
      _password.clear();
      _message = '已清除账号';
    });
  }

  Future<void> _push() async {
    setState(() {
      _busy = true;
      _message = '推送中（本地 → 云端）…';
    });
    try {
      ref.read(webDavClientProvider.notifier).state = _freshClient();
      await ref.read(syncServiceProvider).push();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          'nutstore_last_sync_ms', DateTime.now().millisecondsSinceEpoch);
      setState(() => _message = '已推送到云端（library.json 已覆盖为本地曲库）');
    } catch (e) {
      setState(() => _message = _errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pull() async {
    setState(() {
      _busy = true;
      _message = '拉取中（云端 → 本地）…';
    });
    try {
      ref.read(webDavClientProvider.notifier).state = _freshClient();
      final (imported, remoteAt) = await ref.read(syncServiceProvider).pull();
      ref.read(syncPulledOnceProvider.notifier).state = true;
      ref.read(playlistsProvider.notifier).refresh();
      setState(() => _message = imported
          ? '已从云端拉取合并到本地（远端更新于 $remoteAt）'
          : '云端没有新数据可拉取');
    } catch (e) {
      setState(() => _message = _errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _errText(Object e) {
    final msg = '$e';
    if (msg.contains('401')) {
      return '账号或应用密码错误（要用「第三方应用管理」生成的应用密码，'
          '不是登录密码；粘贴的空格已自动去除，请重新保存账号）';
    }
    return '操作失败: $e';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text('坚果云同步（曲库元数据）',
            style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        const Text('坚果云官网 → 账户信息 → 安全选项 → 第三方应用管理 → 生成应用密码',
            style: TextStyle(color: Colors.grey, fontSize: 11),
            textAlign: TextAlign.center),
        const SizedBox(height: 10),
        SizedBox(
          width: 300,
          child: TextField(
            controller: _email,
            decoration: const InputDecoration(
                labelText: '坚果云邮箱', isDense: true),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: 300,
          child: TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(
                labelText: '应用密码（非登录密码）', isDense: true),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FilledButton.tonal(onPressed: _save, child: const Text('保存账号')),
            const SizedBox(width: 10),
            if (_hasAccount) ...[
              FilledButton.icon(
                onPressed: _busy ? null : _pull,
                icon: const Icon(Icons.cloud_download, size: 18),
                label: const Text('拉取'),
              ),
              const SizedBox(width: 10),
              FilledButton.tonalIcon(
                onPressed: _busy ? null : _push,
                icon: const Icon(Icons.cloud_upload, size: 18),
                label: const Text('推送'),
              ),
              const SizedBox(width: 10),
              TextButton(onPressed: _clear, child: const Text('清除')),
            ],
          ],
        ),
        if (_message != null) ...[
          const SizedBox(height: 8),
          Text(_message!,
              style: const TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      ],
    );
  }
}

/// 二维码（已扫码待确认/换票中/失效时模糊 + 状态角标）。
class _QrWithBlur extends StatelessWidget {
  const _QrWithBlur({required this.png, required this.blurred});

  final Uint8List png;
  final bool blurred;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 200,
        height: 200,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ImageFiltered(
              imageFilter:
                  ImageFilter.blur(sigmaX: blurred ? 6 : 0, sigmaY: blurred ? 6 : 0),
              child: Image.memory(png, fit: BoxFit.contain),
            ),
            if (blurred)
              const Center(
                child: CircleAvatar(
                  radius: 26,
                  backgroundColor: Colors.white,
                  child: Icon(Icons.check, color: Color(0xFF20B486), size: 34),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 更新源选择（Gitee 默认/GitHub），持久化到 shared_preferences。
class _UpdateSourceSelector extends StatefulWidget {
  const _UpdateSourceSelector();

  @override
  State<_UpdateSourceSelector> createState() => _UpdateSourceSelectorState();
}

class _UpdateSourceSelectorState extends State<_UpdateSourceSelector> {
  UpdateSource _source = UpdateSource.gitee;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() {
        _source = prefs.getString(kUpdateSourceKey) == 'github'
            ? UpdateSource.github
            : UpdateSource.gitee;
      });
    });
  }

  Future<void> _set(UpdateSource s) async {
    setState(() => _source = s);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        kUpdateSourceKey, s == UpdateSource.github ? 'github' : 'gitee');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text('更新源', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        SegmentedButton<UpdateSource>(
          segments: [
            ButtonSegment(
                value: UpdateSource.gitee,
                label: Text(UpdateSource.gitee.label),
                icon: const Icon(Icons.cloud)),
            ButtonSegment(
                value: UpdateSource.github,
                label: Text(UpdateSource.github.label),
                icon: const Icon(Icons.cloud_outlined)),
          ],
          selected: {_source},
          onSelectionChanged: (s) => _set(s.first),
        ),
      ],
    );
  }
}

/// 设置分组：小标题 + 玻璃卡片容器。
class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 6, bottom: 6),
            child: Text(
              title.toUpperCase(),
              style: TextStyle(
                fontSize: 12,
                letterSpacing: 1.6,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}

/// AI 歌曲识别配置卡片：DeepSeek（OpenAI 兼容）接口提炼干净歌名。
///
/// Key 只存本机 TokenStore（钥匙串/本地加密文件），不进仓库；
/// 同步开关明确标注是否加密随坚果云同步。
class _AiCard extends ConsumerStatefulWidget {
  const _AiCard();

  @override
  ConsumerState<_AiCard> createState() => _AiCardState();
}

class _AiCardState extends ConsumerState<_AiCard> {
  final _keyCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  bool _saved = false;

  /// 已回填的配置签名（apiKey|baseUrl|model）——
  /// 坚果云拉取到 AI 配置后 state 变化，这里随之重新填充。
  String _filledSig = '';

  @override
  void dispose() {
    _keyCtrl.dispose();
    _urlCtrl.dispose();
    _modelCtrl.dispose();
    super.dispose();
  }

  void _fill(AiConfig cfg) {
    final sig = '${cfg.apiKey}|${cfg.baseUrl}|${cfg.model}';
    if (sig == _filledSig) return;
    _filledSig = sig;
    _keyCtrl.text = cfg.apiKey;
    _urlCtrl.text = cfg.baseUrl;
    _modelCtrl.text = cfg.model;
  }

  /// sk-****** 掩码（保留前 7 位，便于确认是哪把 Key）。
  String _mask(String v) =>
      v.length <= 7 ? v : '${v.substring(0, 7)}••••••';

  @override
  Widget build(BuildContext context) {
    final cfg = ref.watch(aiConfigProvider);
    _fill(cfg);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '用 DeepSeek 等大模型从 B站标题提炼干净歌名，换源试听/歌词匹配更准。'
          'Key 只保存在本机，不会上传到任何仓库。',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _keyCtrl,
          obscureText: true,
          decoration: const InputDecoration(
              labelText: 'API Key', hintText: 'sk-...', isDense: true),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _urlCtrl,
          decoration: const InputDecoration(
              labelText: '接口地址', hintText: 'https://api.deepseek.com',
              isDense: true),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _modelCtrl,
          decoration: const InputDecoration(
              labelText: '模型', hintText: 'deepseek-v4-flash（无思考，快）',
              isDense: true),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                cfg.syncEnabled
                    ? '加密同步到坚果云：开（Key 经 AES-256 加密后随曲库同步，'
                        '密钥由你的坚果云应用密码派生，云端只存密文）'
                    : '加密同步到坚果云：关（Key 仅保存在本机）',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            Switch(
              value: cfg.syncEnabled,
              onChanged: (v) => ref
                  .read(aiConfigProvider.notifier)
                  .save(cfg.copyWith(syncEnabled: v)),
            ),
          ],
        ),
        Row(
          children: [
            FilledButton.tonal(
              onPressed: () async {
                await ref.read(aiConfigProvider.notifier).save(cfg.copyWith(
                      apiKey: _keyCtrl.text.trim(),
                      baseUrl: _urlCtrl.text.trim().isEmpty
                          ? 'https://api.deepseek.com'
                          : _urlCtrl.text.trim(),
                      model: _modelCtrl.text.trim().isEmpty
                          ? 'deepseek-v4-flash'
                          : _modelCtrl.text.trim(),
                    ));
                setState(() => _saved = true);
                Future.delayed(const Duration(seconds: 2), () {
                  if (mounted) setState(() => _saved = false);
                });
              },
              child: Text(_saved ? '已保存' : '保存'),
            ),
            const SizedBox(width: 12),
            if (cfg.configured)
              Flexible(
                child: Text('已保存：${_mask(cfg.apiKey)}（换源用 AI 提炼歌名）',
                    style:
                        const TextStyle(fontSize: 12, color: Colors.green)),
              )
            else
              const Text('未配置，换源用规则清洗标题',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ],
    );
  }
}

/// B站登录卡片（账号组内）。
class _BiliLoginCard extends ConsumerWidget {
  const _BiliLoginCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = ref.watch(loginUiProvider);
    final login = ref.watch(loginStateProvider);

    if (login.isLogin) {
      return Column(
        children: [
          const Icon(Icons.account_circle, size: 56),
          const SizedBox(height: 8),
          Text('哔哩哔哩 已登录：${login.uname} (mid=${login.mid})'),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: () => ref.read(loginStateProvider.notifier).logout(),
            child: const Text('退出登录'),
          ),
        ],
      );
    }

    if (Platform.isIOS || Platform.isAndroid) {
      return Column(
        children: [
          Text('哔哩哔哩', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: ui.busy
                ? null
                : () async {
                    final result = await WebLoginPage.loginBilibili(context);
                    if (result != null && result.success) {
                      await ref
                          .read(biliClientProvider)
                          .importCookieString(result.cookieString);
                      if (context.mounted) {
                        await ref
                            .read(loginStateProvider.notifier)
                            .onLoginSuccess();
                      }
                    }
                  },
            child: const Text('本机网页登录'),
          ),
          TextButton(
            onPressed: () => ref.read(loginUiProvider.notifier).start(),
            child: const Text('或用二维码（需另一台设备）',
                style: TextStyle(fontSize: 12)),
          ),
          if (ui.session != null && ui.status != QrcodeStatus.expired)
            QrImageView(
              data: ui.session!.url,
              size: 180,
              backgroundColor: Colors.white,
            ),
          Text(ui.message, style: const TextStyle(fontSize: 12)),
        ],
      );
    }

    return Column(
      children: [
        Text('哔哩哔哩', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        if (ui.session != null && ui.status != QrcodeStatus.expired)
          QrImageView(
            data: ui.session!.url,
            size: 200,
            backgroundColor: Colors.white,
          )
        else
          const Icon(Icons.qr_code_2, size: 100),
        const SizedBox(height: 10),
        Text(ui.message, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: ui.busy
              ? null
              : () => ref.read(loginUiProvider.notifier).start(),
          child: Text(ui.session == null ? '扫码登录' : '刷新二维码'),
        ),
        const SizedBox(height: 4),
        const Text('登录自己的 B站大会员账号以获取 Hi-Res 无损音质',
            style: TextStyle(color: Colors.grey, fontSize: 11)),
      ],
    );
  }
}
