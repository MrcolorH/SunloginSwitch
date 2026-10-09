import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/sunlogin_service.dart';

class WebLoginRoute {
  final String title;
  final String subtitle;
  final String url;

  const WebLoginRoute({
    required this.title,
    required this.subtitle,
    required this.url,
  });
}

class WebLoginPage extends StatefulWidget {
  final String? initialUrl;
  final String? initialRouteTitle;

  const WebLoginPage({
    super.key,
    this.initialUrl,
    this.initialRouteTitle,
  });

  static const List<WebLoginRoute> availableRoutes = [
    WebLoginRoute(
      title: '线路一：贝锐统一通行证 (推荐)',
      subtitle: '移动端专用，支持短信验证码与密码登录',
      url: 'https://passport.oray.com/login/',
    ),
    WebLoginRoute(
      title: '线路二：向日葵管理中心',
      subtitle: '向日葵专属后台入口',
      url: 'https://sunlogin.oray.com/passport/login',
    ),
    WebLoginRoute(
      title: '线路三：贝锐标准控制台',
      subtitle: '全功能控制中心登录入口',
      url: 'https://console.oray.com/passport/login',
    ),
  ];

  @override
  State<WebLoginPage> createState() => _WebLoginPageState();
}

class _WebLoginPageState extends State<WebLoginPage> {
  late final WebViewController _controller;
  final SunloginService _service = SunloginService();

