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
import '../widgets/cover_aspect_toggle.dart';
import '../widgets/drama_grid.dart';
import '../widgets/filter_bar.dart';
import '../widgets/follow_button.dart';
import '../widgets/focus_ring.dart';
import '../widgets/motion/motion_widgets.dart';
import '../widgets/search_field.dart';
import '../widgets/self_heal.dart';
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
  // 全部源搜索的流式状态：核心那边每返回一个站源就更新一次快照，
  // 页面按会话号轮询，边到边加，不等最慢的站源。
  SearchProgress? _cross;
  String _crossError = '';
  String _searchId = '';
  Timer? _poll;
  int _generation = 0;
  int _pollFailures = 0;
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
    widget.store.addListener(_storeChanged);
    _repository = AppScope.of(context).repository;
    _source = widget.source;
    _catalog = SourceCatalog(_repository, _source);
    if (widget.query.trim().isNotEmpty) _submit(widget.query);
  }

  void _storeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.store.removeListener(_storeChanged);
    _debounce?.cancel();
    _suggestion++;
    _generation++;
    _poll?.cancel();
    final search = _searchId;
    if (search.isNotEmpty) unawaited(_repository.searchCancel(search));
    unawaited(_repository.cancelSuggestions());
    _results?.dispose();
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
    _filterPicks = {};
    if (_allSources) {
      _startCross(query);
      return;
    }
    _resetCross();
    _results?.dispose();
    final results = _results = DramaFeed(
      load: (page, _) =>
          _catalog.search(query, page: page, filters: _filterPicks),
    )..addListener(() => setState(() {}));
    unawaited(results.reload());
    unawaited(_loadSearchFilters());
    setState(() {
      _submitted = query;
      _suggestions = const [];
    });
  }

  // ---- 全部源：启动 + 轮询增量结果 ----

  void _startCross(String query) {
    _results?.dispose();
    _results = null;
    final generation = ++_generation;
    _stopPolling(cancelRemote: true);
    // 参与搜索的站源就是本机已开启的站源（与旧版 Dart 侧过滤同口径，
    // 现在直接把名单交给核心，不再搜完才丢）。
    final sources = [for (final site in widget.store.sources) site.id];
    setState(() {
      _submitted = query;
      _suggestions = const [];
      _crossError = '';
      _pollFailures = 0;
      _cross = SearchProgress(
        query: query,
        pending: sources,
        total: sources.length,
      );
    });
    if (sources.isEmpty) {
      setState(() => _crossError = zh('没有已开启的站源，请先在「站源」里开启'));
      return;
    }
    unawaited(() async {
      try {
        final result = await _repository.searchStart(sources, query);
        if (!mounted || generation != _generation) {
          unawaited(_repository.searchCancel(result.id));
          return;
        }
        _searchId = result.id;
        setState(() => _cross = result);
        _schedulePoll(generation);
      } catch (error) {
        if (!mounted || generation != _generation) return;
        setState(() => _crossError = error.toString());
      }
    }());
  }

  /// 轮询间隔压到 250ms 左右：站源一回来就能刷到屏幕上，
  /// 又不至于把原生核心的请求通道打满。
  void _schedulePoll(int generation) {
    _poll?.cancel();
    _poll = Timer(const Duration(milliseconds: 250), () async {
      if (!mounted || generation != _generation) return;
      final search = _searchId;
      if (search.isEmpty) return;
      try {
        final result = await _repository.searchPoll(search);
        if (!mounted || generation != _generation) return;
        _pollFailures = 0;
        setState(() => _cross = result);
        if (!result.finished) _schedulePoll(generation);
      } catch (error) {
        if (!mounted || generation != _generation) return;
        if (++_pollFailures >= 4) {
          setState(() => _crossError = error.toString());
          return;
        }
        _schedulePoll(generation);
      }
    });
  }

  void _stopPolling({bool cancelRemote = false}) {
    _poll?.cancel();
    _poll = null;
    final search = _searchId;
    _searchId = '';
    if (cancelRemote && search.isNotEmpty) {
      unawaited(_repository.searchCancel(search));
    }
  }

  void _resetCross() {
    _generation++;
    _stopPolling(cancelRemote: true);
    _pollFailures = 0;
    _crossError = '';
    if (_cross != null) setState(() => _cross = null);
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
    (_) => DetailPage(
      store: widget.store,
      drama: drama,
      coverAspect: widget.store.coverCardAspectSearch,
    ),
  );

  Widget _aspectToggle() => CoverAspectToggle(
    value: widget.store.coverCardAspectSearch,
    onChanged: (mode) => unawaited(
      widget.store.setCoverCardAspectSearch(mode).catchError((Object _) {}),
    ),
  );

  /// Opens a merged cross-source result. When other sources carry the
  /// same title (peers), let the user pick which copy to open first.
  Future<void> _openCross(Drama drama) async {
    if (drama.peers.isEmpty) {
      _open(drama);
      return;
    }
    final picked = await showChoicePanel<Drama>(
      context: context,
      title: drama.title,
      options: [
        for (final copy in [drama, ...drama.peers])
          ChoiceOption(
            copy,
            '${SourceSite.byId(copy.source).name}'
            '${copy.episodes > 0 ? ' · ${copy.episodes}集' : ''}',
          ),
      ],
      selected: drama,
      grid: ChoiceGrid.sources,
    );
    if (picked != null && mounted) _open(picked);
  }

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
                  _aspectToggle(),
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
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Center(child: _aspectToggle()),
          ),
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
      content = _crossBody(context, inset, television);
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
        return ErrorStatusView(
          key: ValueKey('error'),
          title: '搜索失败',
          message: results.error,
          icon: Icons.cloud_off_rounded,
          source: _source.id,
          store: widget.store,
          verify: webViewVerifier(context),
          onRetry: () => results.reload(),
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
                coverAspect: widget.store.coverCardAspectSearch,
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

  /// 全部源的流式结果：头部显示进度，下面就是已经搜到的条目，边到边加。
  /// 条目已在核心侧按标题/年份/集数归一去重，同一部剧只出一条，
  /// 副标题标明主站源和还有几个源有同一部剧，点开时可先揀源。
  Widget _crossBody(BuildContext context, double inset, bool television) {
    if (_cross == null && _submitted.isEmpty) {
      return KeyedSubtree(
        key: const ValueKey('recent'),
        child: _recent(context),
      );
    }
    if (_crossError.isNotEmpty && (_cross?.items.isEmpty ?? true)) {
      return StatusView(
        key: const ValueKey('all-error'),
        title: '搜索失败',
        message: _crossError,
        icon: Icons.cloud_off_rounded,
        action: '重试',
        onAction: () => _submit(_submitted),
      );
    }
    final progress = _cross;
    if (progress == null || progress.items.isEmpty) {
      if (progress != null && progress.finished) {
        return StatusView(
          key: const ValueKey('all-empty'),
          title: '没有找到「$_submitted」',
          message: progress.warning.isNotEmpty
              ? progress.warning
              : '换个关键词试试',
          icon: Icons.search_off_rounded,
        );
      }
      // 首个结果还没回来：给转圈 + 实时进度，让用户知道在搜哪些站源。
      return Center(
        key: const ValueKey('all-loading'),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox.square(
                dimension: 32,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(height: 20),
              Text(
                zh('正在搜索全部源'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (progress != null && progress.total > 0) ...[
                const SizedBox(height: 16),
                _crossHeader(context, progress, _crossError),
              ],
            ],
          ),
        ),
      );
    }
    return LayoutBuilder(
      key: ValueKey(('all-results', _submitted)),
      builder: (context, constraints) => CustomScrollView(
        // 结果一直在变长，保持滚动位置别被重建顶回去。
        key: const PageStorageKey<String>('search-cross'),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 12, inset, 0),
            sliver: SliverToBoxAdapter(
              child: _crossHeader(context, progress, _crossError),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 12, inset, 0),
            sliver: DramaSliverGrid(
              width: constraints.maxWidth - inset * 2,
              items: progress.items,
              coverAspect: widget.store.coverCardAspectSearch,
              autofocus: television,
              onOpen: _openCross,
              onMore: (drama) => quickFollow(context, widget.store, drama),
              subtitleOf: (drama) {
                final name = SourceSite.byId(drama.source).name;
                return drama.peers.isEmpty
                    ? name
                    : '$name · ${zh('另 ${drama.peers.length} 源')}';
              },
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              inset,
              12,
              inset,
              television ? 27 : 16,
            ),
            sliver: SliverToBoxAdapter(
              child: Text(
                zh(progress.running ? '继续搜索中…' : '已经搜完全部站源'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _crossHeader(
    BuildContext context,
    SearchProgress progress,
    String error,
  ) {
    final theme = Theme.of(context);
    final caption = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final status = progress.running
        ? '已搜索 ${progress.done}/${progress.total} 个站源 · 已找到 ${progress.items.length} 条'
        : '已搜索 ${progress.total} 个站源 · 共 ${progress.items.length} 条';
    final pending = [
      for (final id in progress.pending.take(4)) SourceSite.byId(id).name,
    ].join('、');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox.square(
              dimension: 14,
              child: progress.running
                  ? const CircularProgressIndicator(strokeWidth: 2)
                  : Icon(
                      Icons.travel_explore_rounded,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                zh(status),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        if (progress.running) ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress.total == 0
                  ? null
                  : (progress.done / progress.total).clamp(0.0, 1.0),
              minHeight: 3,
            ),
          ),
          if (progress.pending.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              zh('正在搜索 $pending${progress.pending.length > 4 ? ' 等' : ''}'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: caption,
            ),
          ],
        ],
        if (progress.warning.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            zh(progress.warning),
            style: caption?.copyWith(color: theme.colorScheme.error),
          ),
        ],
        if (error.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            zh('刷新结果时出错：$error'),
            style: caption?.copyWith(color: theme.colorScheme.error),
          ),
        ],
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
