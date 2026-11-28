import 'package:flutter/material.dart';

import '../../core_bridge.dart';
import '../../library_login.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../zh_script.dart';
import '../app_scope.dart';
import '../theme/motion.dart';
import 'focus_ring.dart';
import 'motion/motion_widgets.dart';

Future<void> _toggle(BuildContext context, LocalStore store, Drama drama) =>
    store.toggleFavorite(drama).catchError((Object failure) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$failure')));
      }
    });

Future<void> quickFollow(
  BuildContext context,
  LocalStore store,
  Drama drama,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final followed = store.isFavorite(drama.id);
  try {
    await store.toggleFavorite(drama);
  } catch (failure) {
    messenger.showSnackBar(SnackBar(content: Text('$failure')));
    return;
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        persist: false,
        content: Text(
          zh(followed ? '已取消追剧「${drama.title}」' : '已追剧「${drama.title}」'),
        ),
        action: SnackBarAction(
          label: zh('撤销'),
          onPressed: () => store
              .toggleFavorite(drama)
              .catchError(
                (Object failure) =>
                    messenger.showSnackBar(SnackBar(content: Text('$failure'))),
              ),
        ),
      ),
    );
}

class FollowPill extends StatelessWidget {
  const FollowPill({
    super.key,
    required this.store,
    required this.drama,
    this.height = 40,
    this.radius,
    this.onToggled,
    this.focusNode,
  });
  final LocalStore store;
  final Drama drama;
  final double height;
  final double? radius;
  final VoidCallback? onToggled;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final followed = store.isFavorite(drama.id);
      final corner = radius ?? height / 2;
      return FocusRing(
        radius: corner,
        child: FilledButton.tonalIcon(
          key: const ValueKey('follow-toggle'),
          focusNode: focusNode,
          onPressed: () {
            _toggle(context, store, drama);
            onToggled?.call();
          },
          style: FilledButton.styleFrom(
            minimumSize: Size(0, height),
            padding: EdgeInsets.fromLTRB(height / 4, 0, height * 0.35, 0),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(corner),
            ),
            iconSize: height * 0.45,
            textStyle: TextStyle(
              fontSize: height >= 44 ? 15 : 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          icon: ToggleIconSwitcher(
            child: Icon(
              followed ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
              key: ValueKey(followed),
            ),
          ),
          label: Stack(
            alignment: Alignment.center,
            children: [
              Visibility(
                visible: false,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: Text(zh('已追剧')),
              ),
              FadeSwitcher(
                duration: Motion.short,
                child: Text(zh(followed ? '已追剧' : '追剧'), key: ValueKey(followed)),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// 詳情頁「收藏」掣：同追劇（純本地）分開，撳咗先即時 write-through
/// 同步去站方帳號（libraryWrite）。只喺來源有 library 能力且已登入
/// （sourceAccount status，經 LibraryLogin cache）先出現；狀態跟
/// LocalStore 的 site list（帳號收藏清單），寫入成功先更新。
class LibrarySavePill extends StatefulWidget {
  const LibrarySavePill({
    super.key,
    required this.store,
    required this.drama,
    this.height = 40,
    this.radius,
  });
  final LocalStore store;
  final Drama drama;
  final double height;
  final double? radius;

  @override
  State<LibrarySavePill> createState() => _LibrarySavePillState();
}

class _LibrarySavePillState extends State<LibrarySavePill> {
  var _busy = false;

  Future<void> _toggle() async {
    if (_busy) return;
    final store = widget.store;
    final drama = widget.drama;
    final saved = store.inLibrarySite(drama.source, drama.id);
    final repository = AppScope.of(context).repository;
    setState(() => _busy = true);
    try {
      await repository.libraryWrite(drama.source, drama, add: !saved);
      await store.setLibrarySiteItem(
        drama.source,
        drama,
        present: !saved,
        epoch: store.profileEpoch,
      );
    } catch (failure) {
      if (failure is AppFailure && failure.code == 'source_login') {
        LibraryLogin.invalidate(drama.source);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(zh('收藏同步失敗：$failure'))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final drama = widget.drama;
    final site = SourceSite.byId(drama.source);
    // 協議約定：收藏掣只對申報了 favorites kind（同步/寫入 kind）
    // 的 library 來源出現。
    if (!site.library || !site.hasFavoritesKind) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<bool>(
      future: LibraryLogin.loggedIn(
        AppScope.of(context).repository,
        drama.source,
      ),
      builder: (context, snapshot) {
        if (snapshot.data != true) return const SizedBox.shrink();
        return ListenableBuilder(
          listenable: widget.store,
          builder: (context, _) {
            final saved = widget.store.inLibrarySite(drama.source, drama.id);
            final height = widget.height;
            final corner = widget.radius ?? height / 2;
            return FocusRing(
              radius: corner,
              child: FilledButton.tonalIcon(
                key: const ValueKey('library-save-toggle'),
                onPressed: _busy ? null : _toggle,
                style: FilledButton.styleFrom(
                  minimumSize: Size(0, height),
                  padding: EdgeInsets.fromLTRB(
                    height / 4,
                    0,
                    height * 0.35,
                    0,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(corner),
                  ),
                  iconSize: height * 0.45,
                  textStyle: TextStyle(
                    fontSize: height >= 44 ? 15 : 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                icon: ToggleIconSwitcher(
                  child: Icon(
                    saved
                        ? Icons.star_rounded
                        : Icons.star_border_rounded,
                    key: ValueKey(saved),
                  ),
                ),
                label: Stack(
                  alignment: Alignment.center,
                  children: [
                    Visibility(
                      visible: false,
                      maintainSize: true,
                      maintainAnimation: true,
                      maintainState: true,
                      child: Text(zh('已收藏')),
                    ),
                    FadeSwitcher(
                      duration: Motion.short,
                      child: Text(
                        zh(saved ? '已收藏' : '收藏'),
                        key: ValueKey(saved),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class FollowIcon extends StatelessWidget {
  const FollowIcon({
    super.key,
    required this.store,
    required this.drama,
    required this.color,
    required this.activeColor,
    this.size = 24,
    this.extent = 48,
  });
  final LocalStore store;
  final Drama drama;
  final Color color;
  final Color activeColor;
  final double size;
  final double extent;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final followed = store.isFavorite(drama.id);
      return Semantics(
        label: zh(followed ? '已追剧，轻点取消' : '追剧'),
        button: true,
        excludeSemantics: true,
        child: IconButton(
          key: const ValueKey('follow-toggle'),
          onPressed: () => _toggle(context, store, drama),
          style: IconButton.styleFrom(fixedSize: Size.square(extent)),
          icon: ToggleIconSwitcher(
            child: Icon(
              followed ? Icons.bookmark_rounded : Icons.bookmark_add_outlined,
              key: ValueKey(followed),
              size: size,
              color: followed ? activeColor : color,
            ),
          ),
        ),
      );
    },
  );
}
