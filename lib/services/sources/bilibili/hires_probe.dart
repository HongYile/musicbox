import 'dart:async';

import 'stream_select.dart';

/// Hi-Res 探测服务：对稿件异步拉取 playurl 选流，确认其有无 Hi-Res/杜比音轨。
///
/// - 结果按 `bvid:cid` 缓存（App 生命周期内有效），同一 key 并发去重；
/// - 全局并发限制 [maxConcurrent]，避免一次搜索触发风控（-412）；
/// - 失败返回 null（未知），不缓存失败，下次可重试。
///
/// 依赖注入选流函数而非 BiliApi，便于单测 mock。
class HiResProbe {
  HiResProbe(this._select);

  final Future<StreamChoice> Function(String bvid, int cid) _select;

  static const maxConcurrent = 3;

  final _cache = <String, StreamChoice>{};
  final _inflight = <String, Future<StreamChoice?>>{};
  var _running = 0;
  final _waiters = <Completer<void>>[];

  /// 已缓存的探测结果（无则 null）。
  StreamChoice? cached(String bvid, int cid) => _cache['$bvid:$cid'];

  /// 探测指定稿件的音质。重复调用命中缓存或合并到进行中的请求。
  Future<StreamChoice?> probe(String bvid, int cid) {
    final key = '$bvid:$cid';
    final hit = _cache[key];
    if (hit != null) return Future.value(hit);
    final existing = _inflight[key];
    if (existing != null) return existing;

    final future = _run(key, bvid, cid);
    _inflight[key] = future;
    return future;
  }

  Future<StreamChoice?> _run(String key, String bvid, int cid) async {
    await _acquire();
    try {
      final choice = await _select(bvid, cid);
      _cache[key] = choice;
      return choice;
    } catch (_) {
      return null; // 未知：网络错误/风控/无权限，下次重试
    } finally {
      _inflight.remove(key);
      _release();
    }
  }

  Future<void> _acquire() async {
    if (_running < maxConcurrent) {
      _running++;
      return;
    }
    final c = Completer<void>();
    _waiters.add(c);
    await c.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      // 名额直接移交给下一个等待者，_running 计数不变。
      _waiters.removeAt(0).complete();
    } else {
      _running--;
    }
  }
}
