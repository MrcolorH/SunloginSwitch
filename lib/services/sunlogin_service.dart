import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:intl/intl.dart';
import '../models/plug_models.dart';
import 'storage_service.dart';

class SunloginService {
  static final SunloginService _instance = SunloginService._internal();
  factory SunloginService() => _instance;
  SunloginService._internal();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
  ));

  static const String appId = 'kNUC97u86Zr7mt9xeZVl';
  static const String clientId = '8ae73501-7def-5b19-b57d-52d15ae1e40b';
  static const String userAgent = 'SLCC/15.3.4 (IOS,appname=sunloginControlClient)';

  String? _token;

  String? get token => _token ?? StorageService.token;

  void setToken(String? token) {
    _token = token;
    if (token != null) {
      StorageService.saveToken(token);
    }
  }

  // 基础 headers
  Map<String, String> _buildHeaders([String? customToken]) {
    final t = customToken ?? token;
    final headers = {
      'User-Agent': userAgent,
      'X-AppID': appId,
      'EX-ClientId': clientId,
      'Accept': '*/*',
    };
    if (t != null && t.isNotEmpty) {
      headers['Authorization'] = 'Bearer $t';
    }
    return headers;
  }

  // 标准 MD5
  String _md5(String input) {
    return md5.convert(utf8.encode(input)).toString().toLowerCase();
  }

  // 生成向日葵专用动态 Key 和 MMddHHmm 时间
  Map<String, String> _generateDynamicKey(String sn) {
    final timeSeed = DateFormat('MMddHHmm').format(DateTime.now());
    final raw = '$sn==smart-plug==$timeSeed';
    final key = _md5(raw);
    return {'time': timeSeed, 'key': key};
  }

  // 安全解析 JSON（防范 Dio 将 text/plain 响应当作 String 导致类型错误）
  dynamic _parseJson(dynamic data) {
    if (data is String) {
      try {
        return jsonDecode(data);
      } catch (_) {
        return null;
      }
    }
    return data;
  }

  // 封装统一的带有 Token 失效重试机制的请求
  Future<Response<T>> _executeWithAuth<T>(Future<Response<T>> Function() requestFn) async {
    try {
      return await requestFn();
    } on DioException catch (e) {
      // 若出现 401 或 token 失效，尝试重新登录
      if (e.response?.statusCode == 401 || e.response?.statusCode == 403) {
        final reLoginSuccess = await _trySilentReLogin();
        if (reLoginSuccess) {
          return await requestFn();
        }
      }
      rethrow;
    }
  }

  Future<bool> _trySilentReLogin() async {
    final u = StorageService.username;
    final p = StorageService.password;
    if (u != null && p != null && u.isNotEmpty && p.isNotEmpty) {
      try {
        await login(u, p);
        return true;
      } catch (_) {}
    }
    return false;
  }

  // ================= 1. 账号与设备接口 =================

  /// 用户名密码登录（包含精准原因诊断）
  Future<String> login(String username, String password) async {
    final pwdMd5 = _md5(password);
    try {
      final response = await _dio.post(
        'https://api-std.sunlogin.oray.com/authorization',
        data: {
          'loginname': username,
          'terminal_name': 'iPhone15Plus',
          'type': 'password',
          'ismd5': true,
          'password': pwdMd5,
        },
        options: Options(headers: _buildHeaders()),
      );

      if (response.statusCode == 200) {
        final data = response.data;
        if (data is Map && data['access_token'] != null) {
          final t = data['access_token'].toString();
          setToken(t);
          await StorageService.saveCredentials(
            username: username,
            password: password,
            token: t,
          );
          return t;
        }
      }
    } on DioException catch (e) {
      String detail = '登录失败，请检查网络或账号密码';
      final resData = e.response?.data;
      if (resData is Map) {
        final err = resData['error']?.toString();
        if (err == 'user/password_not_matched') {
          detail = '向日葵提示【账号或密码不匹配】。\n\n排查建议：\n1. 若您输入的是手机号，因向日葵客户端接口限制，建议改为输入【贝锐原账号名】（如 orayxxxx，可在贝锐网页控制台查看）；\n2. 或者直接使用下方【扫码登录】，无需密码一键登录。';
        } else if (err == 'lt/new_device_alert') {
          detail = '向日葵安全风控拦截【新设备登录预警】。\n向日葵后台禁止了新设备纯密码登录，请直接使用【扫码登录】授权。';
        } else if (err == 'user/need_verify_code') {
          detail = '当前账号触发了安全验证码保护，请直接使用下方【扫码登录】免密授权。';
        } else if (err == 'user/account_not_exist') {
          detail = '该账号不存在，请确认账号名是否正确。';
        } else if (resData['msg'] != null) {
          detail = resData['msg'].toString();
        } else if (err != null) {
          detail = '向日葵接口返回错误: $err';
        }
      }
      throw Exception(detail);
    }
    throw Exception('登录失败，未获取到访问凭据');
  }

  /// 申请二维码登录数据
  Future<Map<String, String>> applyQrCode() async {
    final ms = DateTime.now().millisecondsSinceEpoch;
    final res = await _dio.get('https://user-api-v2.oray.com/qrcode/apply?_t=$ms');
    if (res.statusCode == 200 && res.data is Map) {
      return {
        'key': res.data['key']?.toString() ?? '',
        'qrdata': res.data['qrdata']?.toString() ?? '',
      };
    }
    throw Exception('申请登录二维码失败');
  }

  /// 检查二维码扫码状态
  /// 返回 map: {'status': int, 'secret': String?}
  /// status: 0: 等待扫码, 1: 已扫码待确认, 2: 授权成功, 3: 已过期
  Future<Map<String, dynamic>> checkQrStatus(String key) async {
    final ms = DateTime.now().millisecondsSinceEpoch;
    final res = await _dio.get(
      'https://user-api-v2.oray.com/qrcode/status',
      queryParameters: {'_t': ms, 'key': key},
    );
    if (res.statusCode == 200 && res.data is Map) {
      final s = res.data['status'];
      int status = 0;
      if (s is num) {
        status = s.toInt();
      } else if (s is String) {
        status = int.tryParse(s) ?? 0;
      }
      final secret = res.data['secret']?.toString();
      return {'status': status, 'secret': secret, 'raw': res.data};
    }
    return {'status': 0, 'secret': null};
  }

  /// 二维码确认授权后获取 Token（注意：传入的必须是 status=2 时返回的 secret）
  Future<String> confirmQrLogin(String secret) async {
    final res = await _dio.post(
      'https://user-api-v2.oray.com/qrcode/authorization',
      data: {'key': secret, 'issetcookie': true},
    );
    if (res.statusCode == 200 && res.data is Map) {
      final data = res.data;
      String? t = data['access_token']?.toString() ?? data['token']?.toString();
      if (t == null) {
        for (var entry in data.entries) {
          if (entry.key.toString().toLowerCase().contains('token')) {
            t = entry.value.toString();
            break;
          }
        }
      }
      if (t != null && t.isNotEmpty) {
        setToken(t);
        await StorageService.saveCredentials(
          username: data['account']?.toString() ?? '向日葵扫码用户',
          password: '',
          token: t,
        );
        return t;
      }
      throw Exception('授权成功但未找到有效 Token: ${res.data}');
    }
    throw Exception('获取扫码授权凭据失败 (HTTP ${res.statusCode}): ${res.data}');
  }

  /// 直接使用 Token 进入（例如从网页版控制台复制的 Token）
  Future<void> loginWithDirectToken(String directToken, [String? accountName]) async {
    setToken(directToken);
    // 验证 Token 是否有效
    await getDeviceList();
    await StorageService.saveCredentials(
      username: accountName ?? 'Token登录',
      password: '',
      token: directToken,
    );
  }

  /// 使用网页端 Session ID (_s_id_) 换取 Access Token
  Future<String> exchangeSessionToken(String sessionId) async {
    final ms = DateTime.now().millisecondsSinceEpoch;
    final res = await _dio.get(
      'https://user-api-v2.oray.com/authorization/session-token',
      queryParameters: {'_t': ms, 'key': sessionId},
      options: Options(
        headers: {
          ..._buildHeaders(),
          'Cookie': '_s_id_=$sessionId',
        },
      ),
    );

    final data = _parseJson(res.data);
    if (data is Map) {
      String? t = data['access_token']?.toString() ?? data['token']?.toString();
      if (t == null) {
        for (var entry in data.entries) {
          if (entry.key.toString().toLowerCase().contains('token')) {
            t = entry.value.toString();
            break;
          }
        }
      }
      if (t != null && t.isNotEmpty) {
        setToken(t);
        await StorageService.saveCredentials(
          username: data['account']?.toString() ?? '贝锐网页用户',
          password: '',
          token: t,
        );
        return t;
      }
    }
    throw Exception('Session 凭据兑换失败: ${res.data}');
  }

  /// 尝试通过网页抓取到的任意凭证（直接Token或SessionId或Cookie集合）登录
  Future<bool> tryLoginWithWebCredentials({
    String? directToken,
    String? sessionId,
    Map<String, String>? cookies,
  }) async {
    // 1. 若有直接 token
    if (directToken != null && directToken.trim().isNotEmpty) {
      try {
        await loginWithDirectToken(directToken.trim(), '网页登录用户');
        return true;
      } catch (_) {}
    }

    // 2. 检查 cookies 里是否包含 token 相关的键
    if (cookies != null) {
      for (final entry in cookies.entries) {
        final k = entry.key.toLowerCase();
        final v = entry.value.trim();
        if ((k == 'access_token' || k == 'token' || k.endsWith('_token')) && v.length > 20) {
          try {
            await loginWithDirectToken(v, '网页登录用户');
            return true;
          } catch (_) {}
        }
      }
    }

    // 3. 若有 sessionId 或 cookies 中的 _s_id_
    final sId = sessionId ?? cookies?['_s_id_'] ?? cookies?['s_id'];
    if (sId != null && sId.trim().isNotEmpty) {
      try {
        final t = await exchangeSessionToken(sId.trim());
        await loginWithDirectToken(t, '网页登录用户');
        return true;
      } catch (_) {}
    }

    return false;
  }

  /// 获取绑定的设备列表
  Future<List<SunloginDevice>> getDeviceList() async {
    final response = await _executeWithAuth(() => _dio.get(
      'https://api-std.sunlogin.oray.com/wakeup/devices',
      options: Options(headers: _buildHeaders()),
    ));

    final data = _parseJson(response.data);
    List rawDevices = [];
    if (data is Map && data['devices'] is List) {
      rawDevices = data['devices'];
    } else if (data is List) {
      rawDevices = data;
    }

    return rawDevices
        .whereType<Map>()
        .map((e) => SunloginDevice.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  // ================= 2. 设备状态与控制 =================

  /// 获取插座开关状态 (true=开, false=关)
  Future<bool> getSwitchStatus(String sn) async {
    final sign = _generateDynamicKey(sn);
    final response = await _executeWithAuth(() => _dio.get(
      'https://slapi.oray.net/plug',
      queryParameters: {
        '_api': 'get_plug_status',
        'sn': sn,
        'time': sign['time'],
        'key': sign['key'],
        if (token != null && token!.isNotEmpty) 'access_token': token,
      },
      options: Options(headers: _buildHeaders()),
    ));

    final data = _parseJson(response.data);
    if (data is Map) {
      // 1. 向日葵官方标准数组字段为 'response' (如 [{"index":0,"status":1}])，部分固件为 'relay'
      final list = (data['response'] as List?) ?? (data['relay'] as List?) ?? [];
      for (var item in list) {
        if (item is Map && (item['index'] == 0 || item['index'] == null)) {
          final s = item['status'];
          return s == 1 || s == '1' || s == true;
        }
      }
      if (list.isNotEmpty && list[0] is Map) {
        final s = list[0]['status'];
        return s == 1 || s == '1' || s == true;
      }

      // 2. 兼容顶层 status 字段
      if (data['status'] != null) {
        final s = data['status'];
        return s == 1 || s == '1' || s == true;
      }
    }
    return false;
  }

  /// 设置插座开关状态
  Future<bool> setSwitchStatus(String sn, bool isOpen) async {
    final sign = _generateDynamicKey(sn);
    final response = await _executeWithAuth(() => _dio.get(
      'https://slapi.oray.net/plug',
      queryParameters: {
        '_api': 'set_plug_status',
        'sn': sn,
        'index': 0,
        'status': isOpen ? 1 : 0,
        'time': sign['time'],
        'key': sign['key'],
        if (token != null && token!.isNotEmpty) 'access_token': token,
      },
      options: Options(headers: _buildHeaders()),
    ));

    return response.statusCode == 200;
  }

  /// 获取实时功耗、电压、电流
  Future<PlugElectric> getRealtimeElectric(String sn) async {
    final sign = _generateDynamicKey(sn);
    final response = await _executeWithAuth(() => _dio.get(
      'https://slapi.oray.net/plug',
      queryParameters: {
        '_api': 'get_plug_electric',
        'sn': sn,
        'time': sign['time'],
        'key': sign['key'],
        if (token != null && token!.isNotEmpty) 'access_token': token,
      },
      options: Options(headers: _buildHeaders()),
    ));

    final data = _parseJson(response.data);
    if (data is Map) {
      final raw = (data['response'] is Map) ? data['response'] : data;
      return PlugElectric.fromRaw(
        powerRaw: raw['power'],
        volRaw: raw['vol'],
        currRaw: raw['curr'],
      );
    }
    return const PlugElectric();
  }

  // ================= 3. 电量计数与月度统计 =================

  /// 获取云端历史用电量统计（按小时记录聚合）
  Future<PlugEnergyStats> getEnergyStats(String sn) async {
    final response = await _executeWithAuth(() => _dio.get(
      'https://sl-api.oray.com/smartplug/powerconsumes/$sn',
      queryParameters: {'index': 0},
      options: Options(headers: _buildHeaders()),
    ));

    final data = _parseJson(response.data);
    List rawList = [];
    if (data is List) {
      rawList = data;
    } else if (data is Map) {
      if (data['powerconsumes'] is List) {
        rawList = data['powerconsumes'];
      } else if (data['response'] is List) {
        rawList = data['response'];
      } else if (data['data'] is List) {
        rawList = data['data'];
      }
    }
    return PlugEnergyStats.calculateFromRaw(rawList);
  }

  // ================= 4. 定时任务接口 =================

  /// 获取当前定时任务列表
  Future<List<PlugTimerItem>> getTimers(String sn) async {
    final sign = _generateDynamicKey(sn);
    try {
      final response = await _executeWithAuth(() => _dio.get(
        'https://slapi.oray.net/plug',
        queryParameters: {
          '_api': 'plug_timer_get',
          'sn': sn,
          'time': sign['time'],
          'key': sign['key'],
          if (token != null && token!.isNotEmpty) 'access_token': token,
        },
        options: Options(headers: _buildHeaders()),
      ));

      final data = _parseJson(response.data);
      List timers = [];
      if (data is Map) {
        timers = (data['timer'] as List?) ??
            (data['timers'] as List?) ??
            (data['response'] as List?) ??
            [];
      } else if (data is List) {
        timers = data;
      }
      final List<PlugTimerItem> result = [];
      for (int i = 0; i < timers.length; i++) {
        if (timers[i] is Map) {
          result.add(PlugTimerItem.fromJson(Map<String, dynamic>.from(timers[i]), i));
        }
      }
      return result;
    } catch (_) {
      return [];
    }
  }

  /// 检查是否有活跃的定时任务
  Future<bool> hasActiveTimer(String sn) async {
    final timers = await getTimers(sn);
    if (timers.any((t) => t.enable)) return true;
    
    // 检查是否有倒计时
    final cd = await getCountdown(sn);
    return cd > 0;
  }

  /// 添加云端硬件定时任务
  /// [timeMinutes] 为 0~1439 (例如 08:30 -> 8*60+30=510)
  /// [action] 1=开启, 0=关闭
  /// [repeat] 127=每天, 62=工作日, 65=周末, 0=仅一次
  Future<bool> addTimer(String sn, {
    required int timeMinutes,
    required int action,
    required int repeat,
  }) async {
    final sign = _generateDynamicKey(sn);
    final timerJson = jsonEncode({
      'time': timeMinutes,
      'repeat': repeat,
      'enable': 1,
      'action': action,
    });

    final response = await _executeWithAuth(() => _dio.get(
      'https://slapi.oray.net/plug',
      queryParameters: {
        '_api': 'plug_timer_add',
        'sn': sn,
        'timer': timerJson,
        'time': sign['time'],
        'key': sign['key'],
        if (token != null && token!.isNotEmpty) 'access_token': token,
      },
      options: Options(headers: _buildHeaders()),
    ));
    return response.statusCode == 200;
  }

  /// 获取倒计时（秒）
  Future<int> getCountdown(String sn) async {
    final sign = _generateDynamicKey(sn);
    try {
      final response = await _executeWithAuth(() => _dio.get(
        'https://slapi.oray.net/plug',
        queryParameters: {
          '_api': 'plug_cntdown_get',
          'sn': sn,
          'time': sign['time'],
          'key': sign['key'],
          if (token != null && token!.isNotEmpty) 'access_token': token,
        },
        options: Options(headers: _buildHeaders()),
      ));
      final data = _parseJson(response.data);
      if (data is Map) {
        final raw = (data['response'] is Map) ? data['response'] : data;
        final remain = raw['remain'] ?? raw['time'];
        if (remain != null) {
          return int.tryParse(remain.toString()) ?? 0;
        }
      }
    } catch (_) {}
    return 0;
  }

  /// 设置倒计时开关
  /// [seconds] 多少秒后执行
  /// [action] 1=开, 0=关
  Future<bool> setCountdown(String sn, {
    required int seconds,
    required int action,
  }) async {
    final sign = _generateDynamicKey(sn);
    final cdJson = jsonEncode({
      'time': seconds,
      'enable': 1,
      'action': action,
    });

    final response = await _executeWithAuth(() => _dio.get(
      'https://slapi.oray.net/plug',
      queryParameters: {
        '_api': 'plug_cntdown_add',
        'sn': sn,
        'cntdown': cdJson,
        'time': sign['time'],
        'key': sign['key'],
        if (token != null && token!.isNotEmpty) 'access_token': token,
      },
      options: Options(headers: _buildHeaders()),
    ));
    return response.statusCode == 200;
  }
}
