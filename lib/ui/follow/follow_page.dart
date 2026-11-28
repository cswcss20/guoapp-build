import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core_bridge.dart';
import '../../follow_list.dart';
import '../../library_sync.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../source_modules.dart';
import '../../zh_script.dart';
import '../app_scope.dart';
import '../detail/detail_page.dart';
import '../history/history_page.dart';
import '../search/search_page.dart';
import '../settings/settings_rows.dart';
import '../shell/app_shell.dart';
import '../theme/motion.dart';
import '../widgets/cover_image.dart';
import '../widgets/drama_grid.dart';
import '../widgets/drama_open.dart';
import '../widgets/drama_tile.dart';
import '../widgets/focus_ring.dart';
import '../widgets/motion/motion_widgets.dart';
import '../widgets/page_header.dart';
import '../widgets/search_field.dart';
import '../widgets/status_view.dart';

enum _FollowTab { dramas, tags, library }

enum _LibraryKind { videos, actresses }

typedef _View = ({
  List<Drama> follows,
  List<FavoriteTag> tags,
  List<SourceSite> sources,
  String source,
  List<Drama> shown,
  List<FavoriteTag> shownTags,
  Set<String>? selection,
});

class FollowPage extends StatefulWidget {
  const FollowPage({
    super.key,
    required this.store,
    required this.entryFocus,
    required this.onExitUp,
  });
  final LocalStore store;
  final FocusNode entryFocus;
  final VoidCallback onExitUp;

  @override
  State<FollowPage> createState() => _FollowPageState();
}

class _FollowPageState extends State<FollowPage> {
  final _query = TextEditingController();
  final _editButton = FocusNode();
  final _entered = <Object>{};
  var _tab = _FollowTab.dramas;
  var _source = '';
  var _filter = '';
  var _section = 0;
  Set<String>? _selection;
  var _syncing = false;
  var _librarySource = '';
  var _libraryKind = _LibraryKind.videos;
  final _actressCache = <String, List<Drama>>{};
  final _actressErrors = <String, String>{};
  final _actressLoading = <String>{};

  bool get _inActresses =>
      _tab == _FollowTab.library && _libraryKind == _LibraryKind.actresses;

  List<SourceSite> get _librarySites => [
    for (final site in SourceSite.values)
      if (site.library) site,
  ];

  @override
  void dispose() {
    _query.dispose();
    _editButton.dispose();
    super.dispose();
  }

