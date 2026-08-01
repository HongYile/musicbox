import 'package:flutter/material.dart';

/// 科技感背景（workspace/tech-style-guide.md）：
/// 浅蓝白渐变底 + 细网格 + 两个缓慢漂移的 Ambient 光斑（青/蓝紫）。
class TechBackground extends StatefulWidget {
  const TechBackground({super.key, required this.child});

  final Widget child;

  @override
  State<TechBackground> createState() => _TechBackgroundState();
}

class _TechBackgroundState extends State<TechBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(seconds: 9))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      children: [
        // 底：145° 渐变（亮：浅蓝白 / 暗：深灰蓝）
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: dark
                    ? const [Color(0xFF141419), Color(0xFF101014)]
                    : const [Color(0xFFF8FBFF), Color(0xFFEEF4F9)],
              ),
            ),
          ),
        ),
        // 细网格（工程图纸感）
        Positioned.fill(child: CustomPaint(painter: _GridPainter(dark: dark))),
        // Ambient 光斑 ×2，缓慢漂移
        AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final t = _c.value;
            return Stack(
              children: [
                Positioned(
                  top: -90 + 26 * t,
                  left: -70 + 18 * t,
                  child: _GlowBlob(
                      color: const Color(0xFF3CCBD9),
                      size: 280,
                      alpha: dark ? 0.12 : 0.20),
                ),
                Positioned(
                  right: -80 + 22 * t,
                  bottom: -70 + 30 * (1 - t),
                  child: _GlowBlob(
                      color: const Color(0xFF8AAEFF),
                      size: 300,
                      alpha: dark ? 0.14 : 0.20),
                ),
              ],
            );
          },
        ),
        Positioned.fill(child: widget.child),
      ],
    );
  }
}

class _GlowBlob extends StatelessWidget {
  const _GlowBlob({required this.color, required this.size, this.alpha = 0.20});

  final Color color;
  final double size;
  final double alpha;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: alpha),
          boxShadow: [
            BoxShadow(
                color: color.withValues(alpha: alpha + 0.02),
                blurRadius: 90,
                spreadRadius: 60),
          ],
        ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  const _GridPainter({this.dark = false});

  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = dark ? const Color(0x0AFFFFFF) : const Color(0x0A2864F0)
      ..strokeWidth = 1;
    const step = 48.0;
    for (var x = 0.0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) =>
      oldDelegate.dark != dark;
}
