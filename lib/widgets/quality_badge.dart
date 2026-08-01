import 'package:flutter/material.dart';

import '../services/sources/bilibili/stream_select.dart';

/// 音质徽章：Hi-Res 金 / 杜比 紫 / 其他灰。
class QualityBadge extends StatelessWidget {
  const QualityBadge({super.key, required this.choice, this.compact = false});

  final StreamChoice choice;

  /// 紧凑模式（列表条目用，更小字号与内边距）。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch ((choice.isLossless, choice.isDolby)) {
      (true, _) => (const Color(0xFFD4A017), 'Hi-Res 无损'),
      (_, true) => (Colors.deepPurple, '杜比全景声'),
      _ => (Colors.grey, choice.qualityLabel),
    };
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: compact ? 6 : 10, vertical: compact ? 2 : 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(99), // 胶囊（风格指南）
        boxShadow: [
          if (choice.isLossless || choice.isDolby)
            BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 13),
        ],
      ),
      child: Text(
        label,
        style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
            fontSize: compact ? 10 : 12),
      ),
    );
  }
}
