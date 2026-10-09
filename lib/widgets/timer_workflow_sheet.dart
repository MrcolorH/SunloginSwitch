import 'package:flutter/material.dart';
import '../models/plug_models.dart';
import '../services/local_timer_service.dart';
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

class _TimerWorkflowSheetState extends State<TimerWorkflowSheet>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final SunloginService _service = SunloginService();
  final LocalTimerService _localTimer = LocalTimerService.instance;

  // 云端定时备用状态
  List<PlugTimerItem> _cloudTimers = [];
  int _cloudCountdownRemain = 0;
  bool _isLoadingCloud = false;

  late SmartWorkflowConfig _workflowConfig;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _workflowConfig = StorageService.getWorkflowConfig();
    _localTimer.addListener(_onLocalTimerChanged);
  }

  @override
  void dispose() {
    _localTimer.removeListener(_onLocalTimerChanged);
    _tabController.dispose();
    super.dispose();
  }

  void _onLocalTimerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _fetchCloudTimers() async {
    setState(() => _isLoadingCloud = true);
    try {
      final list = await _service.getTimers(widget.sn);
      final cd = await _service.getCountdown(widget.sn);
      if (mounted) {
        setState(() {
          _cloudTimers = list;
          _cloudCountdownRemain = cd;
        });
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _isLoadingCloud = false);
    }
  }

  // ====================== 本地倒计时逻辑 ======================

  Future<void> _startLocalCountdown(int minutes, int action) async {
    await _localTimer.startCountdown(
      sn: widget.sn,
      seconds: minutes * 60,
      action: action,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已开启手机本地倒计时：$minutes 分钟后自动${action == 1 ? "开启" : "关闭"}插座',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
    widget.onUpdated();
  }

  Future<void> _cancelLocalCountdown() async {
    await _localTimer.cancelCountdown(widget.sn);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已取消本地倒计时')),
      );
    }
    widget.onUpdated();
  }

  Future<void> _showCustomCountdownDialog() async {
    final controller = TextEditingController(text: '45');
    int action = 0; // 0=关, 1=开

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) {
          return AlertDialog(
            title: const Text('自定义本地倒计时'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '倒计时时长 (分钟)',
                    hintText: '例如: 45',
                    suffixText: '分钟',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('到期执行动作:'),
                    SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(value: 0, label: Text('关机')),
                        ButtonSegment(value: 1, label: Text('开机')),
                      ],
                      selected: {action},
                      onSelectionChanged: (s) =>
                          setDlgState(() => action = s.first),
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  final minutes = int.tryParse(controller.text.trim()) ?? 0;
                  if (minutes <= 0) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('请输入有效的时间（大于0分钟）')),
                    );
                    return;
                  }
                  Navigator.pop(ctx);
                  _startLocalCountdown(minutes, action);
                },
                child: const Text('启动倒计时'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ====================== 本地定时任务逻辑 ======================

  Future<void> _showAddLocalTimerDialog([LocalTimerItem? editItem]) async {
    TimeOfDay selectedTime = editItem != null
        ? TimeOfDay(hour: editItem.hour, minute: editItem.minute)
        : TimeOfDay.now();
    int action = editItem?.action ?? 0; // 0=关, 1=开
    int repeatMode = editItem?.repeat ?? 127; // 127=每天, 62=工作日, 65=周末, 0=仅一次, -1=自定义
    List<int> customDays = editItem != null
        ? List<int>.from(editItem.weekDays)
        : [1, 2, 3, 4, 5, 6, 7];
    final nameController = TextEditingController(text: editItem?.name ?? '');

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) {
          return AlertDialog(
            title: Text(editItem == null ? '添加本地定时' : '编辑本地定时'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: '任务名称 (选填)',
                      hintText: '如: 睡觉断电 / 早晨开启',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('定时时间'),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${selectedTime.hour.toString().padLeft(2, '0')}:${selectedTime.minute.toString().padLeft(2, '0')}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                          color: Theme.of(context)
                              .colorScheme
                              .onPrimaryContainer,
                        ),
                      ),
                    ),
                    onTap: () async {
                      final t = await showTimePicker(
                        context: context,
                        initialTime: selectedTime,
                      );
                      if (t != null) {
                        setDlgState(() => selectedTime = t);
                      }
                    },
                  ),
                  const Divider(),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('开关动作'),
                      SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(
                            value: 1,
                            label: Text('开启'),
                            icon: Icon(Icons.power, size: 16),
                          ),
                          ButtonSegment(
                            value: 0,
                            label: Text('关闭'),
                            icon: Icon(Icons.power_off, size: 16),
                          ),
                        ],
                        selected: {action},
                        onSelectionChanged: (s) =>
                            setDlgState(() => action = s.first),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('重复周期'),
                      DropdownButton<int>(
                        value: repeatMode,
                        items: const [
                          DropdownMenuItem(value: 127, child: Text('每天')),
                          DropdownMenuItem(value: 62, child: Text('工作日 (周一至周五)')),
                          DropdownMenuItem(value: 65, child: Text('周末 (周六日)')),
                          DropdownMenuItem(value: 0, child: Text('仅一次')),
                          DropdownMenuItem(value: -1, child: Text('自定义星期')),
                        ],
                        onChanged: (v) {
                          if (v != null) {
                            setDlgState(() {
                              repeatMode = v;
                              if (v == 127) customDays = [1, 2, 3, 4, 5, 6, 7];
                              if (v == 62) customDays = [1, 2, 3, 4, 5];
                              if (v == 65) customDays = [6, 7];
                              if (v == 0) customDays = [];
                            });
                          }
                        },
                      ),
                    ],
                  ),
                  if (repeatMode == -1) ...[
                    const SizedBox(height: 8),
                    const Text('选择执行星期：', style: TextStyle(fontSize: 12)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: List.generate(7, (idx) {
                        final day = idx + 1;
                        final label = ['一', '二', '三', '四', '五', '六', '日'][idx];
                        final isSelected = customDays.contains(day);
                        return FilterChip(
                          label: Text('周$label'),
                          selected: isSelected,
                          onSelected: (selected) {
                            setDlgState(() {
                              if (selected) {
                                customDays.add(day);
                              } else {
                                customDays.remove(day);
                              }
                            });
                          },
                        );
                      }),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () async {
                  if (repeatMode == -1 && customDays.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('请至少选择一个执行星期')),
                    );
                    return;
                  }
                  Navigator.pop(ctx);
                  final name = nameController.text.trim().isEmpty
                      ? (action == 1 ? '定时开机' : '定时关机')
                      : nameController.text.trim();

                  final item = LocalTimerItem(
                    id: editItem?.id ??
                        DateTime.now().millisecondsSinceEpoch.toString(),
                    sn: widget.sn,
                    name: name,
                    hour: selectedTime.hour,
                    minute: selectedTime.minute,
                    action: action,
                    repeat: repeatMode,
                    weekDays: repeatMode == 0 ? [] : customDays,
                    isEnabled: true,
                  );

                  if (editItem != null) {
                    await _localTimer.updateTimer(item);
                  } else {
                    await _localTimer.addTimer(item);
                  }
                  widget.onUpdated();
                },
                child: const Text('保存'),
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
      initialChildSize: 0.88,
      maxChildSize: 0.96,
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
                    Text(
                      '定时与自动化工作流',
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              TabBar(
                controller: _tabController,
                tabs: const [
                  Tab(text: '本地定时 & 倒计时'),
                  Tab(text: '智能工作流'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildLocalTimerTab(scrollController),
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

  Widget _buildLocalTimerTab(ScrollController controller) {
    final cd = _localTimer.getCountdownForDevice(widget.sn);
    final timers = _localTimer.getTimersForDevice(widget.sn);
    final theme = Theme.of(context);

    return ListView(
      controller: controller,
      padding: const EdgeInsets.all(20),
      children: [
        // 1. 本地定时模式说明提示卡
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.teal.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.teal.shade200),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.phone_android, color: Colors.teal, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '已启用手机本地调度模式',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.teal,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '到指定时间后由手机自动发起开关指令，稳定可靠。请确保手机允许本 App 在后台运行。',
                      style: TextStyle(
                        color: Colors.teal.shade800,
                        fontSize: 12,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // 2. 倒计时区域
        Text(
          '快捷倒计时',
          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),

        if (cd != null && cd.isEnabled && cd.remainingSeconds > 0) ...[
          // 正在进行中的倒计时卡片
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: cd.action == 1
                    ? [Colors.green.shade50, Colors.green.shade100]
                    : [Colors.orange.shade50, Colors.orange.shade100],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: cd.action == 1 ? Colors.green.shade300 : Colors.orange.shade300,
              ),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.timelapse,
                          color: cd.action == 1 ? Colors.green : Colors.orange,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          cd.action == 1 ? '倒计时开机进行中' : '倒计时关机进行中',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: cd.action == 1 ? Colors.green.shade900 : Colors.orange.shade900,
                          ),
                        ),
                      ],
                    ),
                    Chip(
                      label: Text(cd.action == 1 ? '到期开启' : '到期关闭'),
                      backgroundColor: cd.action == 1 ? Colors.green : Colors.orange,
                      labelStyle: const TextStyle(color: Colors.white, fontSize: 11),
                      padding: EdgeInsets.zero,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  cd.remainingFormatted,
                  style: TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2,
                    fontFamily: 'monospace',
                    color: cd.action == 1 ? Colors.green.shade900 : Colors.orange.shade900,
                  ),
                ),
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: cd.totalSeconds > 0
                      ? (cd.totalSeconds - cd.remainingSeconds) / cd.totalSeconds
                      : 0.0,
                  color: cd.action == 1 ? Colors.green : Colors.orange,
                  backgroundColor: Colors.white70,
                ),
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  onPressed: _cancelLocalCountdown,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red.shade700,
                    side: BorderSide(color: Colors.red.shade300),
                  ),
                  icon: const Icon(Icons.stop_circle_outlined, size: 18),
                  label: const Text('取消当前倒计时'),
                ),
              ],
            ),
          ),
        ] else ...[
          // 未启动倒计时：显示快捷按钮
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _buildCountdownChip(15, '15分钟后关', 0),
              _buildCountdownChip(30, '30分钟后关', 0),
              _buildCountdownChip(60, '1小时后关', 0),
              _buildCountdownChip(120, '2小时后关', 0),
              ActionChip(
                avatar: const Icon(Icons.more_time, size: 16),
                label: const Text('自定义时长...'),
                onPressed: _showCustomCountdownDialog,
              ),
            ],
          ),
        ],

        const SizedBox(height: 28),

        // 3. 本地定时任务列表
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Text(
                  '定时任务列表',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                if (timers.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '共 ${timers.length} 个',
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            FilledButton.tonalIcon(
              onPressed: () => _showAddLocalTimerDialog(),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加定时'),
            ),
          ],
        ),
        const SizedBox(height: 12),

        if (timers.isEmpty)
          Container(
            padding: const EdgeInsets.all(28),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.cardColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
            ),
            child: Column(
              children: [
                Icon(Icons.alarm_off, size: 36, color: Colors.grey.shade400),
                const SizedBox(height: 8),
                const Text(
                  '暂无本地定时任务',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  '点击上方「添加定时」，手机将在指定时间自动开关',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          )
        else
          ...timers.map((t) {
            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(
                  color: t.isEnabled
                      ? theme.colorScheme.outlineVariant
                      : Colors.grey.withValues(alpha: 0.15),
                ),
              ),
              child: ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                leading: CircleAvatar(
                  backgroundColor: !t.isEnabled
                      ? Colors.grey.shade200
                      : (t.action == 1
                          ? Colors.green.shade100
                          : Colors.red.shade100),
                  child: Icon(
                    t.action == 1 ? Icons.power : Icons.power_off,
                    color: !t.isEnabled
                        ? Colors.grey
                        : (t.action == 1 ? Colors.green : Colors.red),
                    size: 22,
                  ),
                ),
                title: Row(
                  children: [
                    Text(
                      t.timeFormatted,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 20,
                        color: t.isEnabled ? null : Colors.grey,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: t.action == 1
                            ? Colors.green.withValues(alpha: 0.15)
                            : Colors.red.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        t.action == 1 ? '开启' : '关闭',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: t.action == 1 ? Colors.green : Colors.red,
                        ),
                      ),
                    ),
                    if (t.name.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          t.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '周期: ${t.repeatSummary}',
                    style: TextStyle(
                      fontSize: 12,
                      color: t.isEnabled ? Colors.grey.shade700 : Colors.grey,
                    ),
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: t.isEnabled,
                      onChanged: (val) {
                        _localTimer.toggleTimer(t.id, val);
                        widget.onUpdated();
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline,
                          size: 20, color: Colors.grey),
                      tooltip: '删除任务',
                      onPressed: () async {
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('删除定时任务'),
                            content: Text('确定要删除 ${t.timeFormatted} 的定时任务吗？'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('取消'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('删除'),
                              ),
                            ],
                          ),
                        );
                        if (confirm == true) {
                          await _localTimer.deleteTimer(t.id);
                          widget.onUpdated();
                        }
                      },
                    ),
                  ],
                ),
                onTap: () => _showAddLocalTimerDialog(t),
              ),
            );
          }),

        const SizedBox(height: 28),

        // 4. 原厂云端定时备用折叠面板（满足对比与兼容）
        Theme(
          data: theme.copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            title: const Text(
              '原厂云端定时（不推荐）',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            subtitle: const Text(
              '部分向日葵型号云端固件定时不稳定，建议优先使用上方的本地定时',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
            onExpansionChanged: (expanded) {
              if (expanded && _cloudTimers.isEmpty) {
                _fetchCloudTimers();
              }
            },
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.cardColor,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('云端硬件任务',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        IconButton(
                          icon: _isLoadingCloud
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.refresh, size: 18),
                          onPressed: _isLoadingCloud ? null : _fetchCloudTimers,
                        ),
                      ],
                    ),
                    if (_cloudCountdownRemain > 0)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text('云端倒计时: 约 ${(_cloudCountdownRemain / 60).ceil()} 分钟'),
                      ),
                    if (_cloudTimers.isEmpty)
                      const Text('云端未返回任何硬件定时任务',
                          style: TextStyle(color: Colors.grey, fontSize: 12))
                    else
                      ..._cloudTimers.map((ct) => ListTile(
                            dense: true,
                            title: Text(
                                '${ct.timeFormatted} 执行 ${ct.action == 1 ? "开启" : "关闭"}'),
                            subtitle: Text('周期: ${ct.repeatSummary}'),
                            trailing: Text(ct.enable ? '已启用' : '已停用'),
                          )),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCountdownChip(int minutes, String label, int action) {
    return ActionChip(
      avatar: const Icon(Icons.alarm, size: 16),
      label: Text(label),
      onPressed: () => _startLocalCountdown(minutes, action),
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
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                        Text('智能充饱断电保护',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16)),
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
                    Text('${_workflowConfig.thresholdWatts} W',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
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
                    Text('${_workflowConfig.durationMinutes} 分钟',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
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
