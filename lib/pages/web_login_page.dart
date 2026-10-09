import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/sunlogin_service.dart';

class WebLoginPage extends StatefulWidget {
  const WebLoginPage({super.key});

  @override
  State<WebLoginPage> createState() => _WebLoginPageState();
}

class _WebLoginPageState extends State<WebLoginPage> {
  late final WebViewController _controller;
  final _service = SunloginService();

  int _progress = 0;
  bool _isProcessingLogin = false;
  bool _hasSucceeded = false;
  Timer? _sessionDetectTimer;

  // 官方登录地址
  static const String _defaultUrl = 'https://passport.oray.com/login/';

  @override
  void initState() {
    super.initState();
    _initWebViewController();
    _startBackgroundSessionWatcher();
  }

  @override
  void dispose() {
    _sessionDetectTimer?.cancel();
    super.dispose();
  }

  // 启动后台静默会话检测：用户在页面输入完成登录后，在网页跳至403之前就能提前拦截捕获并自动进入
  void _startBackgroundSessionWatcher() {
    _sessionDetectTimer = Timer.periodic(const Duration(milliseconds: 1200), (timer) async {
      if (_hasSucceeded || _isProcessingLogin || !mounted) return;
      await _checkAndExtract(isSilent: true);
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
          onPageStarted: (url) async {
            // 若页面开始重定向离开登录页，提前触发捕获并遮挡页面
            final lower = url.toLowerCase();
            if (!lower.contains('/login/') && (lower.contains('console') || lower.contains('sunlogin') || lower.contains('oray'))) {
              await _triggerAutoCapture('重定向开始');
            }
          },
          onPageFinished: (url) async {
            if (mounted) setState(() => _progress = 100);
            final lower = url.toLowerCase();
            if (!lower.contains('/login/')) {
              await _triggerAutoCapture('页面加载完成');
            }
          },
          onHttpError: (error) async {
            final code = error.response?.statusCode;
            // 关键：登录成功后向日葵/贝锐重定向的目标页面可能返回 403。
            // 立即拦截，使用全屏遮罩遮挡 403 画面，并自动提取凭据进入 App！
            if (code == 403 || code == 302 || code == 401) {
              await _triggerAutoCapture('拦截状态码 $code');
            }
          },
          onWebResourceError: (error) async {
            if (error.description.contains('403') || error.description.contains('Forbidden')) {
              await _triggerAutoCapture('拦截资源异常 403');
            }
          },
          onUrlChange: (change) async {
            final url = change.url ?? '';
            final lower = url.toLowerCase();
            if (url.isNotEmpty && !lower.contains('/login/')) {
              await _triggerAutoCapture('URL变更');
            }
          },
          onNavigationRequest: (request) async {
            final uri = Uri.parse(request.url);
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
      ..loadRequest(Uri.parse(_defaultUrl));
  }

  // 触发自动捕获：立即拉起全屏优雅加载遮罩，不让用户看到 403 页面
  Future<void> _triggerAutoCapture(String reason) async {
    if (_hasSucceeded || _isProcessingLogin || !mounted) return;
    setState(() => _isProcessingLogin = true);
    await _checkAndExtract(isSilent: false);
  }

  // 核心检测与凭据兑换逻辑
  Future<void> _checkAndExtract({bool isSilent = false, bool isManual = false}) async {
    if (_hasSucceeded || !mounted) return;

    if (!isSilent && !_isProcessingLogin) {
      setState(() => _isProcessingLogin = true);
    }

    try {
      final cookieManager = WebViewCookieManager();

      // 1. 获取所有相关的 Cookie
      final domains = [
        Uri.parse('https://sunlogin.oray.com'),
        Uri.parse('https://passport.oray.com'),
        Uri.parse('https://console.oray.com'),
        Uri.parse('https://oray.com'),
        Uri.parse('https://oray.net'),
      ];

      final Map<String, String> mergedCookies = {};
      for (final domain in domains) {
        try {
          final cookies = await cookieManager.getCookies(domain: domain);
          for (final c in cookies) {
            mergedCookies[c.name] = c.value;
          }
        } catch (_) {}
      }

      // 如果没有任何 Cookie，静默模式下跳过
      if (mergedCookies.isEmpty && isSilent) {
        return;
      }

      // 2. 尝试从页面的 localStorage / sessionStorage 抓取 token
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

      // 3. 验证凭据并尝试登录
      final success = await _service.tryLoginWithWebCredentials(
        directToken: foundStorageToken,
        cookies: mergedCookies,
      );

      if (success) {
        _hasSucceeded = true;
        _sessionDetectTimer?.cancel();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ 登录成功！已自动同步向日葵账号与插座设备'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 3),
            ),
          );
          Navigator.pop(context, true);
        }
        return;
      }

      if (isManual && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('尚未检测到登录状态，请先在网页中输入验证码或密码并点击登录'),
          ),
        );
      }
    } catch (e) {
      if (isManual && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('登录验证异常: $e')),
        );
      }
    } finally {
      if (mounted && !_hasSucceeded && !isSilent) {
        // 延时解除遮罩（如果未成功，允许用户继续操作）
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (mounted && !_hasSucceeded) {
            setState(() => _isProcessingLogin = false);
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '向日葵官方登录',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 22),
            tooltip: '刷新网页',
            onPressed: () => _controller.reload(),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              // 顶部平滑加载进度条
              if (_progress < 100)
                LinearProgressIndicator(
                  value: _progress / 100.0,
                  minHeight: 2.5,
                  backgroundColor: Colors.transparent,
                  color: theme.colorScheme.primary,
                ),

              // 主体 WebView 容器
              Expanded(
                child: WebViewWidget(controller: _controller),
              ),
            ],
          ),

          // 底部悬浮毛玻璃操作胶囊 (Floating Action Dock)
          Positioned(
            left: 20,
            right: 20,
            bottom: 24,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface.withValues(alpha: 0.90),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '网页端登录完成将自动进入',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                          ),
                        ),
                      ),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        ),
                        onPressed: _isProcessingLogin ? null : () => _checkAndExtract(isManual: true),
                        icon: _isProcessingLogin
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.arrow_forward_rounded, size: 16),
                        label: const Text('已登录？点此进入', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // 核心亮点：全屏高级毛玻璃遮罩——当登录完成跳转或遭遇403时立即升起，彻底遮盖丑陋的403网页，无感秒级完成设备同步！
          if (_isProcessingLogin)
            Container(
              color: Colors.black.withValues(alpha: 0.4),
              child: Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 26),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface.withValues(alpha: 0.96),
                        borderRadius: BorderRadius.circular(22),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.15),
                            blurRadius: 30,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(
                            color: theme.colorScheme.primary,
                            strokeWidth: 3,
                          ),
                          const SizedBox(height: 18),
                          const Text(
                            '登录成功！正在同步插座设备...',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '已捕获认证凭据，即将自动进入控制台',
                            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                          ),
                        ],
                      ),
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
