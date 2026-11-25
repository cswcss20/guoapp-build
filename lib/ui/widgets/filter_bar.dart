import 'package:flutter/material.dart';

import '../../models.dart';
import '../../zh_script.dart';

/// Filter rows for a catalog category: one row per group declared by the
/// source module, single-select chips, the first option being "全部/預設".
class FilterBar extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final rows = <Widget>[];
    for (final (index, group) in groups.indexed) {
      if (index > 0) rows.add(const SizedBox(height: 10));
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 60,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  zh(group.name),
                  style: TextStyle(
                    fontSize: 13,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            Expanded(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final option in group.options)
                    ChoiceChip(
                      label: Text(zh(option.name)),
                      selected: (picks[group.id] ?? '') == option.id,
                      showCheckmark: false,
                      shape: const StadiumBorder(),
                      onSelected: (_) => onPick(group.id, option.id),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}
