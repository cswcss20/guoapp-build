package core

// HLS 分片平行预取。
//
// 播放器快转后要等目标分片下载完才恢复播放，单连接逐片下载在
// 逐连接限速的 CDN 上明显偏慢。这里在代理层加一层预取：每次分片
// 被请求后，并行预取后续几个分片进内存缓存，播放器随后请求时
// 直接命中。若 CDN 是按 IP 限速则无收益，但也不会更慢：预取的
// 任何失败都静默放弃，播放器请求时走原有直连路径。
//
// 范围：只预取 HLS 媒体清单的分片（kind == "segment"）。master
// 清单、密钥、EXT-X-MAP、渐进式 MP4 都不预取，行为与之前一致。
// AES-128 分片只缓存原始字节，解密仍由播放器完成。

import (
	"context"
	"io"
	"net/http"
	"slices"
	"strings"
	"time"
)

const (
	// nativePrefetchDepth 每次分片请求后向前预取的分片个数。
	nativePrefetchDepth = 3
	// nativePrefetchWorkers 单会话并发预取上限。
	nativePrefetchWorkers = 3
	// nativePrefetchCacheBytes 单会话预取缓存上限，超限淘汰最旧分片。
	nativePrefetchCacheBytes = 64 << 20
	// nativePrefetchSegmentBytes 单分片预取上限，超过则不缓存，
	// 避免整文件型分片（byterange 单文件等）占满内存。
	nativePrefetchSegmentBytes = 16 << 20
	// nativePrefetchTimeout 单次预取请求超时，避免挂死占用并发槽。
	nativePrefetchTimeout = 30 * time.Second
)

type nativePrefetchEntry struct {
	data        []byte
	contentType string
}

// notePlaylistSegments 记录最近一次改写后媒体清单的分片顺序。
// body 是 nativeRewrite 的产物（去广告清洗在其之前完成），行内已是
// 本机回环地址，取末段即资产 id。master 清单没有 segment 行，
// 不覆盖旧顺序。缓存以资产 id（由分片地址派生）为键，直播清单
// 刷新后顺序更新、已缓存分片仍可命中。
func (session *nativeStreamSession) notePlaylistSegments(body string) {
	var ids []string
	session.mu.Lock()
	for _, line := range strings.Split(body, "\n") {
		text := strings.TrimSpace(line)
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		id := text[strings.LastIndex(text, "/")+1:]
		if asset, ok := session.assets[id]; ok && asset.kind == "segment" {
			ids = append(ids, id)
		}
	}
	session.mu.Unlock()
	if len(ids) == 0 {
		return
	}
	session.prefetchMu.Lock()
	defer session.prefetchMu.Unlock()
	session.initPrefetchLocked()
	if slices.Equal(session.prefetchSegments, ids) {
		return
	}
	session.prefetchSegments = ids
	session.prefetchIndex = make(map[string]int, len(ids))
	for index, id := range ids {
		if _, exists := session.prefetchIndex[id]; !exists {
			session.prefetchIndex[id] = index
		}
	}
}

// prefetchAhead 在分片被请求后并行预取后续分片；已缓存或正在
// 预取的跳过。找不到顺序（清单尚未记录）时直接返回。
func (stream *nativeStreamServer) prefetchAhead(session *nativeStreamSession, assetID string) {
	if session.ctx.Err() != nil {
		return
	}
	session.prefetchMu.Lock()
	session.initPrefetchLocked()
	index, ok := session.prefetchIndex[assetID]
	if !ok {
		session.prefetchMu.Unlock()
		return
	}
	var targets []string
	for next := index + 1; next < len(session.prefetchSegments) && len(targets) < nativePrefetchDepth; next++ {
		id := session.prefetchSegments[next]
		if _, cached := session.prefetchCache[id]; cached || session.prefetchInflight[id] {
			continue
		}
		session.prefetchInflight[id] = true
		targets = append(targets, id)
	}
	session.prefetchMu.Unlock()
	for _, id := range targets {
		go stream.prefetchSegment(session, id)
	}
}

// prefetchSegment 拉取一个分片进预取缓存。请求构造与 nativeServe 的
// 上游请求一致（UA + Referer，经 nativeRequest 走媒体凭证与授权），
// 保证预取与直连行为相同。任何失败都静默放弃。
func (stream *nativeStreamServer) prefetchSegment(session *nativeStreamSession, assetID string) {
	defer func() {
		session.prefetchMu.Lock()
		delete(session.prefetchInflight, assetID)
		session.prefetchMu.Unlock()
	}()
	select {
	case session.prefetchSem <- struct{}{}:
		defer func() { <-session.prefetchSem }()
	case <-session.ctx.Done():
		return
	}
	session.mu.Lock()
	asset, ok := session.assets[assetID]
	session.mu.Unlock()
	if !ok || asset.kind != "segment" {
		return
	}
	ctx, cancel := context.WithTimeout(
		providerMediaContext(withProxySource(session.ctx, session.source), session.credentials),
		nativePrefetchTimeout,
	)
	defer cancel()
	upstream, err := http.NewRequestWithContext(ctx, http.MethodGet, asset.address, nil)
	if err != nil {
		return
	}
	upstream.Header.Set("User-Agent", UserAgent)
	upstream.Header.Set("Referer", session.referer)
	response, err := stream.nativeRequest(upstream)
	if err != nil {
		return
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, nativePrefetchSegmentBytes+1))
	if err != nil || len(body) == 0 || len(body) > nativePrefetchSegmentBytes {
		return
	}
	session.prefetchStore(assetID, nativePrefetchEntry{
		data:        body,
		contentType: response.Header.Get("Content-Type"),
	})
}

func (session *nativeStreamSession) prefetchStore(assetID string, entry nativePrefetchEntry) {
	session.prefetchMu.Lock()
	defer session.prefetchMu.Unlock()
	session.initPrefetchLocked()
	if previous, exists := session.prefetchCache[assetID]; exists {
		session.prefetchBytes -= int64(len(previous.data))
	} else {
		session.prefetchOrder = append(session.prefetchOrder, assetID)
	}
	session.prefetchCache[assetID] = entry
	session.prefetchBytes += int64(len(entry.data))
	for session.prefetchBytes > nativePrefetchCacheBytes && len(session.prefetchOrder) > 1 {
		oldest := session.prefetchOrder[0]
		session.prefetchOrder = session.prefetchOrder[1:]
		if evicted, exists := session.prefetchCache[oldest]; exists {
			session.prefetchBytes -= int64(len(evicted.data))
			delete(session.prefetchCache, oldest)
		}
	}
}

func (session *nativeStreamSession) prefetchLookup(assetID string) (nativePrefetchEntry, bool) {
	session.prefetchMu.Lock()
	defer session.prefetchMu.Unlock()
	entry, ok := session.prefetchCache[assetID]
	return entry, ok
}

// initPrefetchLocked 懒初始化预取状态，调用方须持有 prefetchMu。
func (session *nativeStreamSession) initPrefetchLocked() {
	if session.prefetchCache == nil {
		session.prefetchCache = map[string]nativePrefetchEntry{}
	}
	if session.prefetchInflight == nil {
		session.prefetchInflight = map[string]bool{}
	}
	if session.prefetchIndex == nil {
		session.prefetchIndex = map[string]int{}
	}
	if session.prefetchSem == nil {
		session.prefetchSem = make(chan struct{}, nativePrefetchWorkers)
	}
}
