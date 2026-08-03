import 'dart:io';

import 'package:unison/services/lyrics/t2s.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() => T2s.ensureLoaded(
      loader: () => File('assets/t2s.txt').readAsString()));

  test('繁体歌词转简体', () {
    expect(T2s.convert('嘲笑誰恃美揚威'), '嘲笑谁恃美扬威');
    expect(T2s.convert('沒了心如何相配'), '没了心如何相配');
  });

  test('简体/非汉字原样保留', () {
    expect(T2s.convert('已经 是简体 ABC 123'), '已经 是简体 ABC 123');
    expect(T2s.convert(''), '');
  });
}
