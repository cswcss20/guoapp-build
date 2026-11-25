package core

import (
	"context"
	"strings"
	"sync"
	"time"
)

// searchAllTimeout bounds each provider's share of a cross-source search.
// Providers run in parallel — every jsProvider owns a separate goja
// instance pool, so different providers never share a runtime — and a
// source that fails or runs over is skipped and reported instead of
// failing the whole search.
const searchAllTimeout = 12 * time.Second

type nativeSearchGroup struct {
	Source  string        `json:"source"`
	Name    string        `json:"name"`
	Items   []LibraryDrama `json:"items"`
	HasMore bool          `json:"hasMore"`
}

type nativeSearchAllResult struct {
	Groups  []nativeSearchGroup `json:"groups"`
	Failed  []string            `json:"failed"`
	Page    int                 `json:"page"`
	HasMore bool                `json:"hasMore"`
}

type searchAllOutcome struct {
	group  nativeSearchGroup
	failed bool
}

// nativeSearchAll runs one query against every registered provider that
// can search and merges the answers into per-source groups. The page
// number applies to each source individually (page 2 is every source's
// second page); HasMore is set when any source has more.
func (engine *nativeEngine) nativeSearchAll(ctx context.Context, input nativeInput) (nativeSearchAllResult, error) {
	page := max(1, input.Page)
	result := nativeSearchAllResult{
		Groups: []nativeSearchGroup{},
		Failed: []string{},
		Page:   page,
	}
	query := strings.TrimSpace(input.Query)
	if query == "" {
		return result, nil
	}
	type target struct {
		descriptor SourceDescriptor
		search     func(ctx context.Context) ([]Drama, bool, error)
	}
	targets := []target{}
	for _, descriptor := range registeredDescriptors() {
		provider, ok := engine.downloader.provider(descriptor.ID)
		if !ok {
			continue
		}
		// Same interface resolution as the single-source search path in
		// nativeCatalog: warning-carrying searchers first, then plain
		// searchers. Cross-source search carries no filter picks, so the
		// filtered variants (which degrade to the plain ones without
		// picks) are not needed here.
		if searcher, ok := providerAs[WarningSearcher](provider); ok {
			targets = append(targets, target{descriptor, func(ctx context.Context) ([]Drama, bool, error) {
				items, more, _, err := searcher.SearchWithWarning(ctx, page, query)
				return items, more, err
			}})
		} else if searcher, ok := providerAs[Searcher](provider); ok {
			targets = append(targets, target{descriptor, func(ctx context.Context) ([]Drama, bool, error) {
				return searcher.Search(ctx, page, query)
			}})
		}
	}
	outcomes := make([]searchAllOutcome, len(targets))
	var wait sync.WaitGroup
	for index, target := range targets {
		wait.Add(1)
		go func(index int, target target) {
			defer wait.Done()
			sourceCtx, cancel := context.WithTimeout(ctx, searchAllTimeout)
			defer cancel()
			items, more, err := target.search(sourceCtx)
			if err != nil {
				outcomes[index].failed = true
				return
			}
			group := nativeSearchGroup{
				Source:  target.descriptor.ID,
				Name:    target.descriptor.Name,
				Items:   []LibraryDrama{},
				HasMore: more,
			}
			seen := map[string]bool{}
			for _, drama := range items {
				if drama.ID == "" || seen[drama.ID] {
					continue
				}
				seen[drama.ID] = true
				group.Items = append(group.Items, NativeNormalize(drama))
			}
			outcomes[index].group = group
		}(index, target)
	}
	wait.Wait()
	for index, outcome := range outcomes {
		if outcome.failed {
			result.Failed = append(result.Failed, targets[index].descriptor.ID)
			continue
		}
		if len(outcome.group.Items) == 0 {
			continue
		}
		result.Groups = append(result.Groups, outcome.group)
		result.HasMore = result.HasMore || outcome.group.HasMore
	}
	return result, nil
}
