import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/plug_models.dart';

class StorageService {
  static const String _keyUsername = 'sunlogin_username';
  static const String _keyPassword = 'sunlogin_password';
  static const String _keyToken = 'sunlogin_token';
  static const String _keySelectedSn = 'sunlogin_selected_sn';
  static const String _keySelectedName = 'sunlogin_selected_name';
  static const String _keyWorkflow = 'sunlogin_workflow_config';
  static const String _keyLocalTimers = 'sunlogin_local_timers';
  static const String _keyLocalCountdown = 'sunlogin_local_countdown';

  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  static String? get username => _prefs?.getString(_keyUsername);
  static String? get password => _prefs?.getString(_keyPassword);
  static String? get token => _prefs?.getString(_keyToken);
  static String? get selectedSn => _prefs?.getString(_keySelectedSn);
  static String? get selectedName => _prefs?.getString(_keySelectedName);

  static Future<void> saveCredentials({
    required String username,
    required String password,
    String? token,
  }) async {
    await _prefs?.setString(_keyUsername, username);
    await _prefs?.setString(_keyPassword, password);
    if (token != null) {
      await _prefs?.setString(_keyToken, token);
    }
  }

  static Future<void> saveToken(String token) async {
    await _prefs?.setString(_keyToken, token);
  }

  static Future<void> saveSelectedDevice(String sn, String name) async {
    await _prefs?.setString(_keySelectedSn, sn);
    await _prefs?.setString(_keySelectedName, name);
  }

  static Future<void> clearAll() async {
    await _prefs?.clear();
  }

  static SmartWorkflowConfig getWorkflowConfig() {
    final str = _prefs?.getString(_keyWorkflow);
    if (str != null) {
      try {
        return SmartWorkflowConfig.fromJson(jsonDecode(str));
      } catch (_) {}
    }
    return SmartWorkflowConfig();
  }

  static Future<void> saveWorkflowConfig(SmartWorkflowConfig config) async {
    await _prefs?.setString(_keyWorkflow, jsonEncode(config.toJson()));
  }

  /// 获取本地定时任务列表
  static List<LocalTimerItem> getLocalTimers() {
    final str = _prefs?.getString(_keyLocalTimers);
    if (str != null && str.isNotEmpty) {
      try {
        final List list = jsonDecode(str);
        return list.map((item) => LocalTimerItem.fromJson(Map<String, dynamic>.from(item))).toList();
      } catch (_) {}
    }
    return [];
  }

  /// 保存本地定时任务列表
  static Future<void> saveLocalTimers(List<LocalTimerItem> timers) async {
    final list = timers.map((t) => t.toJson()).toList();
    await _prefs?.setString(_keyLocalTimers, jsonEncode(list));
  }

  /// 获取本地倒计时任务
  static LocalCountdownItem? getLocalCountdown() {
    final str = _prefs?.getString(_keyLocalCountdown);
    if (str != null && str.isNotEmpty) {
      try {
        return LocalCountdownItem.fromJson(jsonDecode(str));
      } catch (_) {}
    }
    return null;
  }

  /// 保存本地倒计时任务（若传 null 则清除）
  static Future<void> saveLocalCountdown(LocalCountdownItem? countdown) async {
    if (countdown == null) {
      await _prefs?.remove(_keyLocalCountdown);
    } else {
      await _prefs?.setString(_keyLocalCountdown, jsonEncode(countdown.toJson()));
    }
  }
}

