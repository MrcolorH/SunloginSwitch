import 'package:flutter/material.dart';
import '../models/plug_models.dart';
import '../services/storage_service.dart';
import '../services/sunlogin_service.dart';

class TimerWorkflowSheet extends StatefulWidget {
  final String sn;
  final VoidCallback onUpdated;

  const TimerWorkflowSheet({
    super.key,
    required this.sn,
    required this.onUpdated,
  });

  @override
  State<TimerWorkflowSheet> createState() => _TimerWorkflowSheetState();
}

class _TimerWorkflowSheetState extends State<TimerWorkflowSheet> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final SunloginService _service = SunloginService();

  List<PlugTimerItem> _timers = [];
  int _countdownRemain = 0;
  bool _isLoading = false;

  late SmartWorkflowConfig _workflowConfig;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _workflowConfig = StorageService.getWorkflowConfig();
    _fetchTimers();
  }

  Future<void> _fetchTimers() async {
    setState(() => _isLoading = true);
    try {
      final list = await _service.getTimers(widget.sn);
      final cd = await _service.getCountdown(widget.sn);
      if (mounted) {
        setState(() {
          _timers = list;
          _countdownRemain = cd;
        });
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _setCountdown(int minutes, int action) async {
    setState(() => _isLoading = true);
    try {
      await _service.setCountdown(widget.sn, seconds: minutes * 60, action: action);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已设置 $minutes 分钟后${action == 1 ? "开启" : "关闭"}')),
        );
      }
      widget.onUpdated();
      _fetchTimers();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('设置失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _showAddTimerDialog() async {
    TimeOfDay selectedTime = TimeOfDay.now();
    int action = 0; // 0=关, 1=开
    int repeat = 127; // 127=每天

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) {
          return AlertDialog(
            title: const Text('添加硬件定时任务'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: const Text('执行时间'),
                  trailing: Text(
                    '${selectedTime.hour.toString().padLeft(2, '0')}:${selectedTime.minute.toString().padLeft(2, '0')}',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  onTap: () async {
                    final t = await showTimePicker(context: context, initialTime: selectedTime);
                    if (t != null) {
                      setDlgState(() => selectedTime = t);
                    }
                  },
                ),
                const Divider(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('动作'),
                    SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(value: 1, label: Text('开启')),
                        ButtonSegment(value: 0, label: Text('关闭')),
                      ],
                      selected: {action},
                      onSelectionChanged: (s) => setDlgState(() => action = s.first),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('重复'),
                    DropdownButton<int>(
                      value: repeat,
                      items: const [
                        DropdownMenuItem(value: 127, child: Text('每天')),
                        DropdownMenuItem(value: 62, child: Text('工作日')),
                        DropdownMenuItem(value: 65, child: Text('周末')),
                        DropdownMenuItem(value: 0, child: Text('仅一次')),
                      ],
                      onChanged: (v) {
                        if (v != null) setDlgState(() => repeat = v);
                      },
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
              FilledButton(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  Navigator.pop(ctx);
                  final timeMinutes = selectedTime.hour * 60 + selectedTime.minute;
                  try {
                    await _service.addTimer(
                      widget.sn,
                      timeMinutes: timeMinutes,
                      action: action,
                      repeat: repeat,
                    );
                    widget.onUpdated();
                    _fetchTimers();
                  } catch (e) {
                    if (mounted) {
                      messenger.showSnackBar(SnackBar(content: Text('添加失败: $e')));
                    }
                  }
                },
                child: const Text('确定保存'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('定时与自动化工作流', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                    IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                  ],
                ),
              ),
              TabBar(
                controller: _tabController,
                tabs: const [
                  Tab(text: '云端定时 & 倒计时'),
                  Tab(text: '智能工作流'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    // Tab 1: 云端硬件定时
                    _buildCloudTimerTab(scrollController),
                    // Tab 2: 智能工作流
                    _buildWorkflowTab(scrollController),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCloudTimerTab(ScrollController controller) {
    return ListView(
      controller: controller,
      padding: const EdgeInsets.all(20),
      children: [
        // 倒计时快捷按钮卡片
        Text('快捷倒计时关机', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _buildCountdownChip(15, '15 分钟后关'),
            _buildCountdownChip(30, '30 分钟后关'),
            _buildCountdownChip(60, '1 小时后关'),
            _buildCountdownChip(120, '2 小时后关'),
          ],
        ),
        if (_countdownRemain > 0) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.amber.shade400),
            ),
            child: Row(
              children: [
                const Icon(Icons.timer, color: Colors.amber, size: 20),
                const SizedBox(width: 8),
                Text(
                  '当前生效倒计时: 约 ${(_countdownRemain / 60).ceil()} 分钟后动作',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),

        // 硬件定时列表
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('云端定时列表', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            FilledButton.tonalIcon(
              onPressed: _showAddTimerDialog,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加定时'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_isLoading)
          const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator()))
        else if (_timers.isEmpty)
          Container(
            padding: const EdgeInsets.all(24),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Text('暂无定时任务，插座断网时云端定时依然在插座本地生效', style: TextStyle(color: Colors.grey, fontSize: 13)),
          )
        else
          ..._timers.map((t) {
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: t.action == 1 ? Colors.green.shade100 : Colors.red.shade100,
                  child: Icon(
                    t.action == 1 ? Icons.power : Icons.power_off,
                    color: t.action == 1 ? Colors.green : Colors.red,
                  ),
                ),
                title: Text(
                  '${t.timeFormatted} 执行 ${t.action == 1 ? "开启" : "关闭"}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text('重复: ${t.repeatSummary}'),
                trailing: Chip(
                  label: Text(t.enable ? '已启用' : '已停用'),
                  backgroundColor: t.enable ? Colors.green.shade50 : Colors.grey.shade100,
                ),
              ),
            );
          }),
      ],
    );
  }

  Widget _buildCountdownChip(int minutes, String label) {
    return ActionChip(
      avatar: const Icon(Icons.alarm, size: 16),
      label: Text(label),
      onPressed: () => _setCountdown(minutes, 0),
    );
  }

  Widget _buildWorkflowTab(ScrollController controller) {
    return ListView(
      controller: controller,
      padding: const EdgeInsets.all(20),
      children: [
        // 充饱断电工作流
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.battery_charging_full, color: Colors.green),
                        SizedBox(width: 8),
                        Text('智能充饱断电保护', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      ],
                    ),
                    Switch(
                      value: _workflowConfig.autoPowerOffEnabled,
                      onChanged: (val) {
                        setState(() {
                          _workflowConfig.autoPowerOffEnabled = val;
                          StorageService.saveWorkflowConfig(_workflowConfig);
                        });
                        widget.onUpdated();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '当设备（如手机、电瓶车充电器）充满进入微弱浮充时，自动向插座下发关机指令，保护电池寿命与用电安全。',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                ),
                const Divider(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('触发低功率阈值 (W)'),
                    Text('${_workflowConfig.thresholdWatts} W', style: const TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
                Slider(
                  value: _workflowConfig.thresholdWatts,
                  min: 1.0,
                  max: 20.0,
                  divisions: 19,
                  label: '${_workflowConfig.thresholdWatts}W',
                  onChanged: _workflowConfig.autoPowerOffEnabled
                      ? (v) {
                          setState(() {
                            _workflowConfig.thresholdWatts = v;
                            StorageService.saveWorkflowConfig(_workflowConfig);
                          });
                        }
                      : null,
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('低功率持续时间 (分钟)'),
                    Text('${_workflowConfig.durationMinutes} 分钟', style: const TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
                Slider(
                  value: _workflowConfig.durationMinutes.toDouble(),
                  min: 1.0,
                  max: 30.0,
                  divisions: 29,
                  label: '${_workflowConfig.durationMinutes}分钟',
                  onChanged: _workflowConfig.autoPowerOffEnabled
                      ? (v) {
                          setState(() {
                            _workflowConfig.durationMinutes = v.toInt();
                            StorageService.saveWorkflowConfig(_workflowConfig);
                          });
                        }
                      : null,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
