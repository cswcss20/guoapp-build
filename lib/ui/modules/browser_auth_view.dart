import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../core_bridge.dart';
import '../app_scope.dart';
import '../widgets/focus_ring.dart';

/// SupJav 浏览器验证入口。
/// 用户在此页通过 Cloudflare 验证后，模块自动读取 Cookie 与实际 UA，
/// 通过通用的 sourceAccount('supjav-cookie', 'setCookies', ...) 写回模块状态。
const _authUrl = 'https://supjav.com/zh/';
const _fallbackUA =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

Future<void> showBrowserAuth(BuildContext context, String source) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => BrowserAuthView(source: source),
      ),
    );

class BrowserAuthButton extends StatelessWidget {
  const BrowserAuthButton({super.key, required this.source, this.style});

  final String source;
  final ButtonStyle? style;

  @override
  Widget build(BuildContext context) {
    return FocusRing(
      radius: 20,
      child: FilledButton.tonalIcon(
        style: style,
        onPressed: () => showBrowserAuth(context, source),
        icon: const Icon(Icons.public_rounded),
        label: const Text('浏览器验证'),
      ),
    );
  }
}

class BrowserAuthView extends StatefulWidget {
  const BrowserAuthView({super.key, required this.source});

  final String source;

  @override
  State<BrowserAuthView> createState() => _BrowserAuthViewState();
}

class _BrowserAuthViewState extends State<BrowserAuthView> {
  InAppWebViewController? _controller;
  Timer? _poll;
  bool _busy = false;
  bool _saved = false;
  String _status = '请在下方页面完成 Cloudflare 验证；通过后会自动保存 Cookie 与 UA。';

  AppRepository get _repository => AppScope.of(context).repository;

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
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _capture(auto: true));
  }

  Future<void> _capture({required bool auto}) async {
    final controller = _controller;
    if (controller == null || _busy || _saved) return;
    setState(() => _busy = true);
    try {
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri(_authUrl),
      );
      final pairs = <String>[];
      for (final cookie in cookies) {
        final name = cookie.name.trim();
        if (name.isEmpty) continue;
        pairs.add('$name=${cookie.value}');
      }
      final cookieHeader = pairs.join('; ');
      if (!cookieHeader.contains('cf_clearance=')) {
        if (!auto) {
          _setStatus('还没有拿到 cf_clearance，请先过完验证再点保存。');
        }
        return;
      }

      var ua = _fallbackUA;
      try {
        final jsUa = await controller.evaluateJavascript(
          source: 'navigator.userAgent',
        );
        var text = jsUa == null ? '' : jsUa.toString().trim();
        if (text.startsWith('"') && text.endsWith('"') && text.length > 2) {
          text = text.substring(1, text.length - 1);
        }
        if (text.isNotEmpty) ua = text;
      } catch (_) {
        try {
          final settings = await controller.getSettings();
          if (settings?.userAgent != null && settings!.userAgent!.isNotEmpty) {
            ua = settings.userAgent!;
          }
        } catch (_) {}
      }

      await _repository.sourceAccount(widget.source, 'setCookies', {
        'cookie': cookieHeader,
        'ua': ua,
      });
      _poll?.cancel();
      if (mounted) {
        setState(() {
          _saved = true;
          _status = '已保存 ${pairs.length} 个 Cookie（含 cf_clearance）和浏览器 UA。'
              '可以返回模块正常使用了。';
        });
      }
    } catch (error) {
      if (!auto) _setStatus('保存失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    setState(() => _busy = true);
    try {
      await _repository.sourceAccount(widget.source, 'clearCookies', {});
      await CookieManager.instance().deleteCookies(url: WebUri(_authUrl));
      _poll?.cancel();
      if (mounted) {
        setState(() {
          _saved = false;
          _status = '已清除保存的 Cookie 与 UA，可重新验证。';
        });
      }
    } catch (error) {
      _setStatus('清除失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SupJav 浏览器验证'),
        actions: [
          IconButton(
            onPressed: _busy ? null : () => _capture(auto: false),
            tooltip: '立即保存',
            icon: const Icon(Icons.save_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text(
                _status,
                style: TextStyle(
                  color: _saved ? Colors.green : Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
            Expanded(
              child: InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(_authUrl)),
                initialSettings: InAppWebViewSettings(
                  userAgent: _fallbackUA,
                  javaScriptEnabled: true,
                  domStorageEnabled: true,
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
                    child: FocusRing(
                      radius: 20,
                      child: FilledButton.tonalIcon(
                        onPressed: _busy ? null : () => _capture(auto: false),
                        icon: const Icon(Icons.save_rounded),
                        label: const Text('保存验证结果'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FocusRing(
                      radius: 20,
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _clear,
                        icon: const Icon(Icons.delete_outline_rounded),
                        label: const Text('清除'),
                      ),
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
