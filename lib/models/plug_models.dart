import 'package:intl/intl.dart';

/// 向日葵设备信息
class SunloginDevice {
  final String sn;
  final String name;
  final String model;
  final bool isOnline;

  SunloginDevice({
    required this.sn,
    required this.name,
    required this.model,
    required this.isOnline,
  });

  factory SunloginDevice.fromJson(Map<String, dynamic> json) {
    // 智能解析在线状态：
    // 向日葵 wakeup/devices 接口中，status: 0 通常代表关联的主机电脑当前处于关机状态，而非插座本身离线。
    // 仅当明确存在 is_online / online / link_status / state 且其明确标识为 0/false/'offline' 时才判定为离线；
    // 否则插座在云端绑定列表中只要存在，即为在线可控状态。
    bool online = true;
    final onlineField = json['is_online'] ?? json['online'] ?? json['link_status'] ?? json['device_status'];
    if (onlineField != null) {
      if (onlineField == 0 || onlineField == '0' || onlineField == false || onlineField == 'offline' || onlineField == 'disconnected') {
        online = false;
      } else if (onlineField == 1 || onlineField == '1' || onlineField == true || onlineField == 'online' || onlineField == 'connected') {
        online = true;
      }
    } else {
      // 接口未下发专用在线字段时，设备出现在绑定列表中默认即处于可控在线状态
      online = true;
    }

    return SunloginDevice(
      sn: json['sn']?.toString() ?? '',
      name: json['name']?.toString() ?? '智能插座',
      model: json['model']?.toString() ?? 'C2',
      isOnline: online,
    );
  }

  Map<String, dynamic> toJson() => {
    'sn': sn,
    'name': name,
    'model': model,
    'is_online': isOnline ? 1 : 0,
  };
}

/// 实时电参数
class PlugElectric {
  final double power;   // 瓦特 (W)
  final double voltage; // 伏特 (V)
  final double current; // 安培 (A)

  const PlugElectric({
    this.power = 0.0,
    this.voltage = 0.0,
    this.current = 0.0,
  });

  factory PlugElectric.fromRaw({dynamic powerRaw, dynamic volRaw, dynamic currRaw}) {
    final pNum = num.tryParse(powerRaw?.toString() ?? '') ?? 0.0;
    final vNum = num.tryParse(volRaw?.toString() ?? '') ?? 0.0;
    final cNum = num.tryParse(currRaw?.toString() ?? '') ?? 0.0;

    final p = pNum.toDouble() / 1000.0;
    final v = vNum.toDouble() / 1000.0;
    // currRaw 为微安(uA)或毫安(mA)，官方源码 curr // 1000 为 mA，此处转为安培 (A)
    final c = cNum.toDouble() / 1000000.0;
    return PlugElectric(
      power: double.tryParse(p.toStringAsFixed(2)) ?? 0.0,
      voltage: double.tryParse(v.toStringAsFixed(1)) ?? 0.0,
      current: double.tryParse(c.toStringAsFixed(3)) ?? 0.0,
    );
  }
}

/// 按小时的电量记录
class HourlyEnergy {
  final DateTime startTime;
  final DateTime endTime;
  final double consumeWh; // 瓦时 (Wh)

  HourlyEnergy({
    required this.startTime,
    required this.endTime,
    required this.consumeWh,
  });

  double get consumeKWh => consumeWh / 1000.0; // 度 (kWh)

  factory HourlyEnergy.fromJson(Map<String, dynamic> json) {
    final startSec = int.tryParse(json['starttime']?.toString() ?? '') ?? 0;
    final endSec = int.tryParse(json['endtime']?.toString() ?? '') ?? 0;
    final consume = num.tryParse(json['consume']?.toString() ?? '')?.toDouble() ?? 0.0;
    return HourlyEnergy(
      startTime: DateTime.fromMillisecondsSinceEpoch(startSec * 1000),
      endTime: DateTime.fromMillisecondsSinceEpoch(endSec * 1000),
      consumeWh: consume,
    );
  }
}

/// 按天的电量聚合
class DailyEnergy {
  final String dateStr; // 'yyyy-MM-dd'
  final DateTime date;
  double consumeKWh;

  DailyEnergy({
    required this.dateStr,
    required this.date,
    this.consumeKWh = 0.0,
  });
}

/// 电量统计总揽
class PlugEnergyStats {
  final double todayKWh;
  final double weekKWh;
  final double monthKWh;
  final double lastMonthKWh;
  final List<HourlyEnergy> rawHourlyList;
  final List<DailyEnergy> last7DaysList;

  PlugEnergyStats({
    this.todayKWh = 0.0,
    this.weekKWh = 0.0,
    this.monthKWh = 0.0,
    this.lastMonthKWh = 0.0,
    this.rawHourlyList = const [],
    this.last7DaysList = const [],
  });

