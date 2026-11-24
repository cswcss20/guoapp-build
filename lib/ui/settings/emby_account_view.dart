import 'package:flutter/material.dart';

import '../../core_bridge.dart';
import '../app_scope.dart';
import '../widgets/focus_ring.dart';
import '../widgets/form_text_field.dart';

class EmbyAccount {
  const EmbyAccount({this.loggedIn = false, this.name = '', this.server = ''});

  factory EmbyAccount.fromJson(Map<String, dynamic> json) => EmbyAccount(
    loggedIn: json['loggedIn'] == true,
    name: json['name'] as String? ?? '',
    server: json['server'] as String? ?? '',
  );

  final bool loggedIn;
  final String name;
  final String server;
}

Future<EmbyAccount?> showEmbyLogin(BuildContext context) =>
    showDialog<EmbyAccount>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _EmbyLoginDialog(repository: AppScope.of(context).repository),
    );

class EmbyAccountButton extends StatefulWidget {
  const EmbyAccountButton({super.key, required this.admin, this.style});
  final bool admin;
  final ButtonStyle? style;

  @override
  State<EmbyAccountButton> createState() => _EmbyAccountButtonState();
}

class _EmbyAccountButtonState extends State<EmbyAccountButton> {
  EmbyAccount? _account;
  var _busy = false;

  AppRepository get _repository => AppScope.of(context).repository;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final account = await _repository
        .sourceAccount('emby', '', const {})
        .then(EmbyAccount.fromJson)
        .catchError((_) => const EmbyAccount());
    if (mounted) setState(() => _account = account);
  }

  Future<void> _login() async {
    final account = await showEmbyLogin(context);
    if (account != null && mounted) setState(() => _account = account);
  }

  Future<void> _logout() async {
    setState(() => _busy = true);
    try {
      final account = EmbyAccount.fromJson(
        await _repository.sourceAccount('emby', 'logout', const {}),
      );
      if (mounted) setState(() => _account = account);
    } catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$failure')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggle() {
    final account = _account;
    if (account == null || _busy) return;
    account.loggedIn ? _logout() : _login();
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = _account?.loggedIn ?? false;
    return FocusRing(
      radius: 20,
      child: FilledButton.tonalIcon(
        style: widget.style,
        onPressed: widget.admin && _account != null && !_busy ? _toggle : null,
        icon: Icon(loggedIn ? Icons.logout_rounded : Icons.login_rounded),
        label: Text(loggedIn ? '退出登录' : '登录'),
      ),
    );
  }
}

class _EmbyLoginDialog extends StatefulWidget {
  const _EmbyLoginDialog({required this.repository});
  final AppRepository repository;

  @override
  State<_EmbyLoginDialog> createState() => _EmbyLoginDialogState();
}

class _EmbyLoginDialogState extends State<_EmbyLoginDialog> {
  final _server = TextEditingController();
  final _username = TextEditingController();
  final _secret = TextEditingController();
  final _usernameFocus = FocusNode();
  final _secretFocus = FocusNode();
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _secret.dispose();
    _usernameFocus.dispose();
    _secretFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final server = _server.text.trim();
    final username = _username.text.trim();
    if (server.isEmpty || username.isEmpty) {
      setState(() => _error = '请填写服务器地址和用户名');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.repository.sourceAccount('emby', 'login', {
        'server': server,
        'username': username,
        'pass' 'word': _secret.text,
      });
      if (mounted) Navigator.pop(context, EmbyAccount.fromJson(result));
    } catch (failure) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$failure';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('登录 Emby'),
    content: SizedBox(
      width: 352,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            FormTextField(
              controller: _server,
              autofocus: true,
              maxLength: 256,
              onSubmitted: (_) => _usernameFocus.requestFocus(),
              decoration: const InputDecoration(
                labelText: '服务器地址',
                hintText: 'http://192.168.1.10:8096',
              ),
            ),
            FormTextField(
              controller: _username,
              focusNode: _usernameFocus,
              maxLength: 128,
              onSubmitted: (_) => _secretFocus.requestFocus(),
              decoration: const InputDecoration(labelText: '用户名'),
            ),
            FormTextField(
              controller: _secret,
              focusNode: _secretFocus,
              obscure: true,
              maxLength: 128,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: '密码（如有）',
                hintText: '没有密码可留空',
                errorText: _error,
              ),
            ),
            const Text('登录信息只保存在本机，并直接与你的 Emby 服务器通信。'),
          ],
        ),
      ),
    ),
    actions: [
      FocusRing(
        radius: 20,
        child: TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ),
      FocusRing(
        radius: 20,
        child: FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('登录'),
        ),
      ),
    ],
  );
}
