import 'package:flutter/material.dart';

import '../../models.dart';
import '../../zh_script.dart';

/// Filter rows for a catalog category: one row per group declared by the
/// source module, single-select chips, the first option being "全部/預設".
///
/// The bar starts collapsed (a single header row) so a long option list
/// (e.g. fourkvm's 79 years) does not push the grid off-screen, especially
/// on phones. Each group's chips sit in one horizontally scrollable row
/// instead of wrapping, so the expanded bar stays a bounded height.
class FilterBar extends StatefulWidget {
  const FilterBar({
    super.key,
    required this.groups,
    required this.picks,
    required this.onPick,
  });
  final List<CatalogFilterGroup> groups;
  final Map<String, String> picks;
  final void Function(String groupId, String optionId) onPick;

  @override
  State<FilterBar> createState() => _FilterBarState();
}

class _FilterBarState extends State<FilterBar> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final active = <String>[];
    for (final group in widget.groups) {
      final picked = widget.picks[group.id] ?? '';
      if (picked.isEmpty) continue;
      for (final option in group.options) {
        if (option.id == picked) {
          active.add('${zh(group.name)} ${zh(option.name)}');
          break;
        }
      }
    }
    final children = <Widget>[
      InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Text(
                '篩選',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  active.isEmpty ? '未篩選' : active.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: active.isEmpty
                        ? colors.onSurfaceVariant
                        : colors.onSurface,
                  ),
                ),
              ),
              Icon(
                _expanded ? Icons.expand_less : Icons.expand_more,
                size: 20,
                color: colors.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    ];
    if (_expanded) {
      for (final (index, group) in widget.groups.indexed) {
        if (index > 0) children.add(const SizedBox(height: 10));
        children.add(
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 60,
                child: Text(
                  zh(group.name),
                  style: TextStyle(
                    fontSize: 13,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final option in group.options) ...[
                        ChoiceChip(
                          label: Text(zh(option.name)),
                          selected:
                              (widget.picks[group.id] ?? '') == option.id,
                          showCheckmark: false,
                          shape: const StadiumBorder(),
                          onSelected: (_) =>
                              widget.onPick(group.id, option.id),
                        ),
                        const SizedBox(width: 8),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}
