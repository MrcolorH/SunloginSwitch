import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/plug_models.dart';
import 'storage_service.dart';
import 'sunlogin_service.dart';

/// 本地定时触发执行事件
class LocalTimerTriggerEvent {
  final String sn;
  final bool action; // true: 开启, false: 关闭
  final String title;
  final bool success;
  final String? error;
  final DateTime time;

  LocalTimerTriggerEvent({
    required this.sn,
    required this.action,
    required this.title,
    required this.success,
    this.error,
    required this.time,
  });
}

/// 手机本地定时与倒计时核心调度引擎
class LocalTimerService extends ChangeNotifier {
  static final LocalTimerService instance = LocalTimerService._internal();

  LocalTimerService._internal();

  final SunloginService _sunloginService = SunloginService();
  final StreamController<LocalTimerTriggerEvent> _eventController =
      StreamController<LocalTimerTriggerEvent>.broadcast();

  Stream<LocalTimerTriggerEvent> get eventStream => _eventController.stream;

  List<LocalTimerItem> _timers = [];
  LocalCountdownItem? _countdown;
  Timer? _ticker;

  List<LocalTimerItem> get allTimers => List.unmodifiable(_timers);
  LocalCountdownItem? get currentCountdown => _countdown;

  /// 初始化服务并启动心跳
  Future<void> init() async {
    _timers = StorageService.getLocalTimers();
    _countdown = StorageService.getLocalCountdown();

    // 如果加载时发现倒计时已经严重超时（例如超过10分钟以上且App没打开），直接清除；
    // 如果刚到期未多久，则补发触发
    if (_countdown != null && _countdown!.isEnabled) {
      if (_countdown!.remainingSeconds <= 0) {
        final overdueSeconds = (_countdown!.endTimestamp - DateTime.now().millisecondsSinceEpoch).abs() ~/ 1000;
        if (overdueSeconds < 300) {
          // 5分钟内到期的，立即补发
          _triggerCountdown();
        } else {
          // 严重过期的直接清除
          _countdown = null;
          await StorageService.saveLocalCountdown(null);
        }
      }
    }

    _ticker?.cancel();
    // 启动 1 秒心跳，驱动倒计时动态走字与到期检测
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    notifyListeners();
  }

  /// App 从后台恢复时进行快速补偿检测
  void checkCatchUp() {
    _tick();
  }

  void _tick() {
    final now = DateTime.now();
    bool stateChanged = false;

    // 1. 检查倒计时
    if (_countdown != null && _countdown!.isEnabled) {
      if (_countdown!.remainingSeconds <= 0) {
        _triggerCountdown();
        stateChanged = true;
      } else {
        // 倒计时尚在进行中，每秒通知一次 UI 刷新数字
        stateChanged = true;
      }
    }

    // 2. 检查本地定时任务
    final minuteKey =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    for (final timer in _timers) {
      if (!timer.isEnabled) continue;

      if (timer.hour == now.hour && timer.minute == now.minute) {
        // 已经在本分钟执行过，跳过
        if (timer.lastExecutedDate == minuteKey) continue;

        // 检查周期匹配
        bool shouldRun = false;
        if (timer.repeat == 0 || timer.weekDays.isEmpty) {
          shouldRun = true;
        } else if (timer.weekDays.contains(now.weekday)) {
          shouldRun = true;
        }

        if (shouldRun) {
          timer.lastExecutedDate = minuteKey;
          if (timer.repeat == 0) {
            timer.isEnabled = false; // 仅一次任务，执行完毕后自动关闭
          }
          StorageService.saveLocalTimers(_timers);
          _executeAction(
            sn: timer.sn,
            action: timer.action == 1,
            title: timer.name.isNotEmpty ? timer.name : '本地定时',
          );
          stateChanged = true;
        }
      }
    }

    if (stateChanged) {
      notifyListeners();
    }
  }

  /// 触发倒计时到期
  Future<void> _triggerCountdown() async {
    final cd = _countdown;
    if (cd == null) return;
    _countdown = null;
    await StorageService.saveLocalCountdown(null);
    notifyListeners();

    await _executeAction(
      sn: cd.sn,
      action: cd.action == 1,
      title: '本地倒计时',
    );
  }

  /// 手机下发实际开关指令
  Future<void> _executeAction({
    required String sn,
    required bool action,
    required String title,
  }) async {
    bool success = false;
    String? error;

    try {
      success = await _sunloginService.setSwitchStatus(sn, action);
      if (!success) {
        // 失败后进行一次快速重试
        await Future.delayed(const Duration(seconds: 1));
        success = await _sunloginService.setSwitchStatus(sn, action);
      }
    } catch (e) {
      try {
        // 异常后重试一次
        await Future.delayed(const Duration(seconds: 1));
        success = await _sunloginService.setSwitchStatus(sn, action);
      } catch (err) {
        error = err.toString();
        success = false;
      }
    }

    // 广播事件
    _eventController.add(LocalTimerTriggerEvent(
      sn: sn,
      action: action,
      title: title,
      success: success,
      error: error,
      time: DateTime.now(),
    ));
  }

  /// 获取指定设备的定时任务
  List<LocalTimerItem> getTimersForDevice(String sn) {
    return _timers.where((t) => t.sn == sn).toList();
  }

  /// 获取指定设备的倒计时
  LocalCountdownItem? getCountdownForDevice(String sn) {
    if (_countdown != null && _countdown!.sn == sn) {
      return _countdown;
    }
    return null;
  }

  /// 是否有任何生效的定时或倒计时
  bool hasActiveTimer(String sn) {
    final cd = getCountdownForDevice(sn);
    if (cd != null && cd.isEnabled && cd.remainingSeconds > 0) return true;
    final timers = getTimersForDevice(sn);
    return timers.any((t) => t.isEnabled);
  }

  /// 添加本地定时任务
  Future<void> addTimer(LocalTimerItem timer) async {
    _timers.add(timer);
    await StorageService.saveLocalTimers(_timers);
    notifyListeners();
  }

  /// 更新本地定时任务
  Future<void> updateTimer(LocalTimerItem timer) async {
    final idx = _timers.indexWhere((t) => t.id == timer.id);
    if (idx != -1) {
      _timers[idx] = timer;
      await StorageService.saveLocalTimers(_timers);
      notifyListeners();
    }
  }

  /// 切换启用状态
  Future<void> toggleTimer(String id, bool enabled) async {
    final idx = _timers.indexWhere((t) => t.id == id);
    if (idx != -1) {
      _timers[idx].isEnabled = enabled;
      await StorageService.saveLocalTimers(_timers);
      notifyListeners();
    }
  }

  /// 删除定时任务
  Future<void> deleteTimer(String id) async {
    _timers.removeWhere((t) => t.id == id);
    await StorageService.saveLocalTimers(_timers);
    notifyListeners();
  }

  /// 启动本地倒计时
  Future<void> startCountdown({
    required String sn,
    required int seconds,
    required int action,
  }) async {
    final endTs = DateTime.now().millisecondsSinceEpoch + (seconds * 1000);
    _countdown = LocalCountdownItem(
      sn: sn,
      action: action,
      totalSeconds: seconds,
      endTimestamp: endTs,
      isEnabled: true,
    );
    await StorageService.saveLocalCountdown(_countdown);
    notifyListeners();
  }

  /// 取消本地倒计时
  Future<void> cancelCountdown(String sn) async {
    if (_countdown != null && _countdown!.sn == sn) {
      _countdown = null;
      await StorageService.saveLocalCountdown(null);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _eventController.close();
    super.dispose();
  }
}
