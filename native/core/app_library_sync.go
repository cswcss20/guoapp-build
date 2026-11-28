package core

import (
	"context"
	"errors"
	"strings"
)

// libraryItems 回傳模組站方個人收藏列表的一頁，供前端同步引擎逐頁
// 拉齊後與本地追劇做 diff 合併。kind 預設 "favorites"。
func (engine *nativeEngine) libraryItems(ctx context.Context, input nativeInput) (any, error) {
	source := canonicalProviderSource(input.Source)
	p, ok := engine.downloader.provider(source)
	if !ok {
		return nil, errNativeBuildSource
	}
	library, ok := providerAs[LibraryProvider](p)
	if !ok {
		return nil, errNativeBuildSource
	}
	kind := strings.TrimSpace(input.Kind)
	if kind == "" {
		kind = "favorites"
	}
	page := max(1, input.Page)
	items, hasMore, err := library.LibraryItems(ctx, kind, page)
	if err != nil {
		return nil, err
	}
	normalized := make([]LibraryDrama, 0, len(items))
	seen := map[string]bool{}
	for _, drama := range items {
		if drama.ID == "" || seen[drama.ID] {
			continue
		}
		seen[drama.ID] = true
		normalized = append(normalized, NativeNormalize(drama))
	}
	return map[string]any{"items": normalized, "hasMore": hasMore, "page": page}, nil
}

// libraryWrite 將本地收藏的新增/移除推送回站方。command "add" 為
// 新增，其餘（"remove"）為移除。模組未實作寫入時錯誤會帶
// ErrLibraryWriteUnsupported，前端保留本地狀態下次再試。
func (engine *nativeEngine) libraryWrite(ctx context.Context, input nativeInput) (any, error) {
	source, _, valid := SplitProviderDramaID(input.Drama.ID)
	if !valid {
		return nil, errors.New("剧集信息无效")
	}
	p, ok := engine.downloader.provider(source)
	if !ok {
		return nil, errNativeBuildSource
	}
	library, ok := providerAs[LibraryProvider](p)
	if !ok {
		return nil, errNativeBuildSource
	}
	kind := strings.TrimSpace(input.Kind)
	if kind == "" {
		kind = "favorites"
	}
	if err := library.LibraryWrite(ctx, kind, input.Drama, input.Command == "add"); err != nil {
		return nil, err
	}
	return map[string]any{"ok": true}, nil
}
