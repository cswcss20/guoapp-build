import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'core_bridge.dart';
import 'zh_script.dart';

/// 应用内 WebView 验证桥接。
///
/// Cloudflare 这类人机验证只有真实浏览器内核能通过，普通 HTTP 请求永远拿回
/// 「Just a moment」。这里的做法是：
///   1. 起一个只监听 127.0.0.1 的 HTTP 服务，暴露 `/fetch`；
///   2. 把端口登记给 Go 核心，核心遇到需要验证的域名时改走这个回环地址；
///   3. 用户在应用内浏览器完成验证后，把 Cookie / UA 一并交给核心，后续请求
///      带着同一套指纹直连，不再被拦。
///
/// 端口只绑回环地址，且只在应用进程内有效。
///
/// 与上游实现的区别：上游用原生 MethodChannel（Android/iOS/macOS）开验证页与
/// 无头抓取；这里改用 flutter_inappwebview 实现同一套协议，Windows 也能用，
/// 不需要额外的原生代码。
abstract final class WebViewBridge {
  static HttpServer? _server;
  static Future<void> _fetchLock = Future<void>.value();

  /// 应用根导航器，由 app.dart 注入；验证页靠它推到最上层。
  static GlobalKey<NavigatorState>? navigatorKey;

  static const _fallbackUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  /// 应用内浏览器验证支持的平台（flutter_inappwebview 覆盖的平台）。
  static bool get supported =>
      !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isMacOS ||
          Platform.isWindows);

  /// 判断一条报错是不是「被 Cloudflare 拦了」。
  ///
  /// CF_CHALLENGE 是 ASCII 标记：报错经过 URL 编码后中文会变成 %E8..，
  /// 只有纯 ASCII 能稳定穿过那一层。
  static bool isChallengeError(String message) =>
      message.contains('CF_CHALLENGE') ||
      message.contains('Cloudflare 人机验证') ||
      message.contains('完成人机验证') ||
      message.contains('手动完成验证') ||
      message.toLowerCase().contains('just a moment');

  static Future<int> _ensureServer() async {
    final existing = _server;
    if (existing != null) return existing.port;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((request) async {
      try {
        if (request.uri.path != '/fetch') {
          request.response.statusCode = HttpStatus.notFound;
          return;
        }
        final target = request.uri.queryParameters['url'] ?? '';
        if (target.isEmpty) {
          request.response.statusCode = HttpStatus.badRequest;
          return;
        }
        final res = await _fetchHtml(target);
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'ok': res['ok'] == true,
            'html': res['html'] as String? ?? '',
            'url': res['url'] as String? ?? target,
            if (res['error'] != null) 'error': res['error'],
          }),
        );
      } catch (error) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'ok': false, 'error': '$error'}));
      } finally {
        await request.response.close();
      }
    });
    return server.port;
  }

  /// 无头 WebView 抓页面：等加载完成再多等一小段时间让挑战脚本跑完，
  /// 然后取渲染后的 HTML 与最终地址。并发请求串行化，避免多个无头实例打架。
  static Future<Map<String, dynamic>> _fetchHtml(String target) {
    final completer = Completer<Map<String, dynamic>>();
    _fetchLock = _fetchLock.then((_) async {
      try {
        completer.complete(await _fetchHtmlOnce(target));
      } catch (error) {
        completer.complete({'ok': false, 'error': '$error'});
      }
    });
    return completer.future;
  }

  static Future<Map<String, dynamic>> _fetchHtmlOnce(String target) async {
    final loaded = Completer<void>();
    HeadlessInAppWebView? headless;
    try {
      headless = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(target)),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          thirdPartyCookiesEnabled: true,
          userAgent: _fallbackUA,
        ),
        onLoadStop: (controller, url) {
          if (!loaded.isCompleted) loaded.complete();
        },
        onReceivedError: (controller, request, error) {
          if (request.isForMainFrame == true && !loaded.isCompleted) {
            loaded.complete();
          }
        },
      );
      await headless.run();
      await loaded.future.timeout(const Duration(seconds: 20));
      // 挑战脚本通常在 load 之后还要跑一会儿，给它一点时间落地。
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final controller = headless.webViewController;
      if (controller == null) {
        return {'ok': false, 'error': zh('浏览器内核没有就绪')};
      }
      final html = await controller.evaluateJavascript(
        source: 'document.documentElement.outerHTML',
      );
      final url = await controller.getUrl();
      return {
        'ok': true,
        'html': html?.toString() ?? '',
        'url': url?.toString() ?? target,
      };
    } finally {
      await headless?.dispose();
    }
  }

  /// 打开应用内验证页，通过后把 Cookie / UA 与回环端口交给核心。
  ///
  /// 返回 false 表示当前平台不支持、没有可用验证地址，或用户取消了验证。
  static Future<bool> verifySource(AppRepository repo, String source) async {
    if (!supported) return false;
    final url = await repo.sourceChallengeUrl(source);
    if (url.isEmpty) return false;
    final navigator = navigatorKey?.currentState;
    if (navigator == null) return false;
    final result = await navigator.push<_ChallengeResult>(
      MaterialPageRoute<_ChallengeResult>(
        builder: (_) => _ChallengePage(url: url),
      ),
    );
    if (result == null) return false;
    final port = await _ensureServer();
    await repo.registerWebViewBridge(
      port: port,
      url: url,
      source: source,
      cookies: result.cookies,
      userAgent: result.userAgent,
    );
    return true;
  }

  /// 把已经在别的验证页拿到的 Cookie / UA 登记给核心桥接（例如模块卡上的
  /// 浏览器验证页手动保存时），之后该域名的主机请求会改走桥接抓页。
  static Future<void> registerVerified(
    AppRepository repo, {
    required String url,
    required String source,
    required String cookies,
    required String userAgent,
  }) async {
    final port = await _ensureServer();
    await repo.registerWebViewBridge(
      port: port,
      url: url,
      source: source,
      cookies: cookies,
      userAgent: userAgent,
    );
  }
}

