import 'dart:async';

import 'package:flutter/material.dart';

/// 走马灯文本（往返式）：
/// 超宽时滚动到末尾 → 停顿 1.2s → 滚回开头 → 停顿 1.2s → 循环；
/// 未超宽（>4px 阈值）时普通显示。
/// 用 SingleChildScrollView 实现，天然裁剪、无溢出告警。
class MarqueeText extends StatefulWidget {
  const MarqueeText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText> {
  static const _threshold = 4.0;
  static const _hold = Duration(milliseconds: 1200);
  static const _pxPerSec = 36.0;

  final _sc = ScrollController();
  var _scrolling = false;

  @override
  void dispose() {
    _scrolling = false;
    _sc.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _scrolling = false; // 等重测后重启
  }

  /// 往返滚动循环（mounted/文本变化时自动终止并重启）。
  Future<void> _loop() async {
    if (_scrolling) return;
    _scrolling = true;
    while (mounted && _scrolling && _sc.hasClients) {
      final max = _sc.position.maxScrollExtent;
      if (max <= 0) break;
      await _sc.animateTo(max,
          duration: Duration(milliseconds: (max / _pxPerSec * 1000).round()),
          curve: Curves.linear);
      await Future<void>.delayed(_hold);
      if (!mounted || !_scrolling || !_sc.hasClients) break;
      await _sc.animateTo(0,
          duration: Duration(milliseconds: (max / _pxPerSec * 1000).round()),
          curve: Curves.linear);
      await Future<void>.delayed(_hold);
    }
    _scrolling = false;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tp = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: 1,
          textDirection: TextDirection.ltr,
        )..layout();
        final overflow = tp.width - constraints.maxWidth;

        if (overflow <= _threshold) {
          return Text(widget.text,
              style: widget.style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis);
        }

        // 超宽：可裁剪滚动视图，帧后启动往返循环
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _loop();
        });
        return SingleChildScrollView(
          controller: _sc,
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          child: Text(widget.text, style: widget.style, maxLines: 1),
        );
      },
    );
  }
}