  late String _currentUrl;
  late String _currentRouteTitle;
  int _progress = 0;
  bool _isChecking = false;
  bool _hasSucceeded = false;
  bool _isShowing403Dialog = false;
  int _manualCheckFailCount = 0;
  final Set<String> _failedRouteUrls = {};
  Timer? _sessionDetectTimer;

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.initialUrl ?? WebLoginPage.availableRoutes[0].url;
    _currentRouteTitle = widget.initialRouteTitle ?? WebLoginPage.availableRoutes[0].title;
    _initWebViewController();
    _startBackgroundSessionWatcher();
  }

  @override
  void dispose() {
    _sessionDetectTimer?.cancel();
    super.dispose();
  }

  /// 启动后台静默会话检测，每 1.5 秒尝试一次凭据捕获，静默不打扰用户
  void _startBackgroundSessionWatcher() {
    _sessionDetectTimer = Timer.periodic(const Duration(milliseconds: 1500), (timer) async {
      if (_hasSucceeded || !mounted) return;
      final success = await _checkAndExtract(isManual: false);
      if (success) {
        _onLoginSuccess();
      }
    });
  }

  void _initWebViewController() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) setState(() => _progress = progress);
          },
          onPageStarted: (url) {
            _parseUrlForTokens(url);
          },
          onPageFinished: (url) async {
            if (mounted) setState(() => _progress = 100);
            _parseUrlForTokens(url);
            // 页面加载完成后静默检测：如果有认证信息就跳回，如果没有就不做任何提示，保留在页面上
            final success = await _checkAndExtract(isManual: false);
            if (success) {
              _onLoginSuccess();
            }
          },
          onHttpError: (error) async {
            final code = error.response?.statusCode;
            if (code == 403 || code == 302 || code == 401) {
              await _handlePotential403();
            }
          },
          onWebResourceError: (error) async {
            if (error.description.contains('403')) {
              await _handlePotential403();
            }
          },
          onUrlChange: (change) {
            final u = change.url ?? '';
            if (u.isNotEmpty) {
              _parseUrlForTokens(u);
            }
          },
          onNavigationRequest: (request) async {
            final uri = Uri.parse(request.url);
            // 拦截微信、支付宝等第三方 App 调起
            if (uri.scheme == 'weixin' || uri.scheme == 'alipays') {
              try {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              } catch (_) {}
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(_currentUrl));
  }

  /// 当页面遇到 403 时：先检查是否已有认证信息（登录成功后的403重定向），若无则引导切换线路或扫码
  Future<void> _handlePotential403() async {
    if (_hasSucceeded || !mounted) return;
    final success = await _checkAndExtract(isManual: false);
    if (success) {
      _onLoginSuccess();
      return;
    }

    _failedRouteUrls.add(_currentUrl);

    // 确实没有认证信息且页面 403 了：引导用户切换到其他可用线路或双机扫码登录
    if (!_isShowing403Dialog && mounted) {
      _isShowing403Dialog = true;
      _show403GuideDialog();
    }
  }

  /// 403 智能换线与扫码引导对话框
  void _show403GuideDialog() {
    final remainingRoutes = WebLoginPage.availableRoutes
        .where((r) => r.url != _currentUrl && !_failedRouteUrls.contains(r.url))
        .toList();
    final bool allRoutesFailed = remainingRoutes.isEmpty;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          allRoutesFailed ? Icons.phonelink_setup_rounded : Icons.warning_amber_rounded,
          color: allRoutesFailed ? Colors.teal : Colors.orange,
          size: 32,
        ),
        title: Text(allRoutesFailed ? '3 条网页线路均访问受限' : '当前线路受限 (403)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              allRoutesFailed
                  ? '向日葵服务器当前对移动端网页登录进行了全线路受限 (403)。\n\n强烈建议改用【双机扫码登录】（使用电脑或另一部手机展示二维码，向日葵 App 扫码即可 100% 成功），或稍后重试。'
                  : '当前登录线路（$_currentRouteTitle）限制了手机端访问。建议切换至其他未受限线路重试，或直接前往扫码登录：',
              style: const TextStyle(fontSize: 13, height: 1.45),
            ),
            if (!allRoutesFailed) ...[
              const SizedBox(height: 14),
              ...remainingRoutes.map((r) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                      tileColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      leading: const Icon(Icons.swap_horiz, color: Colors.teal),
                      title: Text(r.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      subtitle: Text(r.subtitle, style: const TextStyle(fontSize: 11)),
                      onTap: () {
                        Navigator.pop(ctx);
                        _switchRoute(r);
                      },
                    ),
                  )),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('稍后重试'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: allRoutesFailed ? Theme.of(context).colorScheme.primary : Colors.teal,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context, 'switchToQr'); // 返回给上级页面并指示切换至双机扫码Tab
            },
            icon: const Icon(Icons.qr_code_scanner, size: 16),
            label: const Text('前往双机扫码登录'),
          ),
        ],
      ),
    ).then((_) => _isShowing403Dialog = false);
  }

  /// 检查 URL 中的参数（部分授权回调直接附带 token 参数）
  void _parseUrlForTokens(String urlStr) {
    try {
      final uri = Uri.parse(urlStr);
      final token = uri.queryParameters['access_token'] ??
          uri.queryParameters['token'] ??
          uri.queryParameters['auth_token'];
      if (token != null && token.length > 20) {
        _loginWithToken(token);
      }
    } catch (_) {}
  }

  Future<void> _loginWithToken(String token) async {
    if (_hasSucceeded) return;
    try {
      await _service.loginWithDirectToken(token, '网页登录用户');
      _onLoginSuccess();
    } catch (_) {}
  }

  /// 核心凭据提取逻辑
  /// 返回 true 表示成功提取并验证凭据；返回 false 表示未检测到有效凭据
  Future<bool> _checkAndExtract({bool isManual = false}) async {
    if (_hasSucceeded || !mounted) return false;

    if (isManual) {
      setState(() => _isChecking = true);
    }

    try {
      final cookieManager = WebViewCookieManager();

      // 1. 尝试从 document.cookie 获取
      final Map<String, String> mergedCookies = {};
      try {
        final jsCookies = await _controller.runJavaScriptReturningResult('document.cookie');
        if (jsCookies is String && jsCookies.isNotEmpty) {
          String clean = jsCookies;
          if (clean.startsWith('"') && clean.endsWith('"')) {
            clean = clean.substring(1, clean.length - 1);
          }
          final parts = clean.split(';');
          for (final p in parts) {
            final kv = p.trim().split('=');
            if (kv.length == 2) {
              mergedCookies[kv[0].trim()] = kv[1].trim();
            }
          }
        }
      } catch (_) {}

      // 2. 从 WebViewCookieManager 获取所有相关域名的 Cookie（包括 HttpOnly 的 _s_id_）
      final domains = [
        Uri.parse('https://passport.oray.com'),
        Uri.parse('https://sunlogin.oray.com'),
        Uri.parse('https://console.oray.com'),
        Uri.parse('https://oray.com'),
        Uri.parse('https://oray.net'),
      ];

      for (final domain in domains) {
        try {
          final cookies = await cookieManager.getCookies(domain: domain);
          for (final c in cookies) {
            mergedCookies[c.name] = c.value;
          }
        } catch (_) {}
      }

      // 3. 从页面的 localStorage / sessionStorage 尝试抓取 Token
      String? foundStorageToken;
      try {
        final storageData = await _controller.runJavaScriptReturningResult('''
          (function() {
            var data = {};
            try {
              for (var i = 0; i < localStorage.length; i++) {
                var k = localStorage.key(i);
                data[k] = localStorage.getItem(k);
              }
              for (var j = 0; j < sessionStorage.length; j++) {
                var sk = sessionStorage.key(j);
                data[sk] = sessionStorage.getItem(sk);
              }
            } catch(e) {}
            return JSON.stringify(data);
          })()
        ''');

        if (storageData is String && storageData.isNotEmpty) {
          String cleanStr = storageData;
          if (cleanStr.startsWith('"') && cleanStr.endsWith('"')) {
            try {
              cleanStr = jsonDecode(cleanStr);
            } catch (_) {}
          }
          final decoded = jsonDecode(cleanStr);
          if (decoded is Map) {
            for (final entry in decoded.entries) {
              final k = entry.key.toString().toLowerCase();
              final v = entry.value.toString();
              if (k.contains('token') && v.length > 20) {
                foundStorageToken = v;
                break;
              }
            }
          }
        }
      } catch (_) {}

      // 4. 发起凭证兑换与验证
      final success = await _service.tryLoginWithWebCredentials(
        directToken: foundStorageToken,
        cookies: mergedCookies,
      );

      if (success) {
        return true;
      }

      if (isManual && mounted) {
        _manualCheckFailCount++;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _manualCheckFailCount >= 2
                  ? '未检测到有效登录凭据。若网页无法登录，可点击右上角切换其他线路或改用双机扫码'
                  : '未检测到有效登录状态，请先在下方网页中完成登录验证',
            ),
            duration: const Duration(seconds: 3),
            action: _manualCheckFailCount >= 2
                ? SnackBarAction(
                    label: '去扫码',
                    textColor: Colors.amber,
                    onPressed: () => Navigator.pop(context, 'switchToQr'),
                  )
                : null,
          ),
        );
      }
      return false;
    } catch (e) {
      if (isManual && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('验证凭据失败: $e')),
        );
      }
      return false;
    } finally {
      if (mounted && isManual) {
        setState(() => _isChecking = false);
      }
    }
  }

  void _onLoginSuccess() {
    if (_hasSucceeded) return;
    _hasSucceeded = true;
    _sessionDetectTimer?.cancel();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ 登录验证成功！已自动获取向日葵账号与插座设备'),
          backgroundColor: Colors.teal,
          duration: Duration(seconds: 2),
        ),
      );
      Navigator.pop(context, true);
    }
  }

  /// 用户主动点击刷新时的处理：
  /// 重新加载网页，并检测是否已有认证信息；若有则跳回，若无则静默不提示，保留在页面上
  Future<void> _handleRefresh() async {
    _controller.reload();
    final success = await _checkAndExtract(isManual: false);
    if (success) {
      _onLoginSuccess();
    }
  }

  /// 切换到指定的登录线路
  void _switchRoute(WebLoginRoute route) {
    setState(() {
      _currentUrl = route.url;
      _currentRouteTitle = route.title;
      _progress = 0;
    });
    _controller.loadRequest(Uri.parse(route.url));
  }

  /// 在外部手机默认浏览器中打开当前页面
  Future<void> _openInExternalBrowser() async {
    try {
      final uri = Uri.parse(_currentUrl);
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (launched && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已调起外部浏览器打开【$_currentRouteTitle】\n登录完成后切回本 App 即可自动检测！'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('调起外部浏览器失败: $e')),
        );
      }
    }
  }

  /// 用户点击【已登录？点此进入】时的处理
  Future<void> _handleManualCheck() async {
    final success = await _checkAndExtract(isManual: true);
    if (success) {
      _onLoginSuccess();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '向日葵官方免扫码登录',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Text(
              _currentRouteTitle,
              style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          // 切换线路菜单
          PopupMenuButton<WebLoginRoute>(
            tooltip: '切换登录线路',
            icon: const Icon(Icons.alt_route_rounded),
            onSelected: _switchRoute,
            itemBuilder: (context) => WebLoginPage.availableRoutes.map((r) {
              final isSelected = r.url == _currentUrl;
              return PopupMenuItem<WebLoginRoute>(
                value: r,
                child: Row(
                  children: [
                    Icon(
                      isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                      size: 18,
                      color: isSelected ? theme.colorScheme.primary : Colors.grey,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            r.title,
                            style: TextStyle(
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                              fontSize: 13,
                              color: isSelected ? theme.colorScheme.primary : null,
                            ),
                          ),
                          Text(r.subtitle, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 22),
            tooltip: '刷新网页并检测',
            onPressed: _handleRefresh,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              // 平滑进度条
              if (_progress < 100)
                LinearProgressIndicator(
                  value: _progress / 100.0,
                  minHeight: 2.5,
                  backgroundColor: Colors.transparent,
                  color: theme.colorScheme.primary,
                ),

              // 主体 WebView（交互无遮挡，自由操作输入）
              Expanded(
                child: WebViewWidget(controller: _controller),
              ),
            ],
          ),

          // 底部悬浮操作胶囊
          Positioned(
            left: 16,
            right: 16,
            bottom: 20,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      // 线路切换快捷按钮
                      PopupMenuButton<WebLoginRoute>(
                        tooltip: '切换线路',
                        onSelected: _switchRoute,
                        itemBuilder: (context) => WebLoginPage.availableRoutes.map((r) {
                          return PopupMenuItem<WebLoginRoute>(
                            value: r,
                            child: Text(r.title, style: const TextStyle(fontSize: 13)),
                          );
                        }).toList(),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.swap_horiz_rounded, size: 16, color: theme.colorScheme.primary),
                              const SizedBox(width: 4),
                              const Text('换线路', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),

                      // 在外部浏览器打开按钮
                      IconButton(
                        onPressed: _openInExternalBrowser,
                        tooltip: '在手机浏览器中打开',
                        icon: const Icon(Icons.open_in_new_rounded, size: 18),
                        visualDensity: VisualDensity.compact,
                      ),

                      const Spacer(),

                      // 主动进入按钮：根据检测状态展示真实准确的文案（检测中显示“正在验证登录...”，绝不提前显示“登录成功”）
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                        ),
                        onPressed: _isChecking ? null : _handleManualCheck,
                        icon: _isChecking
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.arrow_forward_rounded, size: 16),
                        label: Text(
                          _isChecking ? '正在验证登录...' : '已登录？点此进入',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