  factory PlugEnergyStats.calculateFromRaw(List<dynamic> rawList) {
    final hourlyList = rawList
        .whereType<Map>()
        .map((item) => HourlyEnergy.fromJson(Map<String, dynamic>.from(item)))
        .toList();

    double today = 0.0;
    double week = 0.0;
    double month = 0.0;
    double lastMonth = 0.0;

    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    // 本周一 00:00:00
    final weekStart = DateTime(now.year, now.month, now.day - (now.weekday - 1));
    // 本月1日 00:00:00
    final monthStart = DateTime(now.year, now.month, 1);
    // 上月1日 00:00:00
    final lastMonthStart = DateTime(now.month == 1 ? now.year - 1 : now.year, now.month == 1 ? 12 : now.month - 1, 1);

    // 聚合最近 7 天
    final Map<String, DailyEnergy> dailyMap = {};
    final dateFormat = DateFormat('yyyy-MM-dd');
    for (int i = 6; i >= 0; i--) {
      final d = now.subtract(Duration(days: i));
      final key = dateFormat.format(d);
      dailyMap[key] = DailyEnergy(dateStr: key, date: DateTime(d.year, d.month, d.day));
    }

    for (var h in hourlyList) {
      final kwh = h.consumeKWh;
      final time = h.endTime;

      if (time.isAfter(todayStart) || time.isAtSameMomentAs(todayStart)) {
        today += kwh;
      }
      if (time.isAfter(weekStart) || time.isAtSameMomentAs(weekStart)) {
        week += kwh;
      }
      if (time.isAfter(monthStart) || time.isAtSameMomentAs(monthStart)) {
        month += kwh;
      } else if ((time.isAfter(lastMonthStart) || time.isAtSameMomentAs(lastMonthStart)) && time.isBefore(monthStart)) {
        lastMonth += kwh;
      }

      final dayKey = dateFormat.format(time);
      if (dailyMap.containsKey(dayKey)) {
        dailyMap[dayKey]!.consumeKWh += kwh;
      }
    }

    return PlugEnergyStats(
      todayKWh: double.tryParse(today.toStringAsFixed(3)) ?? 0.0,
      weekKWh: double.tryParse(week.toStringAsFixed(3)) ?? 0.0,
      monthKWh: double.tryParse(month.toStringAsFixed(3)) ?? 0.0,
      lastMonthKWh: double.tryParse(lastMonth.toStringAsFixed(3)) ?? 0.0,
      rawHourlyList: hourlyList,
      last7DaysList: dailyMap.values.toList(),
    );
  }
}

/// 定时任务
class PlugTimerItem {
  final int id;
  final int timeMinutes; // 每天第几分钟 0-1439
  final int action;      // 1=开, 0=关
  final int repeat;      // 7位掩码: 127每天, 62工作日
  final bool enable;

  PlugTimerItem({
    required this.id,
    required this.timeMinutes,
    required this.action,
    required this.repeat,
    required this.enable,
  });

  String get timeFormatted {
    final h = (timeMinutes ~/ 60).toString().padLeft(2, '0');
    final m = (timeMinutes % 60).toString().padLeft(2, '0');
    return '$h:$m';
  }

  String get repeatSummary {
    if (repeat == 127) return '每天';
    if (repeat == 62) return '工作日';
    if (repeat == 65) return '周末';
    if (repeat == 0) return '仅一次';
    return '周期: $repeat';
  }

  factory PlugTimerItem.fromJson(Map<String, dynamic> json, int defaultId) {
    return PlugTimerItem(
      id: int.tryParse(json['id']?.toString() ?? '') ?? defaultId,
      timeMinutes: int.tryParse(json['time']?.toString() ?? '') ?? 0,
      action: int.tryParse(json['action']?.toString() ?? '') ?? 0,
      repeat: int.tryParse(json['repeat']?.toString() ?? '') ?? 0,
      enable: json['enable'] == 1 || json['enable'] == '1' || json['enable'] == true,
    );
  }
}

/// 智能自动化工作流配置
class SmartWorkflowConfig {
  bool autoPowerOffEnabled;
  double thresholdWatts;
  int durationMinutes;

  SmartWorkflowConfig({
    this.autoPowerOffEnabled = false,
    this.thresholdWatts = 5.0,
    this.durationMinutes = 5,
  });

  Map<String, dynamic> toJson() => {
    'autoPowerOffEnabled': autoPowerOffEnabled,
    'thresholdWatts': thresholdWatts,
    'durationMinutes': durationMinutes,
  };

  factory SmartWorkflowConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return SmartWorkflowConfig();
    return SmartWorkflowConfig(
      autoPowerOffEnabled: json['autoPowerOffEnabled'] == true,
      thresholdWatts: num.tryParse(json['thresholdWatts']?.toString() ?? '')?.toDouble() ?? 5.0,
      durationMinutes: int.tryParse(json['durationMinutes']?.toString() ?? '') ?? 5,
    );
  }
}

