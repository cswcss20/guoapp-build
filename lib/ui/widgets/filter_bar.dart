import 'dart:async';

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
          _FilterGroupRow(
            key: ValueKey(group.id),
            group: group,
            picks: widget.picks,
            onPick: widget.onPick,
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

/// One filter group row: a fixed label, a horizontally scrollable chip
/// row, and a chevron at each end. Each row owns its ScrollController so
/// the arrows track that row's scroll position independently.
///
/// A chevron scrolls by ~80% of the visible width with animation. When
/// the row's content fits, both chevrons are hidden; otherwise the
/// chevron for a direction that cannot scroll further is dimmed
/// (disabled) instead of hidden, so the user can tell at a glance which
/// way still has more. Drag / swipe / Shift+wheel scrolling is unchanged
/// (the same SingleChildScrollView as before).
class _FilterGroupRow extends StatefulWidget {
  const _FilterGroupRow({
    super.key,
    required this.group,
    required this.picks,
    required this.onPick,
  });
  final CatalogFilterGroup group;
  final Map<String, String> picks;
  final void Function(String groupId, String optionId) onPick;

  @override
  State<_FilterGroupRow> createState() => _FilterGroupRowState();
}

class _FilterGroupRowState extends State<_FilterGroupRow> {
  final _controller = ScrollController();
  bool _hasOverflow = false;
  bool _canLeft = false;
  bool _canRight = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_updateArrows);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateArrows());
  }

  @override
  void didUpdateWidget(covariant _FilterGroupRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The options may have changed (new group object): re-check the
    // scroll extents once the new layout is in place.
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateArrows());
  }

  @override
  void dispose() {
    _controller.removeListener(_updateArrows);
    _controller.dispose();
    super.dispose();
  }

  void _updateArrows() {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final hasOverflow = position.maxScrollExtent > 1.0;
    final canLeft = position.pixels > 1.0;
    final canRight = position.pixels < position.maxScrollExtent - 1.0;
    if (hasOverflow == _hasOverflow &&
        canLeft == _canLeft &&
        canRight == _canRight) {
      return;
    }
    final overflowChanged = hasOverflow != _hasOverflow;
    setState(() {
      _hasOverflow = hasOverflow;
      _canLeft = canLeft;
      _canRight = canRight;
    });
    if (overflowChanged) {
      // Showing or hiding the chevrons changes the viewport width, which
      // changes the scroll extents: re-check once the new layout lands.
      WidgetsBinding.instance.addPostFrameCallback((_) => _updateArrows());
    }
  }

  void _scroll(double direction) {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final target =
        (position.pixels + direction * position.viewportDimension * 0.8)
            .clamp(0.0, position.maxScrollExtent)
            .toDouble();
    unawaited(
      _controller.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      ),
    );
  }

  Widget _chevron({
    required IconData icon,
    required String tooltip,
    required bool enabled,
    required VoidCallback onPressed,
  }) {
    return Visibility(
      visible: _hasOverflow,
      child: IconButton(
        icon: Icon(icon, size: 20),
        tooltip: zh(tooltip),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        onPressed: enabled ? onPressed : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 60,
          child: Text(
            zh(widget.group.name),
            style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
          ),
        ),
        _chevron(
          icon: Icons.chevron_left,
          tooltip: '向左捲動',
          enabled: _canLeft,
          onPressed: () => _scroll(-1),
        ),
        Expanded(
          child: SingleChildScrollView(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final option in widget.group.options) ...[
                  ChoiceChip(
                    label: Text(zh(option.name)),
                    selected:
                        (widget.picks[widget.group.id] ?? '') == option.id,
                    showCheckmark: false,
                    shape: const StadiumBorder(),
                    onSelected: (_) =>
                        widget.onPick(widget.group.id, option.id),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ),
        _chevron(
          icon: Icons.chevron_right,
          tooltip: '向右捲動',
          enabled: _canRight,
          onPressed: () => _scroll(1),
        ),
      ],
    );
  }
}
