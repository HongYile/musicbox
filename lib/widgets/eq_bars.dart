import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 跳动的均衡器三条杠（网易云"播放中"指示）。
/// [animate]=false（暂停）时静止为低高度静态条。
class EqBars extends StatefulWidget {
  const EqBars({
    super.key,
    this.color = const Color(0xFF2864F0),
    this.size = 18,
    this.animate = true,
  });

  final Color color;
  final double size;
  final bool animate;

  @override
  State<EqBars> createState() => _EqBarsState();
}

class _EqBarsState extends State<EqBars> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat();

  @override
  void didUpdateWidget(EqBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate == oldWidget.animate) return;
    if (widget.animate) {
      _c.repeat();
    } else {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final heights = widget.animate
            ? (() {
                final t = _c.value * 2 * math.pi;
                return [
                  0.45 + 0.35 * (0.5 + 0.5 * math.sin(t)),
                  0.45 + 0.55 * (0.5 + 0.5 * math.sin(t + 1.4)),
                  0.45 + 0.40 * (0.5 + 0.5 * math.sin(t + 2.8)),
                ];
              })()
            : const [0.35, 0.55, 0.42]; // 暂停：静态
        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final h in heights)
                Container(
                  width: widget.size / 5.5,
                  height: widget.size * h,
                  decoration: BoxDecoration(
                    color: widget.color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
