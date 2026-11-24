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
import '../widgets/drama_grid.dart';
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
  late SourceCatalog _catalog;
  DramaFeed? _results;
  String _submitted = '';
  List<String> _suggestions = const [];
  Timer? _debounce;
  int _suggestion = 0;
  final _shownSuggestions = <Object>{};
  bool _ready = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    _repository = AppScope.of(context).repository;
    _catalog = SourceCatalog(_repository, widget.source);
    if (widget.query.trim().isNotEmpty) _submit(widget.query);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _suggestion++;
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

  Future<void> _toggleFavoriteTag(String tag) async {
    final query = tag.trim();
    if (query.isEmpty) return;
    unawaited(HapticFeedback.selectionClick());
    try {
      final added = await widget.store.toggleFavoriteTag(
        widget.source.id,
        query,
      );
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
      final saved = widget.store.isFavoriteTag(widget.source.id, _submitted);
      return FocusRing(
        radius: 20,
        child: IconButton(
          tooltip: zh(saved ? '取消收藏标签' : '收藏标签'),
          onPressed: () => _toggleFavoriteTag(_submitted),
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
    final results = _results = DramaFeed(
      load: (page, _) => _catalog.search(query, page: page),
    )..addListener(() => setState(() {}));
    unawaited(results.reload());
    setState(() {
      _submitted = query;
      _suggestions = const [];
    });
  }

  void _changed(String text) {
    _debounce?.cancel();
    final query = text.trim();
    final generation = ++_suggestion;
    if (!widget.source.searchSuggestions || query.isEmpty) {
      setState(() => _suggestions = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final items = await _repository.suggestions(widget.source.id, query);
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
      hint: '在 ${widget.source.name} 中搜索',
      controller: _controller,
      focusNode: _focus,
      autofocus: widget.query.isEmpty,
      onChanged: _changed,
      onSubmitted: _submit,
      letterKeyboard: widget.store.televisionKeyboard,
      matches: widget.source.searchSuggestions
          ? (query) => _repository.suggestions(widget.source.id, query)
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
                  if (_submitted.isNotEmpty) _favoriteTagAction(),
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
          if (_submitted.isNotEmpty) ...[
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
    final results = _results;
    if (results == null) {
      return KeyedSubtree(
        key: const ValueKey('recent'),
        child: _recent(context),
      );
    }
    if (results.items.isEmpty) {
      if (results.loading) {
        return const StatusView.loading(
          key: ValueKey('loading'),
          title: '正在搜索',
        );
      }
      if (results.error.isNotEmpty) {
        return StatusView(
          key: const ValueKey('error'),
          title: '搜索失败',
          message: results.error,
          icon: Icons.cloud_off_rounded,
          action: '重试',
          onAction: () => results.reload(),
        );
      }
      return StatusView(
        key: const ValueKey('empty'),
        title: '没有找到「$_submitted」',
        message: '换个关键词试试',
        icon: Icons.search_off_rounded,
      );
    }
    final inset = television
        ? televisionInset
        : AppScope.formFactorOf(context) == FormFactor.phone
        ? 16.0
        : 24.0;
    return LayoutBuilder(
      key: ValueKey(('results', _submitted)),
      builder: (context, constraints) => AutoLoadMore(
        feed: results,
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                inset,
                television ? 16 : 8,
                inset,
                0,
              ),
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

  Widget _recent(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final recent = widget.store.recentSearches;
      final savedTags = [
        for (final item in widget.store.favoriteTags)
          if (item.source == widget.source.id) item,
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
        title: '在 ${widget.source.name} 中搜索',
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
                    onLongPress: () => _toggleFavoriteTag(item.tag),
                    onSecondaryTap: () => _toggleFavoriteTag(item.tag),
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