/// 手机本地定时任务模型
class LocalTimerItem {
  final String id;
  final String sn;
  String name;
  int hour;      // 0-23
  int minute;    // 0-59
  int action;    // 1=开启, 0=关闭
  int repeat;    // 0=仅一次, 127=每天, 62=工作日, 65=周末, -1=自定义
  List<int> weekDays; // 1=周一 .. 7=周日
  bool isEnabled;
  String? lastExecutedDate; // 格式: yyyy-MM-dd HH:mm，避免同分钟重复触发

  LocalTimerItem({
    required this.id,
    required this.sn,
    this.name = '定时任务',
    required this.hour,
    required this.minute,
    required this.action,
    this.repeat = 127,
    List<int>? weekDays,
    this.isEnabled = true,
    this.lastExecutedDate,
  }) : weekDays = weekDays ?? _calcWeekDaysFromRepeat(repeat);

  static List<int> _calcWeekDaysFromRepeat(int repeat) {
    if (repeat == 127) return [1, 2, 3, 4, 5, 6, 7];
    if (repeat == 62) return [1, 2, 3, 4, 5];
    if (repeat == 65) return [6, 7];
    if (repeat == 0) return [];
    return [1, 2, 3, 4, 5, 6, 7];
  }

  String get timeFormatted {
    final h = hour.toString().padLeft(2, '0');
    final m = minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  String get repeatSummary {
    if (repeat == 0 || weekDays.isEmpty) return '仅一次';
    if (weekDays.length == 7) return '每天';
    final isWorkdays = weekDays.length == 5 &&
        weekDays.contains(1) &&
        weekDays.contains(2) &&
        weekDays.contains(3) &&
        weekDays.contains(4) &&
        weekDays.contains(5);
    if (isWorkdays) return '工作日';

    final isWeekend = weekDays.length == 2 && weekDays.contains(6) && weekDays.contains(7);
    if (isWeekend) return '周末';

    const dayNames = {
      1: '周一',
      2: '周二',
      3: '周三',
      4: '周四',
      5: '周五',
      6: '周六',
      7: '周日',
    };
    final sorted = List<int>.from(weekDays)..sort();
    return sorted.map((d) => dayNames[d] ?? '').join('、');
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'sn': sn,
    'name': name,
    'hour': hour,
    'minute': minute,
    'action': action,
    'repeat': repeat,
    'weekDays': weekDays,
    'isEnabled': isEnabled,
    'lastExecutedDate': lastExecutedDate,
  };

  factory LocalTimerItem.fromJson(Map<String, dynamic> json) {
    final rep = int.tryParse(json['repeat']?.toString() ?? '') ?? 127;
    List<int> days = [];
    if (json['weekDays'] is List) {
      days = (json['weekDays'] as List).map((e) => int.tryParse(e.toString()) ?? 0).where((e) => e >= 1 && e <= 7).toList();
    } else {
      days = _calcWeekDaysFromRepeat(rep);
    }

    return LocalTimerItem(
      id: json['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
      sn: json['sn']?.toString() ?? '',
      name: json['name']?.toString() ?? '定时任务',
      hour: int.tryParse(json['hour']?.toString() ?? '') ?? 0,
      minute: int.tryParse(json['minute']?.toString() ?? '') ?? 0,
      action: int.tryParse(json['action']?.toString() ?? '') ?? 0,
      repeat: rep,
      weekDays: days,
      isEnabled: json['isEnabled'] == true || json['isEnabled'] == 1,
      lastExecutedDate: json['lastExecutedDate']?.toString(),
    );
  }
}

/// 手机本地倒计时任务模型
class LocalCountdownItem {
  final String sn;
  final int action; // 1=开, 0=关
  final int totalSeconds;
  final int endTimestamp; // 毫秒时间戳
  bool isEnabled;

  LocalCountdownItem({
    required this.sn,
    required this.action,
    required this.totalSeconds,
    required this.endTimestamp,
    this.isEnabled = true,
  });

  int get remainingSeconds {
    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = (endTimestamp - now) ~/ 1000;
    return diff > 0 ? diff : 0;
  }

  String get remainingFormatted {
    final rem = remainingSeconds;
    final h = rem ~/ 3600;
    final m = (rem % 3600) ~/ 60;
    final s = rem % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> toJson() => {
    'sn': sn,
    'action': action,
    'totalSeconds': totalSeconds,
    'endTimestamp': endTimestamp,
    'isEnabled': isEnabled,
  };

  factory LocalCountdownItem.fromJson(Map<String, dynamic> json) {
    return LocalCountdownItem(
      sn: json['sn']?.toString() ?? '',
      action: int.tryParse(json['action']?.toString() ?? '') ?? 0,
      totalSeconds: int.tryParse(json['totalSeconds']?.toString() ?? '') ?? 0,
      endTimestamp: int.tryParse(json['endTimestamp']?.toString() ?? '') ?? 0,
      isEnabled: json['isEnabled'] == true || json['isEnabled'] == 1,
    );
  }
}

