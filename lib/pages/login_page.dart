import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../models/plug_models.dart';
import '../services/storage_service.dart';
import '../services/sunlogin_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'web_login_page.dart';

class LoginPage extends StatefulWidget {
  final bool isSwitchDevice;

  const LoginPage({super.key, this.isSwitchDevice = false});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late TabController _tabController;
  final _manualSnController = TextEditingController();
  final _deviceNameController = TextEditingController();
  final _tokenController = TextEditingController();
  final _service = SunloginService();

  bool _isLoading = false;
  List<SunloginDevice> _devices = [];
  late bool _hasLoggedIn;

  // 扫码相关
  final GlobalKey _qrImageBoundaryKey = GlobalKey();
  String _qrKey = '';
  String _qrData = '';
  bool _isQrLoading = false;
  int _qrStatus = 0; // 0=等待扫码, 1=已扫码待确认, 2=已确认, 3=已过期
  Timer? _qrPollingTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 3, vsync: this);
    _manualSnController.text = StorageService.selectedSn ?? '';
    _deviceNameController.text = StorageService.selectedName ?? '向日葵智能插座';
    _tokenController.text = StorageService.token ?? '';

    final canDirectToDeviceList = widget.isSwitchDevice || (StorageService.token != null && StorageService.token!.isNotEmpty);
    _hasLoggedIn = canDirectToDeviceList;

    if (canDirectToDeviceList) {
      _fetchDeviceList();
    } else {
      _startQrLogin();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _qrPollingTimer?.cancel();
    _tabController.dispose();
    _manualSnController.dispose();
    _deviceNameController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 用户从外部浏览器或微信切回时，立即主动检测是否有认证信息
      _checkExternalAuthOnResume();
    }
  }

  // 从外部浏览器切回时，立即自动检测认证信息
  Future<void> _checkExternalAuthOnResume({bool isManual = false}) async {
    if (_hasLoggedIn || !mounted) return;

    // 1. 自动检查剪贴板：若复制了 Token，直接自动登入
    try {
      final clip = await Clipboard.getData(Clipboard.kTextPlain);
      final text = clip?.text?.trim() ?? '';
      if (text.length > 20 && !text.startsWith('http') && !text.contains(' ')) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('检测到剪贴板中含有访问凭据，正在尝试自动登入...')),
          );
        }
        await _service.loginWithDirectToken(text, '剪贴板凭据登录');
        await _fetchDeviceList();
        return;
      }
    } catch (_) {}

    // 2. 检测向日葵授权会话（若有活跃授权码）
    if (_qrKey.isNotEmpty && _qrStatus != 2) {
      await _processQrCheck(isManual: isManual);
      return;
    }

    if (isManual && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已完成外部浏览器检测。若已获取 Access Token，可复制后切回 App 自动登入，或直接使用上方【内置极速登录】。'),
          duration: Duration(seconds: 4),
        ),
      );
    }
  }

  // 获取扫码登录二维码
  Future<void> _startQrLogin() async {
    _qrPollingTimer?.cancel();
    setState(() {
      _isQrLoading = true;
      _qrStatus = 0;
    });

    try {
      final res = await _service.applyQrCode();
      setState(() {
        _qrKey = res['key'] ?? '';
        _qrData = res['qrdata'] ?? '';
        _isQrLoading = false;
      });

      // 每 2 秒轮询一次扫码状态
      _qrPollingTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
        if (!mounted || _qrKey.isEmpty) return;
        await _processQrCheck(isManual: false);
      });
    } catch (e) {
      if (mounted) {
        setState(() => _isQrLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('获取二维码失败: $e')));
      }
    }
  }

  // 统一的检查并登录逻辑
  Future<void> _processQrCheck({bool isManual = false}) async {
    if (_qrKey.isEmpty) return;
    try {
      final checkResult = await _service.checkQrStatus(_qrKey);
      final int status = checkResult['status'] ?? 0;
      final String? secret = checkResult['secret'];

      if (!mounted) return;
      setState(() => _qrStatus = status);

      if (status == 2) {
        // 授权成功，使用 secret 或 qrKey 换取 token
        _qrPollingTimer?.cancel();
        setState(() => _isLoading = true);
        final secretToUse = (secret != null && secret.isNotEmpty) ? secret : _qrKey;
        await _service.confirmQrLogin(secretToUse);
        await _fetchDeviceList();
      } else if (status == 3) {
        _qrPollingTimer?.cancel();
        if (isManual && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('二维码已过期，请点击刷新')));
        }
      } else if (isManual && mounted) {
        if (status == 1) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('检测到已扫码，请在手机上点击【允许/确认登录】按钮')));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('尚未检测到手机端授权确认，请先使用微信扫码并点击确认')));
        }
      }
    } catch (e) {
      if (mounted) {
        if (_qrStatus == 2 || isManual) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('扫码授权异常: $e')));
        }
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _fetchDeviceList() async {
    setState(() => _isLoading = true);
    try {
      final list = await _service.getDeviceList();
      setState(() {
        _devices = list;
        _hasLoggedIn = true;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('获取设备列表失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleTokenLogin() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请粘贴有效的 Access Token')));
      return;
    }

    setState(() => _isLoading = true);
    try {
      await _service.loginWithDirectToken(token);
      final list = await _service.getDeviceList();
      setState(() {
        _devices = list;
        _hasLoggedIn = true;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Token 无效或已过期: $e')));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _selectDevice(SunloginDevice device) async {
    await StorageService.saveSelectedDevice(device.sn, device.name);
    if (mounted) {
      Navigator.pop(context, true);
    }
  }

  Future<void> _saveManualSn() async {
    final sn = _manualSnController.text.trim();
    if (sn.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请输入插座设备 SN 序列号')));
      return;
    }
    final name = _deviceNameController.text.trim().isEmpty
        ? '向日葵插座 ($sn)'
        : _deviceNameController.text.trim();
    final customToken = _tokenController.text.trim();
    if (customToken.isNotEmpty) {
      _service.setToken(customToken);
    }
    await StorageService.saveSelectedDevice(sn, name);
    if (mounted) {
      Navigator.pop(context, true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_hasLoggedIn ? '选择插座设备' : '向日葵登录授权'),
      ),
      body: SafeArea(
        child: _hasLoggedIn ? _buildDeviceList(theme) : _buildLoginOptions(theme),
      ),
    );
  }

  Widget _buildLoginOptions(ThemeData theme) {
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '网页登录 (推荐)'),
            Tab(text: '双机扫码登录'),
            Tab(text: '设备 SN 码登录'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildWebLoginTab(theme),
              _buildQrLoginTab(theme),
              _buildSnLoginTab(theme),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _openWebLogin([String? url, String? title]) async {
    final result = await Navigator.push<dynamic>(
      context,
      MaterialPageRoute(
        builder: (_) => WebLoginPage(
          initialUrl: url,
          initialRouteTitle: title,
        ),
      ),
    );
    if (result == true && mounted) {
      _qrPollingTimer?.cancel();
      await _fetchDeviceList();
    } else if (result == 'switchToQr' && mounted) {
      _tabController.animateTo(1);
      _startQrLogin();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已为您切换至双机扫码登录，使用另一设备或电脑扫码更稳定快捷'),
          duration: Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _launchExternalBrowser(String url, String title) async {
    final uri = Uri.parse(url);
    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (launched && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已调起外部浏览器访问【$title】\n登录完成后切回本 App 即可自动检测！'),
            duration: const Duration(seconds: 4),
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

  // 1. 独立 Tab：官方网页免扫码登录 (包含多线路切换)
  Widget _buildWebLoginTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      children: [
        // 核心卡片：内置极速免扫码登录
        Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.35),
              width: 1.2,
            ),
          ),
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.language_rounded, color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '内置免扫码登录 (最推荐)',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '单台手机首选 · 支持验证码/密码 · 自动同步',
                          style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                '在 App 内直接打开贝锐向日葵认证中心，输入短信验证码或密码拼图，登录成功后 App 自动捕获凭据秒进控制台，免切屏烦恼！',
                style: TextStyle(fontSize: 12.5, height: 1.45, color: theme.colorScheme.onSurface.withValues(alpha: 0.85)),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: FilledButton.icon(
                  onPressed: () => _openWebLogin(),
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.open_in_browser_rounded, size: 19),
                  label: const Text('立即开始内置登录', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 20),

        // 分割线与说明
        Row(
          children: [
            const Expanded(child: Divider()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                '切换登录线路 (直达或外部浏览器)',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontWeight: FontWeight.bold),
              ),
            ),
            const Expanded(child: Divider()),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '点击卡片在 App 内置打开该线路；点击右侧 ↗ 图标直接调起手机默认浏览器：',
          style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600, height: 1.4),
        ),
        const SizedBox(height: 12),

        // 线路一
        _buildLoginRouteCard(
          theme: theme,
          title: '线路一：贝锐统一通行证 (推荐)',
          subtitle: '官方移动端统一登录页面，支持手机验证码/密码',
          icon: Icons.verified_user_rounded,
          url: 'https://passport.oray.com/login/',
        ),
        const SizedBox(height: 10),

        // 线路二
        _buildLoginRouteCard(
          theme: theme,
          title: '线路二：向日葵管理中心',
          subtitle: '向日葵专属后台登录入口，适配远控设备',
          icon: Icons.devices_rounded,
          url: 'https://sunlogin.oray.com/passport/login',
        ),
        const SizedBox(height: 10),

        // 线路三
        _buildLoginRouteCard(
          theme: theme,
          title: '线路三：贝锐标准控制台',
          subtitle: '贝锐全业务控制中心直连登录入口',
          icon: Icons.admin_panel_settings_rounded,
          url: 'https://console.oray.com/passport/login',
        ),

        const SizedBox(height: 16),

        // 切回检测提示与操作
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.sync_rounded, color: theme.colorScheme.primary, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '已在外部浏览器登录完成？',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '在外部浏览器登录完成后切回本 App 即可自动尝试检测；若未自动触发，可点击下方按钮：',
                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700, height: 1.4),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _checkExternalAuthOnResume(isManual: true),
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('立即手动检测认证信息', style: TextStyle(fontSize: 12.5)),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // 高级选填：手动粘贴 Token 折叠项
        ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 4),
          title: Text(
            '高级选填：粘贴云端 Access Token',
            style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
          ),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '若您手头已有在向日葵控制台生成的 Access Token，可直接粘贴登入：',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            ),
            TextField(
              controller: _tokenController,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Access Token',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _isLoading ? null : _handleTokenLogin,
                child: const Text('验证该 Token 并进入'),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ],
    );
  }

  // 线路卡片组件
  Widget _buildLoginRouteCard({
    required ThemeData theme,
    required String title,
    required String subtitle,
    required IconData icon,
    required String url,
  }) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openWebLogin(url, title),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: theme.colorScheme.primary, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                tooltip: '在系统浏览器中打开',
                onPressed: () => _launchExternalBrowser(url, title),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 2. 独立 Tab：双机二维码登录
  Widget _buildQrLoginTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      children: [
        Text(
          '有电脑或另一部手机时，使用向日葵 App 或微信扫一扫即可授权：',
          style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700, height: 1.4),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 18),

        // 模块二：双机二维码登录
        Center(
          child: RepaintBoundary(
            key: _qrImageBoundaryKey,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: _isQrLoading
                  ? const SizedBox(
                      width: 180,
                      height: 180,
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : _qrData.isNotEmpty
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            QrImageView(
                              data: _qrData,
                              version: QrVersions.auto,
                              size: 180.0,
                              backgroundColor: Colors.white,
                            ),
                            const SizedBox(height: 6),
                            if (_qrStatus == 1)
                              const Text('已扫码！请在手机点击【确认登录】', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 12))
                            else if (_qrStatus == 3)
                              TextButton.icon(
                                onPressed: _startQrLogin,
                                icon: const Icon(Icons.refresh, size: 16),
                                label: const Text('二维码已过期，点击刷新', style: TextStyle(fontSize: 12)),
                              )
                            else
                              const Text('有电脑或另一部手机时，可直接扫码授权', style: TextStyle(color: Colors.grey, fontSize: 11)),
                          ],
                        )
                      : TextButton.icon(
                          onPressed: _startQrLogin,
                          icon: const Icon(Icons.refresh),
                          label: const Text('点击获取二维码'),
                        ),
            ),
          ),
        ),

        const SizedBox(height: 14),

        // 状态卡片
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: _qrStatus == 1
                ? Colors.green.withValues(alpha: 0.1)
                : (_qrStatus == 2 ? Colors.blue.withValues(alpha: 0.1) : Colors.grey.withValues(alpha: 0.06)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _qrStatus == 1 ? Icons.check_circle : (_qrStatus == 2 ? Icons.hourglass_top : Icons.info_outline),
                size: 18,
                color: _qrStatus == 1 ? Colors.green : (_qrStatus == 2 ? Colors.blue : Colors.grey),
              ),
              const SizedBox(width: 8),
              Text(
                _qrStatus == 1
                    ? '已扫码，请在手机上确认...'
                    : (_qrStatus == 2 ? '授权成功，正在同步设备...' : '等待扫码授权中...'),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: _qrStatus == 1 ? Colors.green.shade800 : (_qrStatus == 2 ? Colors.blue.shade800 : Colors.grey.shade700),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 10),

        // 刷新与手动进入按钮
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton.icon(
              onPressed: _startQrLogin,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('刷新二维码', style: TextStyle(fontSize: 12)),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: () => _processQrCheck(isManual: true),
              icon: const Icon(Icons.login_rounded, size: 16),
              label: const Text('我已扫码确认', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ],
    );
  }

  // 2. 设备 SN 码登录 Tab
  Widget _buildSnLoginTab(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.2)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.qr_code_scanner, color: theme.colorScheme.primary, size: 24),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '免账号密码直连控制',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                    SizedBox(height: 4),
                    Text(
                      '输入向日葵智能插座机身上的 12 位 SN 序列号（可在插座背面或包装盒上查看），即可直接绑定并控制开/关。',
                      style: TextStyle(fontSize: 12, color: Colors.grey, height: 1.4),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),

        TextField(
          controller: _manualSnController,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: '设备 SN 序列号 (必填)',
            hintText: '例如: ABC123456789',
            prefixIcon: Icon(Icons.qr_code),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),

        TextField(
          controller: _deviceNameController,
          decoration: const InputDecoration(
            labelText: '插座备注名称 (选填)',
            hintText: '例如: 电脑主机、客厅鱼缸',
            prefixIcon: Icon(Icons.drive_file_rename_outline),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 24),

        SizedBox(
          height: 50,
          child: FilledButton.icon(
            onPressed: _isLoading ? null : _saveManualSn,
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('保存 SN 码并进入主控制页', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ),

        const SizedBox(height: 28),
        const Divider(),
        const SizedBox(height: 12),

        // 选填高级凭证
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('高级选填：粘贴云端 Access Token', style: TextStyle(fontSize: 13, color: Colors.grey)),
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                '若需同步云端定时与月度历史用电账单，可粘贴从网页控制台复制的 Access Token：',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
            TextField(
              controller: _tokenController,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Access Token (选填)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            if (_tokenController.text.isNotEmpty)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _isLoading ? null : _handleTokenLogin,
                  child: const Text('验证该 Token 并获取设备'),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ],
    );
  }

  // 设备列表页
  Widget _buildDeviceList(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          '请选择要控制的向日葵插座：',
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        if (_isLoading)
          const Padding(
            padding: EdgeInsets.all(48),
            child: Center(
              child: Column(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('正在加载设备列表...', style: TextStyle(color: Colors.grey)),
                ],
              ),
            ),
          )
        else if (_devices.isEmpty)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text('账号下未找到可用插座设备，请确认是否已在向日葵 App 中绑定该插座'),
            ),
          )
        else
          ..._devices.map((device) {
            final isSelected = StorageService.selectedSn == device.sn;
            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              elevation: isSelected ? 4 : 1,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: isSelected ? theme.colorScheme.primary : Colors.transparent,
                  width: 2,
                ),
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                leading: CircleAvatar(
                  backgroundColor: device.isOnline ? Colors.green.shade100 : Colors.grey.shade200,
                  child: Icon(
                    Icons.power,
                    color: device.isOnline ? Colors.green.shade700 : Colors.grey,
                  ),
                ),
                title: Text(device.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 2),
                    Text('型号: ${device.model}   SN: ${device.sn}', style: const TextStyle(fontSize: 12)),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: device.isOnline ? Colors.green : Colors.grey,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          device.isOnline ? '在线 (可控制)' : '离线',
                          style: TextStyle(
                            fontSize: 12,
                            color: device.isOnline ? Colors.green.shade700 : Colors.grey,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                trailing: isSelected
                    ? Icon(Icons.check_circle, color: theme.colorScheme.primary)
                    : const Icon(Icons.arrow_forward_ios, size: 16),
                onTap: () => _selectDevice(device),
              ),
            );
          }),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: () {
            setState(() => _hasLoggedIn = false);
            _startQrLogin();
          },
          icon: const Icon(Icons.logout),
          label: const Text('切换账号 / 重新登录'),
        ),
      ],
    );
  }
}
