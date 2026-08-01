import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers.dart';
import '../services/sources/bilibili/models.dart';
import '../services/sources/qqmusic/api/qq_login.dart';
import '../services/sync/webdav_client.dart';

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
    final ui = ref.watch(loginUiProvider);
    final login = ref.watch(loginStateProvider);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
          if (login.isLogin) ...[
            const Icon(Icons.account_circle, size: 72),
            const SizedBox(height: 12),
            Text('已登录：${login.uname} (mid=${login.mid})'),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: () =>
                  ref.read(loginStateProvider.notifier).logout(),
              child: const Text('退出登录'),
            ),
          ] else ...[
            if (ui.session != null && ui.status != QrcodeStatus.expired)
              QrImageView(
                data: ui.session!.url,
                size: 220,
                backgroundColor: Colors.white,
              )
            else
              const Icon(Icons.qr_code_2, size: 120),
            const SizedBox(height: 16),
            Text(ui.message),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: ui.busy
                  ? null
                  : () => ref.read(loginUiProvider.notifier).start(),
              child: Text(ui.session == null ? '生成登录二维码' : '刷新二维码'),
            ),
            const SizedBox(height: 8),
            const Text('登录自己的 B站大会员账号以获取 Hi-Res 无损音质',
                style: TextStyle(color: Colors.grey)),
          ],
          const SizedBox(height: 24),
          const Divider(indent: 60, endIndent: 60),
          const SizedBox(height: 12),
          const _QqLoginCard(),
          const SizedBox(height: 20),
          const Divider(indent: 60, endIndent: 60),
          const SizedBox(height: 12),
          const _NutstoreCard(),
          const SizedBox(height: 20),
          const Divider(indent: 60, endIndent: 60),
          const SizedBox(height: 12),
          Text('外观', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(
                  value: ThemeMode.system,
                  label: Text('跟随系统'),
                  icon: Icon(Icons.brightness_auto)),
              ButtonSegment(
                  value: ThemeMode.light,
                  label: Text('亮色'),
                  icon: Icon(Icons.light_mode)),
              ButtonSegment(
                  value: ThemeMode.dark,
                  label: Text('暗色'),
                  icon: Icon(Icons.dark_mode)),
            ],
            selected: {ref.watch(themeModeProvider)},
            onSelectionChanged: (s) =>
                ref.read(themeModeProvider.notifier).set(s.first),
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

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
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
          const Text('内嵌官方网页登录（扫码不稳定的账号也能用）',
              style: TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _loginWebView,
            child: const Text('登录 QQ 音乐（官方网页）'),
          ),
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
    ref.read(webDavClientProvider.notifier).state = WebDavClient(
        email: _email.text.trim(), appPassword: _password.text.trim());
    setState(() {
      _hasAccount = true;
      _message = '已保存账号';
    });
  }

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

  Future<void> _syncNow() async {
    setState(() {
      _busy = true;
      _message = '同步中…';
    });
    try {
      final sync = ref.read(syncServiceProvider);
      final (imported, _) = await sync.pull();
      await sync.push();
      ref.read(playlistsProvider.notifier).refresh();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          'nutstore_last_sync_ms', DateTime.now().millisecondsSinceEpoch);
      setState(() => _message = imported ? '已拉取远程并推送本地' : '已推送本地到坚果云');
    } catch (e) {
      final msg = '$e';
      setState(() => _message = msg.contains('401')
          ? '账号或应用密码错误（要用「第三方应用管理」生成的应用密码，'
              '不是登录密码；粘贴的空格已自动去除，请重新保存账号）'
          : '同步失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
              FilledButton(
                onPressed: _busy ? null : _syncNow,
                child: Text(_busy ? '同步中…' : '立即同步'),
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
