import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core_bridge.dart';
import '../../drama_feed.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../source_catalog.dart';
import '../../zh_script.dart';
import '../app_scope.dart';
import '../detail/detail_page.dart';
import '../shell/app_shell.dart';
import '../theme/motion.dart';
import '../widgets/category_tabs.dart';
import '../widgets/choice_panel.dart';
import '../widgets/drama_grid.dart';
import '../widgets/filter_bar.dart';
import '../widgets/follow_button.dart';
import '../widgets/focus_ring.dart';
import '../widgets/motion/motion_widgets.dart';
import '../widgets/search_field.dart';
import '../widgets/status_view.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.store,
    required this.source,
    this.query = '',
  });
  final LocalStore store;
  final SourceSite source;
  final String query;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final _controller = TextEditingController(text: widget.query);
  final _focus = FocusNode();
  late AppRepository _repository;
  late SourceSite _source;
  late SourceCatalog _catalog;
  bool _allSources = false;
  DramaFeed? _results;
  _AllSearchFeed? _allResults;
  String _submitted = '';
  List<String> _suggestions = const [];
  Timer? _debounce;
  int _suggestion = 0;
  final _shownSuggestions = <Object>{};
  // Search filter groups are per source, not per query: loaded once for
  // the source, while picks reset on every new submission.
  List<CatalogFilterGroup>? _filterGroups;
  Map<String, String> _filterPicks = {};
  bool _filterLoading = false;
  bool _ready = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    _repository = AppScope.of(context).repository;
    _source = widget.source;
    _catalog = SourceCatalog(_repository, _source);
    if (widget.query.trim().isNotEmpty) _submit(widget.query);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _suggestion++;
    unawaited(_repository.cancelSuggestions());
    unawaited(_repository.cancelSearchAll());
    _results?.dispose();
    _allResults?.dispose();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _forget(String query) {
    unawaited(HapticFeedback.selectionClick());
    unawaited(widget.store.forgetSearch(query).catchError((Object _) {}));
  }

  Future<void> _toggleFavoriteTag(String sourceId, String tag) async {
    final query = tag.trim();
    if (query.isEmpty) return;
    unawaited(HapticFeedback.selectionClick());
    try {
      final added = await widget.store.toggleFavoriteTag(sourceId, query);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            persist: false,
            content: Text(
              zh(added ? '已收藏标签「$query」' : '已取消收藏标签「$query」'),
            ),
          ),
        );
    } catch (failure) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$failure')));
    }
  }

  Widget _favoriteTagAction() => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final saved = widget.store.isFavoriteTag(_source.id, _submitted);
      return FocusRing(
        radius: 20,
        child: IconButton(
          tooltip: zh(saved ? '取消收藏标签' : '收藏标签'),
          onPressed: () => _toggleFavoriteTag(_source.id, _submitted),
          icon: Icon(
            saved ? Icons.star_rounded : Icons.star_border_rounded,
            color: saved ? Theme.of(context).colorScheme.primary : null,
          ),
        ),
      );
    },
  );

  void _submit(String text) {
    final query = text.trim();
    if (query.isEmpty) return;
    _controller.text = query;
    _focus.unfocus();
    _debounce?.cancel();
    _suggestion++;
    unawaited(widget.store.rememberSearch(query).catchError((Object _) {}));
    _results?.dispose();
    _results = null;
    _allResults?.dispose();
    _allResults = null;
    _filterPicks = {};
    if (_allSources) {
      final feed = _allResults = _AllSearchFeed(
        load: (page) => _repository.searchAll(query, page: page),
        allowed: {for (final site in widget.store.sources) site.id},
      )..addListener(() => setState(() {}));
      unawaited(feed.reload());
    } else {
      final results = _results = DramaFeed(
        load: (page, _) =>
            _catalog.search(query, page: page, filters: _filterPicks),
      )..addListener(() => setState(() {}));
      unawaited(results.reload());
      unawaited(_loadSearchFilters());
    }
    setState(() {
      _submitted = query;
      _suggestions = const [];
    });
  }

  /// Switches between cross-source search (empty [id]) and one source.
  /// Re-runs the submitted query, if any, so the screen never shows one
  /// mode's results under another mode's selector.
  void _selectSource(String id) {
    if (id.isEmpty) {
      if (_allSources) return;
      _allSources = true;
    } else {
      final site = widget.store.sources.firstWhere(
        (site) => site.id == id,
        orElse: () => _source,
      );
      if (!_allSources && site.id == _source.id) return;
      _source = site;
      _catalog = SourceCatalog(_repository, site);
      _filterGroups = null;
      _filterPicks = {};
      _allSources = false;
    }
    if (_submitted.isNotEmpty) {
      _submit(_submitted);
    } else {
      setState(() {});
    }
  }

  Future<void> _loadSearchFilters() async {
    if (_filterGroups != null || _filterLoading) return;
    _filterLoading = true;
    final catalog = _catalog;
    try {
      final groups = await catalog.searchFilters();
      if (!mounted) return;
      // A source switch mid-flight must not install the old source's
      // groups under the new source.
      if (identical(catalog, _catalog)) _filterGroups = groups;
    } catch (_) {
      // No groups: the bar simply stays hidden, like on catalog tabs
      // for modules without a filters export.
      if (!mounted) return;
      if (identical(catalog, _catalog)) _filterGroups = const [];
    }
    _filterLoading = false;
    if (mounted) setState(() {});
  }

  void _setFilterPick(String groupId, String optionId) {
    final picks = {..._filterPicks};
    if (optionId.isEmpty) {
      picks.remove(groupId);
    } else {
      picks[groupId] = optionId;
    }
    _filterPicks = picks;
    final results = _results;
    if (results != null) unawaited(results.reload(force: true));
    setState(() {});
  }

  Widget? _filterBar(double inset) {
    final groups = _filterGroups;
    if (groups == null || groups.isEmpty) return null;
    return Padding(
      padding: EdgeInsets.fromLTRB(inset, 12, inset, 0),
      child: FilterBar(
        groups: groups,
        picks: _filterPicks,
        onPick: _setFilterPick,
      ),
    );
  }

  void _changed(String text) {
    _debounce?.cancel();
    final query = text.trim();
    final generation = ++_suggestion;
    // Suggestions are per source; cross-source mode has none.
    if (_allSources || !_source.searchSuggestions || query.isEmpty) {
      setState(() => _suggestions = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final items = await _repository.suggestions(_source.id, query);
        if (mounted && generation == _suggestion) {
          setState(() => _suggestions = items);
        }
      } catch (_) {}
    });
  }

  void _open(Drama drama) => openPage<void>(
    context,
    (_) => DetailPage(store: widget.store, drama: drama),
  );

  @override
  Widget build(BuildContext context) {
    final field = SearchField(
      hint: _allSources ? '在全部来源中搜索' : '在 ${_source.name} 中搜索',
      controller: _controller,
      focusNode: _focus,
      autofocus: widget.query.isEmpty,
      onChanged: _changed,
      onSubmitted: _submit,
      letterKeyboard: widget.store.televisionKeyboard,
      matches: !_allSources && _source.searchSuggestions
          ? (query) => _repository.suggestions(_source.id, query)
          : null,
    );
    if (AppScope.of(context).television) {
      return Scaffold(
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                televisionInset,
                27,
                televisionInset,
                0,
              ),
              child: Row(
                spacing: 8,
                children: [
                  Expanded(child: field),
                  if (_submitted.isNotEmpty && !_allSources)
                    _favoriteTagAction(),
                ],
              ),
            ),
            Expanded(child: FadeSwitcher(child: _body(context))),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Padding(
          padding: EdgeInsets.only(right: _submitted.isEmpty ? 16 : 4),
          child: field,
        ),
        actions: [
          if (_submitted.isNotEmpty && !_allSources) ...[
            _favoriteTagAction(),
            const SizedBox(width: 4),
          ],
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: FadeSwitcher(child: _body(context)),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final television = AppScope.of(context).television;
    if (_suggestions.isNotEmpty && _controller.text.trim() != _submitted) {
      return ListView(
        key: const ValueKey('suggest'),
        padding: television
            ? const EdgeInsets.fromLTRB(televisionInset, 8, televisionInset, 27)
            : const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (final (index, item) in _suggestions.indexed)
            EnterOnce(
              key: ValueKey(index),
              id: item,
              played: _shownSuggestions,
              index: index,
              child: TileFocus(
                builder: (focusNode) => ListTile(
                  focusNode: focusNode,
                  leading: const Icon(Icons.search_rounded),
                  title: Text(item),
                  onTap: () => _submit(item),
                ),
              ),
            ),
        ],
      );
    }
    final inset = television
        ? televisionInset
        : AppScope.formFactorOf(context) == FormFactor.phone
        ? 16.0
        : 24.0;
    final Widget content;
    if (_allSources) {
      content = _allContent(context, inset, television);
    } else if (_results == null) {
      content = KeyedSubtree(
        key: const ValueKey('recent'),
        child: _recent(context),
      );
    } else {
      content = _singleContent(context, inset, television, _results!);
    }
    // The filter bar stays visible above every single-source results
    // state — including an empty filtered result — so the user can
    // always change the picks instead of being stuck on a stale list
    // with no way back. Cross-source mode has no filter bar: picks are
    // per source.
    final bar = _allSources ? null : _filterBar(inset);
    return Column(
      children: [
        _sourceSelector(context, inset),
        if (bar != null) bar,
        Expanded(child: content),
      ],
    );
  }

  Widget _sourceSelector(BuildContext context, double inset) {
    final sources = [
      // The page may be opened for a source the store no longer lists
      // (disabled since, say); keep it selectable so the selector's
      // value always matches an option.
      if (!widget.store.sources.any((site) => site.id == _source.id)) _source,
      ...widget.store.sources,
    ];
    if (sources.length < 2) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: AppScope.formFactorOf(context) == FormFactor.phone
            ? 0
            : inset,
      ),
      child: CategoryTabs<String>(
        options: [
          ChoiceOption('', zh('全部来源')),
          for (final site in sources) ChoiceOption(site.id, site.name),
        ],
        selected: _allSources ? '' : _source.id,
        onSelected: _selectSource,
      ),
    );
  }

  Widget _singleContent(
    BuildContext context,
    double inset,
    bool television,
    DramaFeed results,
  ) {
    if (results.items.isEmpty) {
      if (results.loading) {
        return const StatusView.loading(
          key: ValueKey('loading'),
          title: '正在搜索',
        );
      } else if (results.error.isNotEmpty) {
        return StatusView(
          key: ValueKey('error'),
          title: '搜索失败',
          message: results.error,
          icon: Icons.cloud_off_rounded,
          action: '重试',
          onAction: () => results.reload(),
        );
      } else {
        return StatusView(
          key: ValueKey('empty'),
          title: '没有找到「$_submitted」',
          message: '换个关键词试试',
          icon: Icons.search_off_rounded,
        );
      }
    }
    return LayoutBuilder(
      key: ValueKey(('results', _submitted)),
      builder: (context, constraints) => AutoLoadMore(
        feed: results,
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, television ? 16 : 8, inset, 0),
              sliver: DramaSliverGrid(
                width: constraints.maxWidth - inset * 2,
                items: results.items,
                autofocus: television,
                onOpen: _open,
                onMore: (drama) => quickFollow(context, widget.store, drama),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                inset,
                8,
                inset,
                television ? 27 : 16,
              ),
              sliver: SliverToBoxAdapter(child: FeedFooter(feed: results)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _allContent(BuildContext context, double inset, bool television) {
    final feed = _allResults;
    if (feed == null) {
      return KeyedSubtree(
        key: const ValueKey('recent'),
        child: _recent(context),
      );
    }
    if (feed.groups.isEmpty) {
      if (feed.loading) {
        return const StatusView.loading(
          key: ValueKey('all-loading'),
          title: '正在搜索',
        );
      }
      if (feed.error.isNotEmpty) {
        return StatusView(
          key: const ValueKey('all-error'),
          title: '搜索失败',
          message: feed.error,
          icon: Icons.cloud_off_rounded,
          action: '重试',
          onAction: () => feed.reload(),
        );
      }
      return StatusView(
        key: const ValueKey('all-empty'),
        title: '没有找到「$_submitted」',
        message: '换个关键词试试',
        icon: Icons.search_off_rounded,
      );
    }
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (notification.depth == 0 &&
            notification.metrics.axis == Axis.vertical &&
            notification.metrics.extentAfter < 600 &&
            feed.canLoadMore) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => feed.loadMore(),
          );
        }
        return false;
      },
      child: LayoutBuilder(
        key: ValueKey(('all-results', _submitted)),
        builder: (context, constraints) {
          final width = constraints.maxWidth - inset * 2;
          return CustomScrollView(
            slivers: [
              for (final (index, group) in feed.groups.indexed) ...[
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset, 16, inset, 8),
                  sliver: SliverToBoxAdapter(
                    child: _groupHeader(context, group),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: inset),
                  sliver: DramaSliverGrid(
                    width: width,
                    items: group.items.take(8).toList(),
                    autofocus: television && index == 0,
                    onOpen: _open,
                    onMore: (drama) =>
                        quickFollow(context, widget.store, drama),
                  ),
                ),
              ],
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  inset,
                  16,
                  inset,
                  television ? 27 : 16,
                ),
                sliver: SliverToBoxAdapter(child: _allFooter(context, feed)),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _groupHeader(BuildContext context, SearchAllGroup group) {
    final theme = Theme.of(context);
    final more = group.hasMore || group.items.length > 8;
    return Row(
      children: [
        Expanded(
          child: Text(
            '${group.name} · ${group.items.length}',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (more)
          FocusRing(
            radius: 999,
            child: TextButton(
              onPressed: () => _selectSource(group.source),
              child: Text(zh('去这个来源看全部')),
            ),
          ),
      ],
    );
  }

  Widget _allFooter(BuildContext context, _AllSearchFeed feed) {
    final theme = Theme.of(context);
    final caption = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final failedNames = [
      for (final id in feed.failed) SourceSite.byId(id).name,
    ];
    return Column(
      children: [
        if (failedNames.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              zh('以下来源没有回应：${failedNames.join('、')}'),
              style: caption,
              textAlign: TextAlign.center,
            ),
          ),
        SizedBox(
          height: 48,
          child: Center(
            child: feed.loadingMore
                ? const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  )
                : feed.error.isNotEmpty
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          feed.error,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: caption,
                        ),
                      ),
                      const SizedBox(width: 8),
                      FocusRing(
                        radius: 999,
                        child: TextButton(
                          onPressed: feed.hasMore ? feed.loadMore : feed.reload,
                          child: Text(zh('重试')),
                        ),
                      ),
                    ],
                  )
                : feed.hasMore
                ? null
                : Text(zh('已经到底了'), style: caption),
          ),
        ),
      ],
    );
  }

  Widget _recent(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final recent = widget.store.recentSearches;
      final savedTags = [
        for (final item in widget.store.favoriteTags)
          if (_allSources || item.source == _source.id) item,
      ];
      return FadeSwitcher(
        child: _recentContent(context, recent, savedTags),
      );
    },
  );

  Widget _recentContent(
    BuildContext context,
    List<String> recent,
    List<FavoriteTag> savedTags,
  ) {
    if (recent.isEmpty && savedTags.isEmpty) {
      return StatusView(
        key: const ValueKey('empty'),
        title: _allSources ? '在全部来源中搜索' : '在 ${_source.name} 中搜索',
        message: '输入剧名或关键词',
        icon: Icons.search_rounded,
      );
    }
    final theme = Theme.of(context);
    return ListView(
      key: const ValueKey('recent'),
      padding: AppScope.of(context).television
          ? const EdgeInsets.fromLTRB(televisionInset, 8, televisionInset, 27)
          : const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (savedTags.isNotEmpty) ...[
          Text(
            zh('收藏标签'),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final item in savedTags)
                FocusRing(
                  radius: 8,
                  child: GestureDetector(
                    onLongPress: () =>
                        _toggleFavoriteTag(item.source, item.tag),
                    onSecondaryTap: () =>
                        _toggleFavoriteTag(item.source, item.tag),
                    child: ActionChip(
                      avatar: Icon(
                        Icons.star_rounded,
                        size: 16,
                        color: theme.colorScheme.primary,
                      ),
                      label: Text(item.tag),
                      onPressed: () => _submit(item.tag),
                    ),
                  ),
                ),
            ],
          ),
          if (recent.isNotEmpty) const SizedBox(height: 20),
        ],
        if (recent.isNotEmpty) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  zh('最近搜索'),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              FocusRing(
                radius: 999,
                child: TextButton(
                  onPressed: () => widget.store
                      .clearRecentSearches()
                      .catchError((Object _) {}),
                  child: Text(zh('清空')),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          AnimatedSize(
            duration: Motion.of(context, Motion.medium),
            curve: Motion.enter,
            alignment: Alignment.topLeft,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final query in recent)
                  FocusRing(
                    radius: 8,
                    child: GestureDetector(
                      onLongPress: () => _forget(query),
                      onSecondaryTap: () => _forget(query),
                      child: ActionChip(
                        avatar: const Icon(Icons.history_rounded, size: 16),
                        label: Text(query),
                        onPressed: () => _submit(query),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Cross-source search state: per-source groups merged page by page.
/// [allowed] is the set of source ids the store currently permits and
/// enables — the core searches every registered provider, so groups (and
/// failures) from sources the user turned off or the profile does not
/// permit are dropped here and never displayed.
class _AllSearchFeed extends ChangeNotifier {
  _AllSearchFeed({required this.load, required this.allowed});
  final Future<SearchAllPage> Function(int page) load;
  final Set<String> allowed;

  List<SearchAllGroup> _groups = const [];
  List<String> _failed = const [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  String _error = '';
  int _next = 1;
  int _generation = 0;
  bool _disposed = false;

  List<SearchAllGroup> get groups => _groups;
  List<String> get failed => _failed;
  bool get loading => _loading;
  bool get loadingMore => _loadingMore;
  bool get hasMore => _hasMore;
  String get error => _error;
  bool get canLoadMore => _hasMore && !_loading && !_loadingMore;

  Future<void> reload() async {
    final generation = ++_generation;
    _loading = true;
    _loadingMore = false;
    _error = '';
    _notify();
    try {
      final page = await load(1);
      if (generation != _generation) return;
      _accept(page, more: false);
    } catch (failure) {
      if (generation != _generation) return;
      _error = '$failure';
    }
    _loading = false;
    _notify();
  }

  Future<void> loadMore() async {
    if (!canLoadMore) return;
    final generation = _generation;
    _loadingMore = true;
    _error = '';
    _notify();
    try {
      final page = await load(_next);
      if (generation != _generation) return;
      _accept(page, more: true);
    } catch (failure) {
      if (generation != _generation) return;
      _error = '$failure';
    }
    _loadingMore = false;
    _notify();
  }

  void _accept(SearchAllPage page, {required bool more}) {
    final groups = [
      for (final group in page.groups)
        if (allowed.contains(group.source)) group,
    ];
    _failed = [
      for (final id in page.failed)
        if (allowed.contains(id)) id,
    ];
    if (!more) {
      _groups = groups;
    } else {
      final byId = {for (final group in _groups) group.source: group};
      for (final group in groups) {
        final old = byId[group.source];
        if (old == null) {
          _groups = [..._groups, group];
          byId[group.source] = group;
        } else {
          final known = {for (final drama in old.items) drama.id};
          byId[group.source] = SearchAllGroup(
            old.source,
            old.name,
            [
              ...old.items,
              for (final drama in group.items)
                if (known.add(drama.id)) drama,
            ],
            hasMore: group.hasMore,
          );
        }
      }
      _groups = [for (final group in _groups) byId[group.source]!];
    }
    _next = page.page + 1;
    // Recompute from the groups actually shown: the core's hasMore may
    // rest on a source this profile does not display.
    _hasMore = _groups.any((group) => group.hasMore);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