class _ChallengeResult {
  const _ChallengeResult(this.cookies, this.userAgent);

  final String cookies;
  final String userAgent;
}

/// 整屏验证页：用户在这里过完 Cloudflare 挑战，页面轮询 Cookie，
/// 拿到 cf_clearance 就自动收起并把 Cookie / UA 交回桥接。
/// 与 modules 的浏览器验证页同一套做法，只是地址由站源决定、结果交给核心桥接。
class _ChallengePage extends StatefulWidget {
  const _ChallengePage({required this.url});

  final String url;

  @override
  State<_ChallengePage> createState() => _ChallengePageState();
}

class _ChallengePageState extends State<_ChallengePage> {
  InAppWebViewController? _controller;
  Timer? _poll;
  bool _busy = false;
  bool _done = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _status = zh('请在下方页面完成人机验证；通过后会自动保存并继续。');
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _setStatus(String text) {
    if (mounted) setState(() => _status = text);
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _capture(auto: true),
    );
  }

  Future<String> _readUserAgent(InAppWebViewController controller) async {
    try {
      final jsUa = await controller.evaluateJavascript(
        source: 'navigator.userAgent',
      );
      var text = jsUa == null ? '' : jsUa.toString().trim();
      if (text.startsWith('"') && text.endsWith('"') && text.length > 2) {
        text = text.substring(1, text.length - 1);
      }
      if (text.isNotEmpty) return text;
    } catch (_) {}
    try {
      final settings = await controller.getSettings();
      if (settings?.userAgent != null && settings!.userAgent!.isNotEmpty) {
        return settings.userAgent!;
      }
    } catch (_) {}
    return WebViewBridge._fallbackUA;
  }

  Future<void> _capture({required bool auto}) async {
    final controller = _controller;
    if (controller == null || _busy || _done) return;
    setState(() => _busy = true);
    try {
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri(widget.url),
      );
      final pairs = <String>[];
      for (final cookie in cookies) {
        final name = cookie.name.trim();
        if (name.isEmpty) continue;
        pairs.add('$name=${cookie.value}');
      }
      final cookieHeader = pairs.join('; ');
      if (auto && !cookieHeader.contains('cf_clearance=')) {
        return;
      }
      if (cookieHeader.isEmpty) {
        if (!auto) _setStatus(zh('还没有拿到验证 Cookie，请先过完验证再点完成。'));
        return;
      }
      final ua = await _readUserAgent(controller);
      _poll?.cancel();
      _done = true;
      if (mounted) {
        Navigator.of(context).pop(_ChallengeResult(cookieHeader, ua));
      }
    } catch (error) {
      if (!auto) _setStatus(zh('保存失败：$error'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(zh('完成人机验证')),
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          tooltip: zh('取消'),
          icon: const Icon(Icons.close_rounded),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text(
                _status,
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              ),
            ),
            Expanded(
              child: InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(widget.url)),
                initialSettings: InAppWebViewSettings(
                  userAgent: WebViewBridge._fallbackUA,
                  javaScriptEnabled: true,
                  domStorageEnabled: true,
                  thirdPartyCookiesEnabled: true,
                  supportZoom: true,
                ),
                onWebViewCreated: (controller) {
                  _controller = controller;
                  _startPolling();
                },
                onLoadStop: (controller, url) {
                  _capture(auto: true);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _busy ? null : () => _capture(auto: false),
                      icon: const Icon(Icons.check_rounded),
                      label: Text(zh('完成验证')),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                      label: Text(zh('取消')),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
