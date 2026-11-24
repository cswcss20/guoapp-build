import 'dart:async';

import 'package:flutter/material.dart';

import '../app_build.dart';
import '../local_store.dart';
import '../zh_script.dart';
import 'app_scope.dart';
import 'widgets/focus_ring.dart';

const termsVersion = 2;
const _clauses = [
  '$appName 是开源软件，框架与模块商店中的站源模块代码公开，仅供个人学习与技术研究，**不收费，不提供任何付费服务**。',
  '$appName 与红果短剧及其他各站源的运营方**无任何关联**，未获得其授权或认可；文中提到的名称和商标归各自权利人所有。',
  '$appName 本身**不存储、不上传、不分发任何影视内容**，所有内容均来自第三方站点，版权归原权利人所有；应用不解除源站 VIP 或其他授权限制。',
  '除内置的红果外，站源以模块形式由你自行安装，模块会访问安装时列出的第三方站点；**从文件或地址安装的模块未经模块商店收录，请只安装可信来源的模块，由此产生的后果由你自行承担**。',
  '通过本应用观看或下载的内容仅供试看和个人学习交流，**请于下载后 24 小时内删除**；如喜欢相关作品，请支持正版。',
  '**不得在任何公开平台（如社交媒体、短视频平台、论坛、公开群组等）宣传、分享本应用及其安装包、下载链接或通过本应用获取的内容**。',
  '站源内容（包括其中的广告、链接、二维码、联系方式等）均由第三方提供，**请自行鉴别真伪，切勿轻信其中的充值、投资、博彩、兼职等信息**；**由此造成的任何财产损失，作者不承担任何责任**。',
  '观看记录、追剧和下载等数据只保存在本设备，不会上传。',
  '你应遵守所在地法律法规及各站点的服务条款，**不得将本应用用于违法或商业用途**；**因使用本应用产生的一切后果由你自行承担**。',
  '本应用按「现状」提供，不对可用性、稳定性或适用性作任何保证，**作者不承担由此造成的任何直接或间接损失**。',
  '如不同意本条款，**请立即停止使用并卸载本应用**。',
];

class TermsPage extends StatefulWidget {
  const TermsPage({super.key, required this.store});
  final LocalStore store;

  @override
  State<TermsPage> createState() => _TermsPageState();
}

class _TermsPageState extends State<TermsPage> {
  var _agreed = false;
  var _busy = false;

  void _toggleAgreed() => setState(() => _agreed = !_agreed);

  Future<void> _accept() async {
    setState(() => _busy = true);
    try {
      await widget.store.setAcceptedTerms(termsVersion);
    } catch (failure) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存失败：$failure')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final television = AppScope.of(context).television;
    final body = theme.textTheme.bodyMedium?.copyWith(height: 1.6);
    final emphasis = TextStyle(
      color: theme.colorScheme.error,
      fontWeight: FontWeight.w600,
    );
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: television
                ? const EdgeInsets.symmetric(
                    horizontal: televisionInset,
                    vertical: 27,
                  )
                : const EdgeInsets.symmetric(horizontal: 16, vertical: 48),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 8,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      zh('$appName 使用条款'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    zh('请阅读以上条款，勾选同意后才能继续。'),
                    textAlign: TextAlign.center,
                    style: body?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  for (final (index, clause) in _clauses.indexed)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                      child: Text.rich(
                        TextSpan(
                          text: '${index + 1}. ',
                          children: [
                            for (final (part, text)
                                in zh(clause).split('**').indexed)
                              TextSpan(
                                text: text,
                                style: part.isOdd ? emphasis : null,
                              ),
                          ],
                        ),
                        style: body,
                      ),
                    ),
                  MergeSemantics(
                    child: Material(
                      type: MaterialType.transparency,
                      borderRadius: BorderRadius.circular(8),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: _busy ? null : _toggleAgreed,
                        child: Row(
                          children: [
                            ExcludeFocus(
                              child: Checkbox(
                                value: _agreed,
                                onChanged: _busy
                                    ? null
                                    : (_) => _toggleAgreed(),
                              ),
                            ),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  0,
                                  12,
                                  8,
                                  12,
                                ),
                                child: Text(zh('我已阅读并同意以上全部条款')),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FocusRing(
                    radius: 24,
                    child: FilledButton(
                      style: const ButtonStyle(
                        minimumSize: WidgetStatePropertyAll(
                          Size.fromHeight(48),
                        ),
                      ),
                      onPressed: _agreed && !_busy ? _accept : null,
                      child: Text(zh('同意并继续')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
