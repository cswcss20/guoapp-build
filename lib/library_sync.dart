import 'core_bridge.dart';
import 'local_store.dart';
import 'models.dart';

class LibrarySyncResult {
  const LibrarySyncResult({
    this.added = 0,
    this.removed = 0,
    this.pushed = 0,
    this.pushFailed = 0,
    this.writeUnsupported = false,
    this.error = '',
  });

  /// 網站→app 新增數。
  final int added;

  /// 網站→app 刪除數（站方已取消收藏、本地跟住移除）。
  final int removed;

  /// app→網站 成功推送數（新增＋移除）。
  final int pushed;

  /// app→網站 推送失敗數（本地狀態保留，下次同步再試）。
  final int pushFailed;

  /// 模組未實作寫入（寫入接口未支援）：本地收藏照常保留。
  final bool writeUnsupported;

  /// 拉取失敗等整體錯誤；非空表示今次同步無做任何變更。
  final String error;

  bool get ok => error.isEmpty;
}

/// 雙向收藏同步引擎：拉齊站方收藏清單後與本地追劇做 diff。
///
/// - 網站→app：新增合併入追劇；刪除只在成功拉齊完整清單時執行，
///   拉取失敗一律不刪。
/// - app→網站：本地新增/移除經模組 libraryWrite 推送；失敗或模組
///   未實作寫入時保留本地狀態、下次再試，絕不丟失本地收藏。
///
/// 以 LocalStore 的已同步 id 集合分辨「本地新加」（本地有、站方冇、
/// 未同步過 → 推送新增）同「網站已刪」（已同步、本地仲有、站方
/// 已冇 → 本地移除）。
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
      // 1. 拉齊站方清單（逐頁；任一頁失敗或拉唔齊即放棄，本地不變）。
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
      final siteIds = {for (final drama in siteItems) drama.id};
      final local = store.favoritesOfSource(source);
      final localIds = {for (final drama in local) drama.id};
      final synced = store.librarySyncedIds(source);

      // 2. 網站→app：新增（站方有、本地冇、未同步過）＋已存在項目
      //    的元數據更新；刪除（已同步、本地仲有、站方已冇）。
      final addOrUpdate = [
        for (final drama in siteItems)
          if (localIds.contains(drama.id) || !synced.contains(drama.id))
            drama,
      ];
      final removeIds = synced.intersection(localIds).difference(siteIds);

      // 3. app→網站：本地新增推送 add；本地已移除但站方仲有推送
      //    remove。推送失敗只記錄，本地狀態不變。
      var pushed = 0;
      var pushFailed = 0;
      var writeUnsupported = false;
      final pushedAddIds = <String>{};
      final failedRemoveIds = <String>{};
      Future<void> push(Drama drama, bool add) async {
        if (writeUnsupported) {
          pushFailed++;
          if (!add) failedRemoveIds.add(drama.id);
          return;
        }
        try {
          await repository.libraryWrite(source, drama, kind: kind, add: add);
          pushed++;
          if (add) pushedAddIds.add(drama.id);
        } on AppFailure catch (error) {
          pushFailed++;
          if (!add) failedRemoveIds.add(drama.id);
          if (error.code == 'library_write_unsupported') {
            writeUnsupported = true;
          }
        } catch (_) {
          pushFailed++;
          if (!add) failedRemoveIds.add(drama.id);
        }
      }

      for (final drama in local) {
        if (!siteIds.contains(drama.id) && !synced.contains(drama.id)) {
          await push(drama, true);
          if (store.profileEpoch != epoch) {
            return const LibrarySyncResult(error: '用戶已切換，同步取消');
          }
        }
      }
      final siteById = {for (final drama in siteItems) drama.id: drama};
      for (final id in synced.difference(localIds).intersection(siteIds)) {
        await push(siteById[id]!, false);
        if (store.profileEpoch != epoch) {
          return const LibrarySyncResult(error: '用戶已切換，同步取消');
        }
      }

      // 4. 合併入本地收藏。
      await store.applyLibraryMerge(
        source,
        addOrUpdate: addOrUpdate,
        removeIds: removeIds,
        epoch: epoch,
      );
      if (store.profileEpoch != epoch) {
        return const LibrarySyncResult(error: '用戶已切換，同步取消');
      }

      // 5. 更新已同步集合：兩邊都有嘅＋成功推送新增嘅＋推送移除
      //    失敗嘅（保留待下次再試，唔會被誤當站方新增加返本地）。
      final resulting = {
        for (final drama in store.favoritesOfSource(source)) drama.id,
      };
      final nextSynced = siteIds.intersection(resulting)
        ..addAll(pushedAddIds)
        ..addAll(failedRemoveIds);
      await store.saveLibrarySynced(source, nextSynced, epoch: epoch);

      return LibrarySyncResult(
        added: resulting.difference(localIds).length,
        removed: removeIds.length,
        pushed: pushed,
        pushFailed: pushFailed,
        writeUnsupported: writeUnsupported,
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
