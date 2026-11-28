import 'package:flutter/widgets.dart';

import '../../local_store.dart';
import '../../models.dart';
import '../search/search_page.dart';
import '../shell/app_shell.dart';

/// 模組申報 openAsSearch 的目錄項目（例如女優列表）：撳入時改開
/// 搜尋頁（標題為搜尋詞），不入詳情頁。成功分流回傳搜尋頁的
/// Future（頁面關閉時完成）；項目未帶標記、站源不支援搜尋或
/// 站源被停用時回傳 null，呼叫方照舊開詳情頁。
Future<void>? openDramaSearchIfMarked(
  BuildContext context,
  LocalStore store,
  Drama drama,
) {
  if (!drama.openAsSearch) return null;
  final site = SourceSite.byId(drama.source);
  if (!site.onlineSearch || !store.allowsSource(site.id)) return null;
  return openPage<void>(
    context,
    (_) => SearchPage(store: store, source: site, query: drama.title),
  );
}
