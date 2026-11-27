import 'package:flutter/material.dart';

import '../../zh_script.dart';
import 'focus_ring.dart';

/// 卡片封面直圖／橫圖切換（分段膠囊）。value 為 'portrait' / 'landscape'，
/// 對應 LocalStore 的 coverCardAspect 設定。
class CoverAspectToggle extends StatelessWidget {
  const CoverAspectToggle({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _segment(context, 'portrait', zh('直图')),
          _segment(context, 'landscape', zh('横图')),
        ],
      ),
    );
  }

  Widget _segment(BuildContext context, String mode, String label) {
    final colors = Theme.of(context).colorScheme;
    final selected = value == mode;
    final portrait = mode == 'portrait';
    final foreground = selected
        ? colors.onSecondaryContainer
        : colors.onSurfaceVariant;
    return FocusRing(
      radius: 999,
      child: InkWell(
        onTap: selected ? null : () => onChanged(mode),
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: selected ? colors.secondaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: portrait ? 9 : 14,
                height: portrait ? 13 : 9,
                decoration: BoxDecoration(
                  border: Border.all(color: foreground, width: 1.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: foreground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
