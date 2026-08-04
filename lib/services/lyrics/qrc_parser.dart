/// QRC（逐字歌词）解析器：行时间戳 [start,dur] + 逐字 (offset,dur)。
/// 纯逻辑，无平台依赖。
library;

/// 一个字/音节的时间片（startMs 为相对歌曲开局的绝对时间）。
class QrcWord {
  const QrcWord(this.text, this.startMs, this.durMs);

  final String text;
  final int startMs;
  final int durMs;

  int get endMs => startMs + durMs;
}

/// 一行歌词。
class QrcLine {
  const QrcLine(this.startMs, this.durMs, this.words);

  final int startMs;
  final int durMs;
  final List<QrcWord> words;

  int get endMs => startMs + durMs;

  /// 整行文本。
  String get text => words.map((w) => w.text).join().trim();

  /// [position] 时刻已唱到的字数（用于逐字高亮）。
  int sungWordCount(Duration position) {
    final ms = position.inMilliseconds;
    var n = 0;
    for (final w in words) {
      if (ms >= w.startMs) n++;
    }
    return n;
  }
}

final _lineReg = RegExp(r'^\[(\d+),(\d+)\](.*)$');
final _wordReg = RegExp(r'([^(]*)\((\d+),(\d+)\)');

/// 解析 QRC 文本（LyricContent 属性内容）。
/// 无逐字标记的行退化为"整行一个词"（翻译/音译通道常见）。
List<QrcLine> parseQrc(String raw) {
  final lines = <QrcLine>[];
  for (final rawLine in raw.split('\n')) {
    final m = _lineReg.firstMatch(rawLine.trim());
    if (m == null) continue;
    final start = int.parse(m.group(1)!);
    final dur = int.parse(m.group(2)!);
    final body = m.group(3)!;
    final words = <QrcWord>[];
    for (final wm in _wordReg.allMatches(body)) {
      final text = wm.group(1) ?? '';
      final off = int.parse(wm.group(2)!);
      final wdur = int.parse(wm.group(3)!);
      if (text.isNotEmpty) {
        words.add(QrcWord(text, start + off, wdur));
      }
    }
    if (words.isEmpty && body.trim().isNotEmpty) {
      words.add(QrcWord(body, start, dur));
    }
    if (words.isNotEmpty) lines.add(QrcLine(start, dur, words));
  }
  lines.sort((a, b) => a.startMs.compareTo(b.startMs));
  return lines;
}

/// 当前行下标（无匹配 -1）。
int qrcCurrentIndex(List<QrcLine> lines, Duration position) {
  final ms = position.inMilliseconds;
  var idx = -1;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].startMs <= ms) {
      idx = i;
    } else {
      break;
    }
  }
  return idx;
}