  void _keepFocus(FocusNode target) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !AppScope.of(context).television) return;
        final focused = FocusManager.instance.primaryFocus;
        if (focused != null && focused is! FocusScopeNode) return;
        if (target.context?.mounted ?? false) {
          revealFocus(target);
        } else {
          widget.onExitUp();
        }
      });

  void _switchTab(_FollowTab next) {
    if (_tab == next) return;
    setState(() {
      _tab = next;
      _source = '';
      _filter = '';
      _selection = null;
    });
  }

  void _switchLibraryTab(String sourceId) {
    if (_tab == _FollowTab.library && _librarySource == sourceId) return;
    setState(() {
      _tab = _FollowTab.library;
      _librarySource = sourceId;
      _libraryKind = _LibraryKind.videos;
      _source = '';
      _filter = '';
      _selection = null;
    });
  }

  void _switchLibraryKind(_LibraryKind kind) {
    if (_libraryKind == kind) return;
    setState(() {
      _libraryKind = kind;
      _selection = null;
    });
    if (kind == _LibraryKind.actresses) _ensureActresses(_librarySource);
  }

  void _ensureActresses(String source) {
    if (source.isEmpty ||
        _actressCache.containsKey(source) ||
        _actressErrors.containsKey(source) ||
        _actressLoading.contains(source)) {
      return;
    }
    _actressLoading.add(source);
    _loadActresses(source);
  }

  Future<void> _loadActresses(String source) async {
    final repository = AppScope.of(context).repository;
    try {
      final items = <Drama>[];
      final seen = <String>{};
      for (var page = 1; page <= 20; page++) {
        final result = await repository.libraryItems(
          source,
          kind: 'actresses',
          page: page,
        );
        for (final drama in result.items) {
          if (drama.id.isNotEmpty && seen.add(drama.id)) items.add(drama);
        }
        if (!result.hasMore) break;
      }
      if (!mounted) return;
      setState(() {
        _actressCache[source] = items;
        _actressErrors.remove(source);
        _actressLoading.remove(source);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _actressErrors[source] = _actressErrorMessage(source, error);
        _actressLoading.remove(source);
      });
    }
  }

  String _actressErrorMessage(String source, Object error) {
    final name = SourceSite.byId(source).name;
    final code = error is AppFailure ? error.code : '';
    final message = '$error';
    final unsupported =
        code == 'library_write_unsupported' ||
        message.contains('未支援') ||
        message.contains('不支持') ||
        message.contains('notImplemented') ||
        message.contains('收藏種類') ||
        message.contains('收藏种类');
    if (unsupported) return '此模組版本未支援女優列表，請更新模組後再試。';
    if (code == 'source_login' ||
        message.contains('登入') ||
        message.contains('登录')) {
      return '$message\n請到「我的 › 模組 › $name」登入後再試。';
    }
    return '女優列表載入失敗：$message\n如未登入，請到「我的 › 模組 › $name」登入後再試。';
  }

  void _retryActresses(String source) {
    setState(() {
      _actressCache.remove(source);
      _actressErrors.remove(source);
    });
    _ensureActresses(source);
  }

  void _switch(int section) {
    if (section == _section) return;
    setState(() {
      _section = section;
      _selection = null;
    });
  }

  void _startEditing() {
    setState(() => _selection = {});
    _keepFocus(widget.entryFocus);
  }

  void _finishEditing() {
    setState(() => _selection = null);
    _keepFocus(_editButton);
  }

  void _toggle(String id) => setState(() {
    final selection = {...?_selection};
    if (!selection.remove(id)) selection.add(id);
    _selection = selection;
  });

  void _open(Drama drama) {
    if (openDramaSearchIfMarked(context, widget.store, drama) != null) return;
    if (widget.store.following(drama.id)?.hasUpdates ?? false) {
      saveSetting(context, () => widget.store.markUpdatesRead(drama.id));
    }
    openPage<void>(
      context,
      (_) => DetailPage(store: widget.store, drama: drama),
    );
  }

  void _openTag(FavoriteTag item) {
    final site = SourceSite.byId(item.source);
    if (!site.onlineSearch || !widget.store.allowsSource(site.id)) return;
    openPage<void>(
      context,
      (_) => SearchPage(store: widget.store, source: site, query: item.tag),
    );
  }

  Future<void> _removeSelected(Set<String> ids) async {
    if (ids.isEmpty) return;
    final colors = Theme.of(context).colorScheme;
    final isTags = _tab == _FollowTab.tags;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          zh(isTags ? '取消收藏 ${ids.length} 个标签？' : '取消追剧 ${ids.length} 部？'),
        ),
        content: Text(zh(isTags ? '之后仍可随时重新收藏。' : '观看记录会保留。')),
        actions: [
          FocusRing(
            radius: 20,
            child: TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: Text(zh('取消')),
            ),
          ),
          FocusRing(
            radius: 20,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: colors.error,
                foregroundColor: colors.onError,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: Text(zh(isTags ? '取消收藏' : '取消追剧')),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await saveSetting(
      context,
      () => isTags
          ? widget.store.removeFavoriteTags(ids)
          : widget.store.removeFavorites(ids),
    );
    if (!mounted) return;
    setState(() => _selection = null);
    _keepFocus(widget.entryFocus);
  }

  static bool _matchesTag(FavoriteTag item, String rawQuery) {
    final query = rawQuery.trim().toLowerCase();
    if (query.isEmpty) return true;
    final sourceName = SourceSite.byId(item.source).name.toLowerCase();
    return item.tag.toLowerCase().contains(query) ||
        sourceName.contains(query);
  }

  static List<SourceSite> _tagSources(List<FavoriteTag> tags) {
    final seen = <String>{};
    final list = <SourceSite>[];
    for (final item in tags) {
      if (seen.add(item.source)) {
        list.add(SourceSite.byId(item.source));
      }
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final form = AppScope.formFactorOf(context);
    return PopScope(
      canPop: _selection == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finishEditing();
      },
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _rail(
                wide: form == FormFactor.pad || form == FormFactor.window,
              ),
              Expanded(
                child: _section == 0
                    ? _followBody(context)
                    : HistoryPage(
                        store: widget.store,
                        root: true,
                        embedded: true,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _railItem({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: FocusRing(
        radius: 12,
        child: Material(
          color: selected
              ? colors.primaryContainer.withValues(alpha: .55)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            key: ValueKey('library-$label'),
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: SizedBox(
              height: 44,
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: Motion.short,
                    width: 3,
                    height: 20,
                    decoration: BoxDecoration(
                      color: selected ? colors.primary : Colors.transparent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    icon,
                    size: 18,
                    color: selected
                        ? colors.primary
                        : colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      zh(label),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: selected
                            ? FontWeight.w800
                            : FontWeight.w500,
                        color: selected ? colors.primary : colors.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _rail({required bool wide}) => Padding(
    padding: EdgeInsets.fromLTRB(wide ? 12 : 8, 10, wide ? 8 : 4, 10),
    child: SizedBox(
      width: wide ? 132 : 92,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _railItem(
            icon: Icons.bookmark_border_rounded,
            label: '追剧',
            selected: _section == 0,
            onTap: () => _switch(0),
          ),
          _railItem(
            icon: Icons.history_rounded,
            label: '历史记录',
            selected: _section == 1,
            onTap: () => _switch(1),
          ),
        ],
      ),
    ),
  );

  /// 「想看 / 在看 / 已看」由观看记录派生，不额外存状态。
  bool _matches(Drama drama) {
    if (_filter.isEmpty) return true;
    final watch = widget.store.watched(drama.id);
    final total = drama.episodes;
    final done =
        watch != null &&
        watch.finished &&
        (total <= 0 || watch.episode >= total);
    return switch (_filter) {
      'want' => watch == null,
      'watching' => watch != null && !done,
      'done' => done,
      'updates' => widget.store.following(drama.id)?.hasUpdates ?? false,
      _ => true,
    };
  }

  Widget _followBody(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.store, _query]),
    builder: (context, _) {
      final follows = widget.store.favorites;
      final tags = widget.store.favoriteTags;
      final inLibrary = _tab == _FollowTab.library;
      final sources = _tab == _FollowTab.tags
          ? _tagSources(tags)
          : inLibrary
          ? const <SourceSite>[]
          : followedSources(follows);
      final source = sources.any((site) => site.id == _source) ? _source : '';
      final shown = [
        for (final drama in follows)
          if ((inLibrary
                  ? drama.source == _librarySource
                  : source.isEmpty || drama.source == source) &&
              matchesFollowTitle(drama, _query.text) &&
              _matches(drama))
            drama,
      ];
      final shownTags = [
        for (final item in tags)
          if ((source.isEmpty || item.source == source) &&
              _matchesTag(item, _query.text))
            item,
      ];
      final activeIds = _tab == _FollowTab.tags
          ? {for (final item in shownTags) item.id}
          : {for (final drama in shown) drama.id};
      final view = (
        follows: follows,
        tags: tags,
        sources: sources,
        source: source,
        shown: shown,
        shownTags: shownTags,
        selection: _selection?.intersection(activeIds),
      );
      return switch (AppScope.formFactorOf(context)) {
        FormFactor.phone => _phone(context, view),
        FormFactor.pad || FormFactor.window => _wide(context, view),
        FormFactor.television => _television(context, view),
      };
    },
  );

  Set<String> _ids(_View view) => _tab == _FollowTab.tags
      ? {for (final item in view.shownTags) item.id}
      : {for (final drama in view.shown) drama.id};

  bool _isEmptyShown(_View view) =>
      _tab == _FollowTab.tags ? view.shownTags.isEmpty : view.shown.isEmpty;

  Widget _search({FocusNode? focusNode}) => SearchField(
    hint: _tab == _FollowTab.tags ? '搜索收藏标签' : '搜索追剧',
    controller: _query,
    focusNode: focusNode,
    onSubmitted: (_) {},
    letterKeyboard: widget.store.televisionKeyboard,
    matches: (query) async => _tab == _FollowTab.tags
        ? {
            for (final item in widget.store.favoriteTags)
              if (_matchesTag(item, query)) item.tag,
          }.toList()
        : {
            for (final drama in widget.store.favorites)
              if ((_tab != _FollowTab.library ||
                      drama.source == _librarySource) &&
                  matchesFollowTitle(drama, query))
                drama.title,
          }.toList(),
  );

  Widget _textButton(
    String label,
    VoidCallback? onPressed, {
    IconData? icon,
    FocusNode? focusNode,
  }) => FocusRing(
    radius: 20,
    child: icon == null
        ? TextButton(
            focusNode: focusNode,
            onPressed: onPressed,
            child: Text(zh(label)),
          )
        : TextButton.icon(
            focusNode: focusNode,
            onPressed: onPressed,
            icon: Icon(icon, size: 18),
            label: Text(zh(label)),
          ),
  );

  Widget _editButtonFor(_View view, {bool icon = true}) => _textButton(
    '编辑',
    _isEmptyShown(view) ? null : _startEditing,
    icon: icon ? Icons.check_box_outlined : null,
    focusNode: _editButton,
  );

  /// 有站源申報 library 能力時顯示手動同步掣（站方收藏 ↔ 追劇）。
  Widget? _syncButton() {
    if (!SourceSite.values.any((site) => site.library)) return null;
    return _textButton(
      _syncing ? '同步中' : '同步收藏',
      _syncing ? null : _runSync,
      icon: Icons.sync_rounded,
    );
  }

  Future<void> _runSync() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    final repository = AppScope.of(context).repository;
    var added = 0;
    var removed = 0;
    var pushed = 0;
    var pushFailed = 0;
    var writeUnsupported = false;
    String? failure;
    try {
      for (final site in SourceSite.values.where((site) => site.library)) {
        final result = await LibrarySync(repository, widget.store).run(site.id);
        if (result.ok) {
          added += result.added;
          removed += result.removed;
          pushed += result.pushed;
          pushFailed += result.pushFailed;
          writeUnsupported = writeUnsupported || result.writeUnsupported;
        } else {
          failure ??= '${site.name}：${result.error}';
        }
        if (!mounted) return;
      }
    } catch (error) {
      failure ??= '$error';
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
    if (!mounted) return;
    final message = failure != null
        ? '同步失败：$failure'
        : '同步完成：新增 $added、移除 $removed、推送 $pushed'
              '${pushFailed > 0 ? '、推送失敗 $pushFailed（下次再試）' : ''}'
              '${writeUnsupported ? '（站源未支援寫入，本地收藏已保留）' : ''}';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(zh(message))));
  }

  Widget _selectAll(_View view) {
    final all = _ids(view);
    final everything = view.selection!.length == all.length;
    return _textButton(
      everything ? '取消全选' : '全选',
      () => setState(() => _selection = everything ? {} : all),
    );
  }

  Widget _removeButton(_View view) {
    final colors = Theme.of(context).colorScheme;
    final selection = view.selection!;
    final isTags = _tab == _FollowTab.tags;
    return FocusRing(
      radius: 20,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: colors.error,
          foregroundColor: colors.onError,
        ),
        onPressed: selection.isEmpty ? null : () => _removeSelected(selection),
        icon: Icon(
          isTags ? Icons.star_outline_rounded : Icons.bookmark_remove_outlined,
          size: 18,
        ),
        label: Text(zh(isTags ? '取消收藏' : '取消追剧')),
      ),
    );
  }

  List<Widget> _editActions(_View view) => [
    _selectAll(view),
    _removeButton(view),
    _textButton('完成', _finishEditing),
  ];

  Widget _title(String text, double size) => Semantics(
    header: true,
    child: Text(
      zh(text),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: size, fontWeight: FontWeight.w800),
    ),
  );

  Widget _tabSwitch(_View view, {required double inset}) => Padding(
    padding: EdgeInsets.fromLTRB(inset, 2, inset, 8),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        spacing: 8,
        children: [
          FocusRing(
            radius: 8,
            child: ChoiceChip(
              key: const ValueKey('follow-tab-dramas'),
              label: Text(
                view.follows.isEmpty
                    ? zh('追剧')
                    : '${zh('追剧')} ${view.follows.length}',
              ),
              showCheckmark: false,
              selected: _tab == _FollowTab.dramas,
              onSelected: (_) => _switchTab(_FollowTab.dramas),
            ),
          ),
          FocusRing(
            radius: 8,
            child: ChoiceChip(
              key: const ValueKey('follow-tab-tags'),
              label: Text(
                view.tags.isEmpty
                    ? zh('收藏标签')
                    : '${zh('收藏标签')} ${view.tags.length}',
              ),
              showCheckmark: false,
              selected: _tab == _FollowTab.tags,
              onSelected: (_) => _switchTab(_FollowTab.tags),
            ),
          ),
          for (final site in _librarySites)
            FocusRing(
              radius: 8,
              child: ChoiceChip(
                key: ValueKey('follow-tab-library-${site.id}'),
                label: Text(zh('${site.name} 收藏')),
                showCheckmark: false,
                selected:
                    _tab == _FollowTab.library && _librarySource == site.id,
                onSelected: (_) => _switchLibraryTab(site.id),
              ),
            ),
        ],
      ),
    ),
  );

  String _libraryTitle(_View view) {
    final name = SourceSite.byId(_librarySource).name;
    return _libraryKind == _LibraryKind.actresses
        ? '$name 收藏'
        : '$name 收藏 · ${view.shown.length}';
  }

  Widget _libraryKindSwitch({required double inset}) => Padding(
    padding: EdgeInsets.fromLTRB(inset, 0, inset, 8),
    child: SegmentedButton<_LibraryKind>(
      segments: [
        ButtonSegment(
          value: _LibraryKind.videos,
          icon: const Icon(Icons.movie_outlined, size: 18),
          label: Text(zh('影片')),
        ),
        ButtonSegment(
          value: _LibraryKind.actresses,
          icon: const Icon(Icons.person_outline_rounded, size: 18),
          label: Text(zh('女優')),
        ),
      ],
      selected: {_libraryKind},
      showSelectedIcon: false,
      onSelectionChanged: (selection) =>
          _switchLibraryKind(selection.first),
    ),
  );

  Widget _sourceChip(String id, String label, _View view) => FocusRing(
    radius: 8,
    child: ChoiceChip(
      key: ValueKey('follow-source-$id'),
      label: Text(zh(label)),
      showCheckmark: false,
      selected: view.source == id,
      onSelected: (_) => setState(() => _source = id),
    ),
  );

  Widget _filterChip(String id, String label) => FocusRing(
    radius: 8,
    child: ChoiceChip(
      key: ValueKey('follow-filter-$id'),
      label: Text(zh(label)),
      showCheckmark: false,
      selected: _filter == id,
      onSelected: (_) => setState(() => _filter = id),
    ),
  );

  /// 观看状态筛选：全部 / 想看 / 在看 / 已看 / 有更新（只在追剧分頁顯示）。
  Widget _filterChips({required double inset, bool scroll = false}) {
    final chips = [
      _filterChip('', '全部'),
      _filterChip('want', '想看'),
      _filterChip('watching', '在看'),
      _filterChip('done', '已看'),
      _filterChip('updates', '有更新'),
    ];
    if (scroll) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.fromLTRB(inset, 0, inset, 8),
        child: Row(spacing: 8, children: chips),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(inset, 0, inset, 8),
      child: Wrap(spacing: 8, runSpacing: 8, children: chips),
    );
  }

  Widget? _sources(_View view, {required double inset, bool scroll = false}) {
    if (view.sources.length < 2) return null;
    final chips = [
      _sourceChip('', '全部', view),
      for (final site in view.sources) _sourceChip(site.id, site.name, view),
    ];
    if (scroll) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.fromLTRB(inset, 0, inset, 8),
        child: Row(spacing: 8, children: chips),
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(inset, 0, inset, 8),
      child: Wrap(spacing: 8, runSpacing: 8, children: chips),
    );
  }

  String _selectionTitle(int count) =>
      _tab == _FollowTab.tags ? '已选择 $count 个标签' : '已选择 $count 部';

  Widget _phone(BuildContext context, _View view) {
    final selection = view.selection;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: _content(
          context,
          view,
          inset: 16,
          header: [
            FadeSwitcher(
              child: selection == null
                  ? PageHeader(
                      key: const ValueKey(false),
                      title: _tab == _FollowTab.dramas
                          ? '我的追剧 · ${view.shown.length}'
                          : _tab == _FollowTab.library
                          ? _libraryTitle(view)
                          : '追剧',
                      actions: [
                        ?_syncButton(),
                        if (!_inActresses) _editButtonFor(view, icon: false),
                      ],
                    )
                  : PageHeader(
                      key: const ValueKey(true),
                      title: _selectionTitle(selection.length),
                      actions: [
                        _selectAll(view),
                        _textButton('完成', _finishEditing),
                      ],
                    ),
            ),
            _tabSwitch(view, inset: 16),
            if (_tab == _FollowTab.library) _libraryKindSwitch(inset: 16),
            if (!_inActresses)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: _search(),
              ),
            if (_tab == _FollowTab.dramas ||
                (_tab == _FollowTab.library &&
                    _libraryKind == _LibraryKind.videos))
              _filterChips(inset: 16, scroll: true),
            ?_sources(view, inset: 16, scroll: true),
          ],
        ),
      ),
      bottomNavigationBar: selection == null
          ? null
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(height: 48, child: _removeButton(view)),
            ),
    );
  }

  Widget _wide(BuildContext context, _View view) => Scaffold(
    body: SafeArea(
      bottom: false,
      child: _content(
        context,
        view,
        inset: 24,
        header: [
          LayoutBuilder(
            builder: (context, constraints) => Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 24, 8),
              child: SizedBox(
                height: 48,
                child: FadeSwitcher(
                  child: view.selection == null
                      ? Padding(
                          key: const ValueKey(false),
                          padding: const EdgeInsets.only(left: 12),
                          child: Row(
                            spacing: 8,
                            children: [
                              Expanded(
                                child: _title(
                                  _tab == _FollowTab.dramas
                                      ? '我的追剧 · ${view.shown.length}'
                                      : _tab == _FollowTab.library
                                      ? _libraryTitle(view)
                                      : '追剧',
                                  28,
                                ),
                              ),
                              if (!_inActresses)
                                SizedBox(
                                  width: (constraints.maxWidth - 400).clamp(
                                    160.0,
                                    280.0,
                                  ),
                                  child: _search(),
                                ),
                              ?_syncButton(),
                              if (!_inActresses) _editButtonFor(view),
                            ],
                          ),
                        )
                      : Row(
                          key: const ValueKey(true),
                          spacing: 8,
                          children: [
                            IconButton(
                              tooltip: zh('退出编辑'),
                              onPressed: _finishEditing,
                              icon: const Icon(Icons.close_rounded),
                            ),
                            Expanded(
                              child: _title(
                                _selectionTitle(view.selection!.length),
                                28,
                              ),
                            ),
                            ..._editActions(view),
                          ],
                        ),
                ),
              ),
            ),
          ),
          _tabSwitch(view, inset: 24),
          if (_tab == _FollowTab.library) _libraryKindSwitch(inset: 24),
          if (_tab == _FollowTab.dramas ||
              (_tab == _FollowTab.library &&
                  _libraryKind == _LibraryKind.videos))
            _filterChips(inset: 24),
          ?_sources(view, inset: 24),
        ],
      ),
    ),
  );

  Widget _television(BuildContext context, _View view) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: (_, event) {
      if (event is KeyUpEvent ||
          event.logicalKey != LogicalKeyboardKey.arrowUp) {
        return KeyEventResult.ignored;
      }
      final moved = FocusManager.instance.primaryFocus?.focusInDirection(
        TraversalDirection.up,
      );
      if (moved != true) widget.onExitUp();
      return KeyEventResult.handled;
    },
    child: Scaffold(
      body: SafeArea(
        top: false,
        child: _content(
          context,
          view,
          inset: televisionInset,
          top: 14,
          header: [
            _tabSwitch(view, inset: televisionInset),
            if (_tab == _FollowTab.library)
              _libraryKindSwitch(inset: televisionInset),
            if (view.follows.isNotEmpty ||
                view.tags.isNotEmpty ||
                view.selection != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  televisionInset,
                  0,
                  televisionInset,
                  8,
                ),
                child: SizedBox(
                  height: 48,
                  child: FadeSwitcher(
                    child: Row(
                      key: ValueKey(view.selection == null),
                      spacing: 12,
                      children: view.selection == null
                          ? [
                              if (!_inActresses)
                                SizedBox(
                                  width: 260,
                                  child: _search(
                                    focusNode: _isEmptyShown(view)
                                        ? widget.entryFocus
                                        : null,
                                  ),
                                ),
                              const Spacer(),
                              ?_syncButton(),
                              if (!_inActresses) _editButtonFor(view),
                            ]
                          : [
                              Expanded(
                                child: _title(
                                  _selectionTitle(view.selection!.length),
                                  24,
                                ),
                              ),
                              ..._editActions(view),
                            ],
                    ),
                  ),
                ),
              ),
            if (_tab == _FollowTab.dramas ||
                (_tab == _FollowTab.library &&
                    _libraryKind == _LibraryKind.videos))
              _filterChips(inset: televisionInset),
            ?_sources(view, inset: televisionInset),
          ],
        ),
      ),
    ),
  );

  (int, double, double) _grid(BuildContext context, double width) {
    final landscape = widget.store.coverCardAspect == 'landscape';
    switch (AppScope.formFactorOf(context)) {
      case FormFactor.phone:
        return (landscape ? 2 : 3, 10, 20);
      case FormFactor.television:
        return (landscape ? 4 : 6, 20, 24);
      case FormFactor.pad || FormFactor.window:
        final desktop = AppScope.formFactorOf(context) == FormFactor.window;
        final minimum = (desktop ? 140.0 : 120.0) * (landscape ? 1.6 : 1.0);
        final gap = desktop ? 18.0 : 16.0;
        final columns = ((width + gap) / (minimum + gap)).floor().clamp(1, 99);
        return (columns, gap, desktop ? 22 : 20);
    }
  }

  Widget _tagCard(
    BuildContext context,
    FavoriteTag item,
    Set<String>? selection, {
    FocusNode? focusNode,
  }) {
    final colors = Theme.of(context).colorScheme;
    final selected = selection?.contains(item.id) ?? false;
    final sourceName = SourceSite.byId(item.source).name;
    final isActress = RegExp(
      r'^(?:女优|女優|演员|演員|actress)\s*[:：]',
      caseSensitive: false,
    ).hasMatch(item.tag);
    return FocusRing(
      radius: 14,
      child: Material(
        color: selected
            ? colors.primaryContainer
            : colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          focusNode: focusNode,
          onTap: selection == null
              ? () => _openTag(item)
              : () => _toggle(item.id),
          onLongPress: selection == null
              ? () => setState(() => _selection = {item.id})
              : null,
          onSecondaryTap: selection == null
              ? () => setState(() => _selection = {item.id})
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 10,
              children: [
                if (selection != null)
                  Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 20,
                    color: selected
                        ? colors.onPrimaryContainer
                        : colors.onSurfaceVariant,
                  )
                else
                  Icon(
                    isActress
                        ? Icons.person_rounded
                        : Icons.local_offer_rounded,
                    size: 18,
                    color: colors.primary,
                  ),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 2,
                    children: [
                      Text(
                        item.tag,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: selected
                              ? colors.onPrimaryContainer
                              : colors.onSurface,
                        ),
                      ),
                      Text(
                        sourceName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: selected
                              ? colors.onPrimaryContainer.withValues(alpha: 0.8)
                              : colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (selection == null)
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: colors.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    _View view, {
    required double inset,
    double top = 0,
    required List<Widget> header,
  }) {
    if (_inActresses) {
      return _actressContent(
        context,
        view,
        inset: inset,
        top: top,
        header: header,
      );
    }
    if (_tab == _FollowTab.tags) {
      return CustomScrollView(
        slivers: [
          SliverPadding(
            padding: EdgeInsets.only(top: top),
            sliver: SliverList.list(children: header),
          ),
          if (view.shownTags.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: FadeSwitcher(
                scale: true,
                child: StatusView(
                  key: ValueKey(('tags-empty', view.tags.isEmpty)),
                  title: view.tags.isEmpty ? '还没有收藏标签' : '没有匹配的收藏标签',
                  message: view.tags.isEmpty
                      ? '在详情页长按或右键点击标签，或在搜索结果页点右上角星标即可收藏。'
                      : null,
                  icon: view.tags.isEmpty
                      ? Icons.star_border_rounded
                      : Icons.search_off_rounded,
                ),
              ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                inset,
                12,
                inset,
                AppScope.of(context).television ? 27 : 32,
              ),
              sliver: SliverToBoxAdapter(
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final (index, item) in view.shownTags.indexed)
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                          minWidth: 150,
                          maxWidth: 320,
                        ),
                        child: _tagCard(
                          context,
                          item,
                          view.selection,
                          focusNode: index == 0 ? widget.entryFocus : null,
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - inset * 2;
        final (columns, gap, runGap) = _grid(context, width);
        final tile = (width - gap * (columns - 1)) / columns;
        final updated = [
          for (final drama in view.shown)
            if (widget.store.following(drama.id)?.hasUpdates ?? false) drama,
        ];
        final rest = [
          for (final drama in view.shown)
            if (!updated.contains(drama)) drama,
        ];
        final sections = <(String?, List<Drama>)>[
          if (updated.isNotEmpty) ('有更新', updated),
          if (rest.isNotEmpty) (updated.isEmpty ? null : '其他追剧', rest),
        ];
        final first = view.shown.isEmpty
            ? null
            : (updated.firstOrNull ?? rest.first);
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.only(top: top),
              sliver: SliverList.list(children: header),
            ),
            if (view.shown.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: FadeSwitcher(
                  scale: true,
                  child: StatusView(
                    key: ValueKey(
                      (view.follows.isEmpty, _tab == _FollowTab.library),
                    ),
                    title: _tab == _FollowTab.library
                        ? '还没有同步的收藏'
                        : view.follows.isEmpty
                        ? '还没有追剧'
                        : '没有匹配的追剧',
                    message: _tab == _FollowTab.library
                        ? '点上方「同步收藏」把站源收藏同步到追剧，或先到「我的 › 模組」登入该站源。'
                        : view.follows.isEmpty
                        ? missingSourceHint(
                            widget.store.missingSourceRecords().follows,
                            '部追剧',
                          )
                        : null,
                    icon: _tab == _FollowTab.library || view.follows.isEmpty
                        ? Icons.bookmark_border_rounded
                        : Icons.search_off_rounded,
                  ),
                ),
              )
            else ...[
              for (final (label, dramas) in sections) ...[
                if (label != null)
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(inset + 4, 12, inset, 10),
                    sliver: SliverToBoxAdapter(
                      child: Semantics(
                        header: true,
                        child: Text.rich(
                          TextSpan(
                            text: zh(label),
                            children: [
                              TextSpan(
                                text: '  ${dramas.length}',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    inset,
                    label == null ? 12 : 0,
                    inset,
                    0,
                  ),
                  sliver: SliverGrid.builder(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: gap,
                      mainAxisSpacing: runGap,
                      mainAxisExtent: ProgressPoster.extentFor(
                        context,
                        tile,
                        coverAspect: widget.store.coverCardAspect,
                      ),
                    ),
                    itemCount: dramas.length,
                    itemBuilder: (context, index) {
                      final drama = dramas[index];
                      return Focus(
                        key: ValueKey(drama.id),
                        canRequestFocus: false,
                        skipTraversal: true,
                        onKeyEvent: (_, event) =>
                            wrapGridRow(index, columns, dramas.length, event),
                        child: EnterOnce(
                          id: drama.id,
                          played: _entered,
                          index: index,
                          child: _poster(
                            context,
                            drama,
                            tile,
                            view.selection,
                            focusNode:
                                drama == first ? widget.entryFocus : null,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
              SliverPadding(
                padding: EdgeInsets.only(
                  bottom: AppScope.of(context).television ? 27 : 32,
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _actressContent(
    BuildContext context,
    _View view, {
    required double inset,
    double top = 0,
    required List<Widget> header,
  }) {
    final source = _librarySource;
    final items = _actressCache[source];
    final error = _actressErrors[source];
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - inset * 2;
        const gap = 12.0;
        final columns = ((width + gap) / (104 + gap)).floor().clamp(3, 10);
        final tile = (width - gap * (columns - 1)) / columns;
        final scaler = MediaQuery.textScalerOf(context);
        final extent =
            (tile +
                    8 +
                    scaler.scale(14) * 1.3 +
                    2 +
                    scaler.scale(12) * 1.3)
                .ceilToDouble();
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.only(top: top),
              sliver: SliverList.list(children: header),
            ),
            if (items == null && error == null)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: StatusView.loading(title: '正在加载女優列表'),
              )
            else if (error != null)
              SliverFillRemaining(
                hasScrollBody: false,
                child: StatusView(
                  title: '女優列表載入失敗',
                  message: error,
                  icon: Icons.cloud_off_rounded,
                  action: '重試',
                  onAction: () => _retryActresses(source),
                ),
              )
            else if (items!.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: StatusView(
                  title: '還沒有收藏的女優',
                  message: '在站源網站收藏女優後，回到這裡即可看到。',
                  icon: Icons.person_outline_rounded,
                ),
              )
            else ...[
              SliverPadding(
                padding: EdgeInsets.fromLTRB(inset, 12, inset, 0),
                sliver: SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    crossAxisSpacing: gap,
                    mainAxisSpacing: 16,
                    mainAxisExtent: extent,
                  ),
                  itemCount: items!.length,
                  itemBuilder: (context, index) => _actressCell(
                    context,
                    items[index],
                    tile,
                    focusNode: index == 0 ? widget.entryFocus : null,
                  ),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.only(
                  bottom: AppScope.of(context).television ? 27 : 32,
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _actressCell(
    BuildContext context,
    Drama drama,
    double width, {
    FocusNode? focusNode,
  }) {
    final colors = Theme.of(context).colorScheme;
    final remark = drama.remark.isNotEmpty
        ? drama.remark
        : drama.badge.isNotEmpty
        ? drama.badge
        : drama.description;
    return FocusRing(
      radius: 12,
      child: InkWell(
        focusNode: focusNode,
        borderRadius: BorderRadius.circular(12),
        onTap: () => _open(drama),
        child: Column(
          children: [
            ClipOval(
              child: SizedBox(
                width: width,
                height: width,
                child: DramaCover(
                  drama: drama,
                  radius: width / 2,
                  details: false,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              drama.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              zh(remark),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.3,
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _poster(
    BuildContext context,
    Drama drama,
    double width,
    Set<String>? selection, {
    FocusNode? focusNode,
  }) {
    final watch = widget.store.watched(drama.id);
    final state = widget.store.following(drama.id);
    final total = drama.episodes;
    final String caption;
    if (watch == null) {
      caption = total > 0 ? zh('未观看 · 共 $total 集') : zh('未观看');
    } else if (total > 0 && watch.episode >= total && watch.finished) {
      caption = zh('已看完');
    } else {
      final long = zh('看到第 ${watch.episode} 集 / 共 $total 集');
      caption = total > 0 && _fits(context, long, width)
          ? long
          : zh('看到第 ${watch.episode} 集');
    }
    return ProgressPoster(
      drama: drama,
      width: width,
      coverAspect: widget.store.coverCardAspect,
      focusNode: focusNode,
      progress: watch != null && total > 0 ? watch.episode / total : 0,
      caption: caption,
      tag: SourceSite.byId(drama.source).name,
      badge: state != null && state.hasUpdates
          ? zh('${state.newEpisodes} 集更新')
          : null,
      selected: selection?.contains(drama.id),
      onTap: selection == null ? () => _open(drama) : () => _toggle(drama.id),
      onMore: selection == null
          ? () => setState(() => _selection = {drama.id})
          : null,
    );
  }

  bool _fits(BuildContext context, String text, double width) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: DefaultTextStyle.of(context).style.copyWith(
          fontSize: AppScope.of(context).television ? 13 : 12,
          height: 1.3,
        ),
      ),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final fits = painter.width <= width - 4;
    painter.dispose();
    return fits;
  }
}
