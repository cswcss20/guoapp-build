import 'core_bridge.dart';

/// 站源帳號登入狀態查詢（sourceAccount status，command 為空字串，
/// 回 {loggedIn}）。結果以 Future 形式按站源 cache 住，避免詳情頁
/// 「收藏」掣同追劇頁空清單提示重複查詢；查唔到（模組未支援
/// account、未登入、核心未就緒）一律當未登入。
///
/// 瀏覽器登入保存/清除 Cookie 後（browser_auth_view）會呼叫
/// [invalidate] 清走該站源的 cache，下次查詢重新攞。
class LibraryLogin {
  static final _cache = <String, Future<bool>>{};

  static Future<bool> loggedIn(AppRepository repository, String source) =>
      _cache.putIfAbsent(source, () async {
        try {
          final result = await repository.sourceAccount(source, '', const {});
          return result['loggedIn'] == true;
        } catch (_) {
          return false;
        }
      });

  static void invalidate(String source) => _cache.remove(source);
}
