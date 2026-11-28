import 'core_bridge.dart';
import 'local_store.dart';
import 'models.dart';

class LibrarySyncResult {
  const LibrarySyncResult({
    this.added = 0,
    this.removed = 0,
    this.error = '',
  });

  /// 今次拉取同舊 site list 比較的新增數（站方新收藏）。
  final int added;

  /// 今次拉取同舊 site list 比較的移除數（站方已取消收藏）。
  final int removed;

  /// 拉取失敗等整體錯誤；非空表示今次同步無做任何變更（舊
  /// site list 原封保留）。
  final String error;

  bool get ok => error.isEmpty;
}

/// 站方帳號收藏拉取同步（pull-only）：拉齊站方收藏清單後成份
/// 存入 LocalStore 的 per-source site list（librarySite.json），
/// 供追劇頁「{來源} 收藏」tab 顯示。與本地追劇完全分開：
/// 追劇永遠唔推送去帳號；app→網站寫入只經詳情頁「收藏」掣
/// 即時 write-through（libraryWrite），不在此引擎處理。
///
/// 完整拉齊先替換；任一頁失敗或拉唔齊即放棄，舊清單不變。
class LibrarySync {
  LibrarySync(this.repository, this.store);

  final AppRepository repository;
  final LocalStore store;

  static bool _running = false;

  Future<LibrarySyncResult> run(
    String source, {
    String kind = 'favorites',
  }) async {
    if (_running) return const LibrarySyncResult(error: '同步進行中');
    final site = SourceSite.byId(source);
    if (!site.library || !store.allowsSource(source) || store.locked) {
      return const LibrarySyncResult(error: '站源未支援收藏同步');
    }
    _running = true;
    final epoch = store.profileEpoch;
    try {
      // 拉齊站方清單（逐頁；任一頁失敗或拉唔齊即放棄，舊清單不變）。
      final siteItems = <Drama>[];
      final seen = <String>{};
      var page = 1;
      var complete = false;
      while (true) {
        final result = await repository.libraryItems(
          source,
          kind: kind,
          page: page,
        );
        if (store.profileEpoch != epoch) {
          return const LibrarySyncResult(error: '用戶已切換，同步取消');
        }
        for (final drama in result.items) {
          if (drama.id.isNotEmpty && seen.add(drama.id)) siteItems.add(drama);
        }
        if (!result.hasMore) {
          complete = true;
          break;
        }
        if (page >= 200) break;
        page++;
      }
      if (!complete) {
        return const LibrarySyncResult(error: '站方收藏未能拉齊，同步取消');
      }
      final previousIds = {
        for (final drama in store.librarySiteItems(source)) drama.id,
      };
      final siteIds = {for (final drama in siteItems) drama.id};
      await store.saveLibrarySite(source, siteItems, epoch: epoch);
      if (store.profileEpoch != epoch) {
        return const LibrarySyncResult(error: '用戶已切換，同步取消');
      }
      return LibrarySyncResult(
        added: siteIds.difference(previousIds).length,
        removed: previousIds.difference(siteIds).length,
      );
    } on AppFailure catch (error) {
      return LibrarySyncResult(error: error.message);
    } catch (error) {
      return LibrarySyncResult(error: '$error');
    } finally {
      _running = false;
    }
  }
}
