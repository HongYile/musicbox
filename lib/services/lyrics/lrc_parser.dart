/// LRC 歌词解析器（纯逻辑，无平台依赖）。
library;

import 'dart:convert';

class LrcLine {
  const LrcLine(this.time, this.text);

  /// 该行应显示的时间点。
  final Duration time;
  final String text;
}

final _tagReg = RegExp(r'\[(\d+):(\d+)(?:[.:](\d+))?\]');

/// 解析 LRC 文本为按时间排序的行列表。
///
/// - 支持一行多时间标签（每个标签产生一行）；
/// - 跳过元数据行（[ti:][ar:] 等非数字标签）与无标签行；
/// - 毫秒部分按 2 位（厘秒）或 3 位解析。
List<LrcLine> parseLrc(String raw) {
  final lines = <LrcLine>[];
  for (final rawLine in const LineSplitter().convert(raw)) {
    final matches = _tagReg.allMatches(rawLine).toList();
    if (matches.isEmpty) continue;
    final text = rawLine.replaceAll(_tagReg, '').trim();
    for (final m in matches) {
      final min = int.parse(m.group(1)!);
      final sec = int.parse(m.group(2)!);
      final fracRaw = m.group(3) ?? '0';
      final frac = int.parse(fracRaw.padRight(3, '0').substring(0, 3));
      lines.add(LrcLine(
        Duration(minutes: min, seconds: sec, milliseconds: frac),
        text,
      ));
    }
  }
  lines.sort((a, b) => a.time.compareTo(b.time));
  return lines;
}

/// 给定播放位置，返回当前应高亮的行下标（无歌词返回 -1）。
int lrcCurrentIndex(List<LrcLine> lines, Duration position) {
  var idx = -1;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].time <= position) {
      idx = i;
    } else {
      break;
    }
  }
  return idx;
}
