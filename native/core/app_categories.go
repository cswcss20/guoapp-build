package core

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"sort"
	"strings"
)

type Category struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

func nativeCatalogKey(source, category string) string {
	source = canonicalProviderSource(source)
	if category = strings.TrimSpace(category); category != "" {
		return source + "|" + category
	}
	return source
}

// nativeFilters returns the filter groups a module declares for one
// catalog category. Modules without a filters export (or with a failing
// one) yield an empty list, never an error, so the catalog UI can simply
// omit the filter bar.
func (engine *nativeEngine) nativeFilters(ctx context.Context, input nativeInput) ([]FilterGroup, error) {
	source := canonicalProviderSource(input.Source)
	if !registeredProviderSource(source) {
		return nil, errors.New("请选择有效站源")
	}
	category := strings.TrimSpace(input.Category)
	if !ValidNativeCategory(source, category) {
		return nil, errors.New("内容分类无效")
	}
	provider, ok := engine.downloader.provider(source)
	if !ok {
		return nil, errors.New("请选择有效站源")
	}
	filtered, ok := provider.(FilterProvider)
	if !ok {
		return []FilterGroup{}, nil
	}
	groups, err := filtered.Filters(ctx, category)
	if err != nil || len(groups) == 0 {
		return []FilterGroup{}, nil
	}
	cleaned := make([]FilterGroup, 0, len(groups))
	for _, group := range groups {
		group.ID = strings.TrimSpace(group.ID)
		group.Name = strings.TrimSpace(group.Name)
		if group.ID == "" || group.Name == "" || len(group.Options) == 0 {
			continue
		}
		options := make([]FilterOption, 0, len(group.Options))
		for _, option := range group.Options {
			option.ID = strings.TrimSpace(option.ID)
			option.Name = strings.TrimSpace(option.Name)
			if option.Name == "" {
				continue
			}
			options = append(options, option)
		}
		if len(options) < 2 {
			continue
		}
		group.Options = options
		cleaned = append(cleaned, group)
		if len(cleaned) >= 12 {
			break
		}
	}
	return cleaned, nil
}

// nativeCleanFilters drops empty group ids and empty picks (an empty pick
// means "全部/預設" and is never sent to the module).
func nativeCleanFilters(raw map[string]string) map[string]string {
	if len(raw) == 0 {
		return nil
	}
	cleaned := make(map[string]string, len(raw))
	for id, value := range raw {
		id = strings.TrimSpace(id)
		value = strings.TrimSpace(value)
		if id == "" || value == "" {
			continue
		}
		cleaned[id] = value
	}
	if len(cleaned) == 0 {
		return nil
	}
	return cleaned
}

// nativeFilterKeySuffix keeps filtered catalog pages in their own cache
// bucket so they never mix with the unfiltered listing of a category.
func nativeFilterKeySuffix(filters map[string]string) string {
	keys := make([]string, 0, len(filters))
	for id := range filters {
		keys = append(keys, id)
	}
	sort.Strings(keys)
	var builder strings.Builder
	for _, id := range keys {
		builder.WriteString(id)
		builder.WriteByte('=')
		builder.WriteString(filters[id])
		builder.WriteByte('&')
	}
	sum := sha256.Sum256([]byte(builder.String()))
	return hex.EncodeToString(sum[:8])
}

func ValidNativeCategory(source, category string) bool {
	if category == "" {
		return true
	}
	if len(category) > 128 || strings.ContainsAny(category, "|/\\\x00\r\n") {
		return false
	}
	if descriptor, ok := registeredDescriptor(source); ok {
		return descriptor.ValidCategory != nil && descriptor.ValidCategory(category)
	}
	return false
}

func (engine *nativeEngine) nativeCategories(ctx context.Context, source string, force bool) ([]Category, error) {
	source = canonicalProviderSource(source)
	all := []Category{{Name: "全部"}}
	p, ok := engine.downloader.provider(source)
	if !ok {
		return nil, errors.New("请选择有效站源")
	}
	version := providerModuleVersion(p)
	engine.mu.Lock()
	cached := append([]Category{}, engine.categoryOptions[source]...)
	current := engine.categoryVersions[source] == version
	engine.mu.Unlock()
	if len(cached) > 1 && current && !force {
		return cached, nil
	}
	categories, err := p.Categories(ctx, force)
	all = append(all, categories...)
	if errors.Is(err, ErrCategoriesIncomplete) {
		return all, nil
	}
	if err != nil {
		return nil, err
	}
	if len(all) == 1 {
		return nil, errors.New("站源暂未返回内容分类，请稍后重试")
	}
	engine.rememberCategories(source, version, all)
	return all, nil
}

func (engine *nativeEngine) rememberCategories(source, version string, all []Category) {
	engine.mu.Lock()
	defer engine.mu.Unlock()
	if engine.categoryOptions == nil {
		engine.categoryOptions = map[string][]Category{}
	}
	if engine.categoryVersions == nil {
		engine.categoryVersions = map[string]string{}
	}
	engine.categoryOptions[source] = all
	engine.categoryVersions[source] = version
	engine.writeCatalogDiskLocked()
}

func providerModuleVersion(p Provider) string {
	if module, ok := p.(*jsProvider); ok {
		return module.module.manifest.Version
	}
	return ""
}
