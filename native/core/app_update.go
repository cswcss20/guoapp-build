package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
)

var nativeUpdateServer = ""

var nativeProjectURL = ""

var nativeAppVersionPattern = regexp.MustCompile(`^\d+\.\d+\.\d+\+(\d+)$`)

type nativeUpdate struct {
	Available bool   `json:"available"`
	Version   string `json:"version,omitempty"`
	URL       string `json:"url,omitempty"`
}

func nativeUpdateServers() []string {
	servers := []string{}
	for _, server := range strings.Split(nativeUpdateServer, ",") {
		if server = strings.TrimRight(strings.TrimSpace(server), "/"); server != "" {
			servers = append(servers, server)
		}
	}
	return servers
}

func nativeReleasePrefix() string {
	project := strings.TrimRight(strings.TrimSpace(nativeProjectURL), "/")
	if project == "" {
		return ""
	}
	return project + "/releases/"
}

func nativeAppBuildNumber(version string) (int, bool) {
	match := nativeAppVersionPattern.FindStringSubmatch(version)
	if match == nil {
		return 0, false
	}
	number, err := strconv.Atoi(match[1])
	return number, err == nil
}

func (engine *nativeEngine) checkUpdate(ctx context.Context, version string) (nativeUpdate, error) {
	current, valid := nativeAppBuildNumber(version)
	if !valid {
		return nativeUpdate{}, errors.New("应用版本号无效")
	}
	servers := nativeUpdateServers()
	if len(servers) == 0 {
		return nativeUpdate{}, errors.New("这个安装包没有配置更新服务器，无法检查更新")
	}
	var latest nativeUpdate
	var err error
	for _, server := range servers {
		if latest, err = engine.fetchLatest(ctx, server); err == nil || ctx.Err() != nil {
			break
		}
	}
	if err != nil {
		return nativeUpdate{}, fmt.Errorf("更新服务器请求失败：%w", err)
	}
	number, valid := nativeAppBuildNumber(latest.Version)
	if !valid {
		return nativeUpdate{}, errors.New("更新服务器没有返回有效的版本号")
	}
	if number <= current {
		return nativeUpdate{}, nil
	}
	prefix := nativeReleasePrefix()
	if prefix == "" {
		return nativeUpdate{}, errors.New("这个安装包没有配置项目地址，无法确认新版本的发布页")
	}
	if !strings.HasPrefix(latest.URL, prefix) {
		return nativeUpdate{}, errors.New("更新服务器返回的发布页不属于本项目，已忽略")
	}
	return nativeUpdate{Available: true, Version: latest.Version, URL: latest.URL}, nil
}

func (engine *nativeEngine) fetchLatest(ctx context.Context, server string) (nativeUpdate, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, server+"/v1/latest", nil)
	if err != nil {
		return nativeUpdate{}, err
	}
	response, err := engine.downloader.client.Do(request)
	if err != nil {
		return nativeUpdate{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nativeUpdate{}, fmt.Errorf("检查更新失败：HTTP %d", response.StatusCode)
	}
	var latest nativeUpdate
	return latest, json.NewDecoder(io.LimitReader(response.Body, 4096)).Decode(&latest)
}
