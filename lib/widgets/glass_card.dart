import 'dart:ui';

import 'package:flutter/material.dart';

/// 玻璃拟态卡片（风格指南）：72% 透明白 + 18px 背景模糊 + 1px 细边 + 柔影。
/// 桌面端 hover 时上浮 2px 并加深投影（过渡 .25s）。
class GlassCard extends StatefulWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.margin,
    this.padding,
    this.borderRadius = 16,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry? padding;
  final double borderRadius;
  final VoidCallback? onTap;

  @override
  State<GlassCard> createState() => _GlassCardState();
}

class _GlassCardState extends State<GlassCard> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fill = dark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.white.withValues(alpha: 0.72);
    final border =
        dark ? Colors.white.withValues(alpha: 0.10) : const Color(0xFFDFE6EE);
    final radius = BorderRadius.circular(widget.borderRadius);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        margin: widget.margin,
        transform: Matrix4.translationValues(0, _hover ? -2 : 0, 0),
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: _hover
                  ? const Color(0x1E263E5C)
                  : const Color(0x12263E5C),
              blurRadius: 35,
              offset: Offset(0, _hover ? 16 : 12),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Material(
              // 用带色带形的 Material 作为 ListTile 的最近 Material 祖先，
              // 否则中间的 DecoratedBox 会吞掉水波纹并抛异常。
              color: fill,
              shape: RoundedRectangleBorder(
                borderRadius: radius,
                side: BorderSide(color: border),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: widget.onTap,
                borderRadius: radius,
                child: Padding(
                  padding: widget.padding ?? EdgeInsets.zero,
                  child: widget.child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
