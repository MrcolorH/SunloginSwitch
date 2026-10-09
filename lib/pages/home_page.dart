import 'dart:async';
import 'package:flutter/material.dart';
import '../models/plug_models.dart';
import '../services/storage_service.dart';
import '../services/sunlogin_service.dart';
import '../widgets/energy_chart_sheet.dart';
import '../widgets/timer_workflow_sheet.dart';
import 'login_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final SunloginService _service = SunloginService();

  String? _sn;
  String? _deviceName;

  bool _isOpen = false;
  PlugElectric _electric = const PlugElectric();
  PlugEnergyStats _energyStats = PlugEnergyStats();
  bool _hasTimer = false;

  bool _isLoading = false;
  bool _isSwitching = false;
  Timer? _pollingTimer;

  // 智能充饱断电计时追踪
  int _lowPowerDurationSeconds = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkInitAndLoad();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollingTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 仅当当前 HomePage 处于最顶层可见页面且已成功登录绑定时才触发前台刷新
      // 绝不在上面打开了 LoginPage 时刷新，避免切回 App 时误触发未登录拦截
      final isCurrent = ModalRoute.of(context)?.isCurrent ?? false;
      if (isCurrent && _sn != null && _sn!.isNotEmpty && StorageService.token != null && StorageService.token!.isNotEmpty) {
        _refreshAllData();
        _startPolling();
      }
    } else if (state == AppLifecycleState.paused) {
      _pollingTimer?.cancel();
    }
  }

  Future<void> _checkInitAndLoad() async {
    _sn = StorageService.selectedSn;
    _deviceName = StorageService.selectedName ?? '向日葵智能插座';

    if (_sn == null || _sn!.isEmpty) {
      // 首次未选择设备，跳转登录与选择页
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final res = await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const LoginPage()),
        );
        if (res == true) {
          _checkInitAndLoad();
        }
      });
      return;
    }

    await _refreshAllData();
    _startPolling();
  }

  void _startPolling() {
    _pollingTimer?.cancel();
    // 每 15 秒轮询一次实时功率与状态
    _pollingTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted && _sn != null && !_isSwitching) {
        _pollRealtimeData();
      }
    });
  }

  /// 静默拉取实时功率和开关状态（用于轮询与智能工作流检查）
  Future<void> _pollRealtimeData() async {
    if (_sn == null) return;
    try {
      final status = await _service.getSwitchStatus(_sn!);
      final electric = await _service.getRealtimeElectric(_sn!);
      if (mounted) {
        setState(() {
          // 双因子校验：若实际功率 > 0.5W，说明有电器在通电工作，开关必然为开；
          // 否则采用云端返回的继电器状态，杜绝云端缓存延迟导致的误判为关。
          _isOpen = (electric.power > 0.5) ? true : status;
          _electric = electric;
        });
      }

      // 智能工作流逻辑：充饱自动断电
      final workflow = StorageService.getWorkflowConfig();
      if (workflow.autoPowerOffEnabled && _isOpen) {
        if (_electric.power > 0 && _electric.power <= workflow.thresholdWatts) {
          _lowPowerDurationSeconds += 15;
          if (_lowPowerDurationSeconds >= workflow.durationMinutes * 60) {
            // 触发自动断电
            _lowPowerDurationSeconds = 0;
            await _service.setSwitchStatus(_sn!, false);
            if (mounted) {
              setState(() => _isOpen = false);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已触发智能断电保护：设备已充满，插座已自动关闭')),
              );
            }
          }
        } else {
          _lowPowerDurationSeconds = 0;
        }
      }
    } catch (_) {}
  }

  /// 全量刷新（状态、实时电参数、历史用电统计、定时任务）
  Future<void> _refreshAllData() async {
    if (_sn == null) return;
    setState(() => _isLoading = true);

    try {
      final statusFuture = _service.getSwitchStatus(_sn!);
      final electricFuture = _service.getRealtimeElectric(_sn!);
      final energyFuture = _service.getEnergyStats(_sn!);
      final timerFuture = _service.hasActiveTimer(_sn!);

      final results = await Future.wait([
        statusFuture,
        electricFuture,
        energyFuture,
        timerFuture,
      ]);

      if (mounted) {
        final status = results[0] as bool;
        final electric = results[1] as PlugElectric;
        setState(() {
          _isOpen = (electric.power > 0.5) ? true : status;
          _electric = electric;
          _energyStats = results[2] as PlugEnergyStats;
          _hasTimer = results[3] as bool;
        });
      }
    } catch (e) {
      if (mounted) {
        final errStr = e.toString().toLowerCase();
        if (errStr.contains('401') || errStr.contains('403') || errStr.contains('token')) {
          _showTokenExpiredDialog();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('刷新异常: $e')));
        }
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// 切换插座开关
  Future<void> _toggleSwitch() async {
    if (_sn == null || _isSwitching) return;
    final target = !_isOpen;
    setState(() => _isSwitching = true);

    try {
      await _service.setSwitchStatus(_sn!, target);
      if (mounted) {
        setState(() {
          _isOpen = target;
          if (!target) {
            _electric = const PlugElectric(power: 0, voltage: 220, current: 0);
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(target ? '插座已开启' : '插座已关闭'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
      // 切换后延迟 2 秒拉取最新功耗与校验，给向日葵云端服务器与硬件充分的上报同步时间
      Future.delayed(const Duration(milliseconds: 2000), () {
        if (mounted && !_isSwitching) _pollRealtimeData();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('控制失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _isSwitching = false);
    }
  }

  bool _isShowingExpiredDialog = false;

  void _showTokenExpiredDialog() {
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false) || _isShowingExpiredDialog) return;
    _isShowingExpiredDialog = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange),
            SizedBox(width: 8),
            Text('登录状态失效'),
          ],
        ),
        content: const Text('向日葵登录凭证已过期，请重新扫码或登录以恢复控制。'),
        actions: [
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _openDeviceSelector();
            },
            child: const Text('重新登录'),
          ),
        ],
      ),
    ).then((_) => _isShowingExpiredDialog = false);
  }

  void _openDeviceSelector() async {
    final res = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage(isSwitchDevice: true)),
    );
    if (res == true) {
      _checkInitAndLoad();
    }
  }

  void _logoutAndRelogin() async {
    await StorageService.clearAll();
    _service.setToken(null);
    if (mounted) {
      final res = await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const LoginPage(isSwitchDevice: false)),
      );
      if (res == true) {
        _checkInitAndLoad();
      }
    }
  }

  void _openEnergyDetails() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => EnergyChartSheet(stats: _energyStats),
    );
  }

  void _openTimerWorkflow() {
    if (_sn == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => TimerWorkflowSheet(
        sn: _sn!,
        onUpdated: _refreshAllData,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: _openDeviceSelector,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    _deviceName ?? '向日葵插座',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                ),
                const Icon(Icons.arrow_drop_down),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: _isLoading
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            tooltip: '刷新状态',
            onPressed: _isLoading ? null : _refreshAllData,
          ),
          PopupMenuButton<String>(
            onSelected: (val) {
              if (val == 'switch') {
                _openDeviceSelector();
              } else if (val == 'relogin') {
                _logoutAndRelogin();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'switch',
                child: Row(
                  children: [
                    Icon(Icons.devices, size: 20),
                    SizedBox(width: 10),
                    Text('切换插座设备'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'relogin',
                child: Row(
                  children: [
                    Icon(Icons.logout, size: 20),
                    SizedBox(width: 10),
                    Text('切换账号 / 退出登录'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshAllData,
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: [
            // 1. 设备 SN 与定时状态 Chip
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _isOpen ? Colors.green : Colors.grey,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'SN: ${_sn ?? "未连接"}',
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                    ),
                  ],
                ),
                ActionChip(
                  avatar: Icon(
                    _hasTimer ? Icons.timer : Icons.timer_outlined,
                    size: 16,
                    color: _hasTimer ? Colors.blue : Colors.grey,
                  ),
                  label: Text(
                    _hasTimer ? '定时任务生效中' : '设置定时/工作流',
                    style: TextStyle(
                      fontSize: 12,
                      color: _hasTimer ? Colors.blue.shade800 : Colors.grey.shade800,
                      fontWeight: _hasTimer ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  backgroundColor: _hasTimer ? Colors.blue.shade50 : (isDark ? Colors.grey.shade800 : Colors.grey.shade100),
                  onPressed: _openTimerWorkflow,
                ),
              ],
            ),
            const SizedBox(height: 36),

            // 2. 巨型中央开关按钮
            Center(
              child: GestureDetector(
                onTap: _toggleSwitch,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: 190,
                  height: 190,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: _isOpen
                          ? [Colors.green.shade400, Colors.green.shade700]
                          : [Colors.grey.shade300, Colors.grey.shade500],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: (_isOpen ? Colors.green : Colors.grey).withValues(alpha: 0.35),
                        blurRadius: 28,
                        spreadRadius: 6,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Center(
                    child: _isSwitching
                        ? const CircularProgressIndicator(color: Colors.white, strokeWidth: 3)
                        : Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.power_settings_new, size: 68, color: Colors.white),
                              const SizedBox(height: 8),
                              Text(
                                _isOpen ? '已开启' : '已关闭',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.5,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 40),

            // 3. 实时电参数面板（功率、电压、电流）
            Card(
              elevation: 1,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildElectricItem(
                      label: '实时功率',
                      value: '${_electric.power}',
                      unit: 'W',
                      icon: Icons.bolt,
                      color: _isOpen ? Colors.amber.shade700 : Colors.grey,
                    ),
                    Container(height: 36, width: 1, color: Colors.grey.withValues(alpha: 0.2)),
                    _buildElectricItem(
                      label: '当前电压',
                      value: '${_electric.voltage}',
                      unit: 'V',
                      icon: Icons.speed,
                      color: Colors.blue.shade600,
                    ),
                    Container(height: 36, width: 1, color: Colors.grey.withValues(alpha: 0.2)),
                    _buildElectricItem(
                      label: '实时电流',
                      value: '${_electric.current}',
                      unit: 'A',
                      icon: Icons.electric_meter,
                      color: Colors.teal.shade600,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // 4. 电量统计概览（今日、本周、本月）带详情入口
            InkWell(
              onTap: _openEnergyDetails,
              borderRadius: BorderRadius.circular(20),
              child: Card(
                elevation: 1,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.bar_chart, color: theme.colorScheme.primary, size: 22),
                              const SizedBox(width: 8),
                              const Text('电量统计概览', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                            ],
                          ),
                          Row(
                            children: [
                              Text('趋势与明细', style: TextStyle(color: theme.colorScheme.primary, fontSize: 13)),
                              Icon(Icons.chevron_right, size: 18, color: theme.colorScheme.primary),
                            ],
                          ),
                        ],
                      ),
                      const Divider(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _buildEnergyItem('今日用电', '${_energyStats.todayKWh}', '度'),
                          _buildEnergyItem('本周用电', '${_energyStats.weekKWh}', '度'),
                          _buildEnergyItem('本月用电', '${_energyStats.monthKWh}', '度'),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // 5. 快捷工作流入口卡片
            Card(
              elevation: 1,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              child: ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.purple.shade50,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.auto_awesome, color: Colors.purple.shade700),
                ),
                title: const Text('定时开关与智能工作流', style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: const Text('支持定时、倒计时及手机/电瓶车充饱自动断电保护'),
                trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                onTap: _openTimerWorkflow,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildElectricItem({
    required String label,
    required String value,
    required String unit,
    required IconData icon,
    required Color color,
  }) {
    return Column(
      children: [
        Icon(icon, color: color, size: 26),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(width: 2),
            Text(unit, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }

  Widget _buildEnergyItem(String label, String value, String unit) {
    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(width: 2),
            Text(unit, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}
