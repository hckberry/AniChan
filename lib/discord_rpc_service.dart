import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:isolate';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// ---------------------------------------------------------------------------
/// Config (persisted by AppState in Hive as a plain map)
/// ---------------------------------------------------------------------------
class DiscordRpcConfig {
  bool enabled;
  String token;
  String applicationId; // Any Discord application id you own (developer portal).
  bool showTitle;
  bool showEpisode;
  bool showTimestamp;
  bool showCoverArt;
  String customStatus; // Supports {title} and {episode}. Empty = default.
  String button1Label;
  String button1Url;
  String button2Label;
  String button2Url;

  DiscordRpcConfig({
    this.enabled = false,
    this.token = '',
    this.applicationId = '',
    this.showTitle = true,
    this.showEpisode = true,
    this.showTimestamp = true,
    this.showCoverArt = true,
    this.customStatus = '',
    this.button1Label = '',
    this.button1Url = '',
    this.button2Label = '',
    this.button2Url = '',
  });

  factory DiscordRpcConfig.fromMap(Map? m) {
    m ??= const {};
    return DiscordRpcConfig(
      enabled: m['enabled'] ?? false,
      token: m['token'] ?? '',
      applicationId: m['applicationId'] ?? '',
      showTitle: m['showTitle'] ?? true,
      showEpisode: m['showEpisode'] ?? true,
      showTimestamp: m['showTimestamp'] ?? true,
      showCoverArt: m['showCoverArt'] ?? true,
      customStatus: m['customStatus'] ?? '',
      button1Label: m['button1Label'] ?? '',
      button1Url: m['button1Url'] ?? '',
      button2Label: m['button2Label'] ?? '',
      button2Url: m['button2Url'] ?? '',
    );
  }

  Map<String, dynamic> toMap() => {
        'enabled': enabled,
        'token': token,
        'applicationId': applicationId,
        'showTitle': showTitle,
        'showEpisode': showEpisode,
        'showTimestamp': showTimestamp,
        'showCoverArt': showCoverArt,
        'customStatus': customStatus,
        'button1Label': button1Label,
        'button1Url': button1Url,
        'button2Label': button2Label,
        'button2Url': button2Url,
      };
}

/// What the player is currently doing.
class MediaActivity {
  final String title;
  final int episode;
  final String? coverUrl;
  final Duration position;
  final Duration duration;
  final bool playing;

  const MediaActivity({
    required this.title,
    required this.episode,
    this.coverUrl,
    required this.position,
    required this.duration,
    required this.playing,
  });
}

enum DiscordStatus { disabled, connecting, connected, authFailed, error }

/// ---------------------------------------------------------------------------
/// Gateway-based Rich Presence using a *user token*.
/// (Violates Discord ToS - accepted by the user. Use at your own risk.)
/// ---------------------------------------------------------------------------
class DiscordRpcService extends ChangeNotifier {
  DiscordRpcService(this.config);

  DiscordRpcConfig config;
  DiscordStatus status = DiscordStatus.disabled;

  static const _gateway = 'wss://gateway.discord.gg';
  static const _api = 'https://discord.com/api/v9';

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 15),
  ));

  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  Timer? _heartbeat;
  Timer? _reconnectTimer;
  int? _seq;
  String? _sessionId;
  String? _resumeUrl;
  bool _acked = true;
  bool _userClosed = false;
  int _attempts = 0;

  MediaActivity? _activity;
  final Map<String, String> _assetCache = {};

  // ----- public API ---------------------------------------------------------

  /// Apply new settings and (re)connect / disconnect as required.
  Future<void> updateConfig(DiscordRpcConfig c) async {
    final tokenChanged = c.token != config.token;
    final toggled = c.enabled != config.enabled;
    config = c;
    if (!config.enabled || config.token.isEmpty) {
      await disconnect();
      _setStatus(DiscordStatus.disabled);
      return;
    }
    if (tokenChanged || toggled || _ch == null) {
      _sessionId = null;
      _seq = null;
      await connect();
    } else {
      await _pushPresence();
    }
  }

  Future<void> connect() async {
    if (!config.enabled || config.token.isEmpty) return;
    await _teardownSocket();
    _userClosed = false;
    _setStatus(DiscordStatus.connecting);
    try {
      final base = _resumeUrl ?? _gateway;
      _ch = WebSocketChannel.connect(Uri.parse('$base/?v=10&encoding=json'));
      await _ch!.ready;
      _sub = _ch!.stream.listen(
        _onMessage,
        onDone: _onClosed,
        onError: (_) => _onClosed(),
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('[DiscordRPC] connect failed: $e');
      _scheduleReconnect();
    }
  }

  Future<void> disconnect() async {
    _userClosed = true;
    _reconnectTimer?.cancel();
    await _clearPresenceBestEffort();
    await _teardownSocket();
    await DiscordBackground.stop();
  }

  /// Called by the player on play / pause / seek / episode change.
  Future<void> setWatching(MediaActivity a) async {
    _activity = a;
    if (config.enabled) {
      await DiscordBackground.start();
      await _pushPresence();
    }
  }

  Future<void> clearActivity() async {
    _activity = null;
    await _pushPresence();
  }

  // ----- gateway protocol ---------------------------------------------------

  void _onMessage(dynamic raw) {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    final op = msg['op'] as int;
    final d = msg['d'];
    if (msg['s'] != null) _seq = msg['s'] as int;

    switch (op) {
      case 10: // HELLO
        final interval = (d['heartbeat_interval'] as num).toInt();
        _startHeartbeat(interval);
        if (_sessionId != null && _seq != null) {
          _send({
            'op': 6,
            'd': {'token': config.token, 'session_id': _sessionId, 'seq': _seq}
          });
        } else {
          _identify();
        }
        break;
      case 11: // HEARTBEAT_ACK
        _acked = true;
        break;
      case 1: // server requests heartbeat
        _send({'op': 1, 'd': _seq});
        break;
      case 7: // RECONNECT
        _forceReconnect();
        break;
      case 9: // INVALID_SESSION
        if (d != true) {
          _sessionId = null;
          _seq = null;
        }
        Future.delayed(Duration(milliseconds: 1000 + Random().nextInt(4000)),
            () => d == true ? _resumeOrIdentify() : _identify());
        break;
      case 0: // DISPATCH
        if (msg['t'] == 'READY') {
          _sessionId = d['session_id'];
          _resumeUrl = d['resume_gateway_url'];
          _attempts = 0;
          _setStatus(DiscordStatus.connected);
          _pushPresence();
        } else if (msg['t'] == 'RESUMED') {
          _attempts = 0;
          _setStatus(DiscordStatus.connected);
          _pushPresence();
        }
        break;
    }
  }

  void _resumeOrIdentify() {
    if (_sessionId != null && _seq != null) {
      _send({
        'op': 6,
        'd': {'token': config.token, 'session_id': _sessionId, 'seq': _seq}
      });
    } else {
      _identify();
    }
  }

  void _identify() {
    _send({
      'op': 2,
      'd': {
        'token': config.token,
        'capabilities': 16381,
        'properties': {
          'os': 'Android',
          'browser': 'Discord Android',
          'device': 'Android',
          'system_locale': 'en-US',
          'client_version': '221.0 - rn',
          'release_channel': 'googleRelease',
        },
        'presence': {
          'status': 'online',
          'since': 0,
          'activities': <dynamic>[],
          'afk': false,
        },
        'compress': false,
        'client_state': {'guild_versions': {}},
      }
    });
  }

  void _startHeartbeat(int intervalMs) {
    _heartbeat?.cancel();
    _acked = true;
    final jitter = (intervalMs * Random().nextDouble()).toInt();
    Timer(Duration(milliseconds: jitter), () {
      _beat();
      _heartbeat = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
        if (!_acked) {
          _forceReconnect(); // zombied connection
          return;
        }
        _beat();
      });
    });
  }

  void _beat() {
    _acked = false;
    _send({'op': 1, 'd': _seq});
  }

  void _send(Map<String, dynamic> payload) {
    try {
      _ch?.sink.add(jsonEncode(payload));
    } catch (e) {
      debugPrint('[DiscordRPC] send failed: $e');
    }
  }

  // ----- presence -----------------------------------------------------------

  Future<void> _pushPresence() async {
    if (status != DiscordStatus.connected) return;
    final act = _activity;
    final activities = <Map<String, dynamic>>[];
    if (act != null && config.enabled) {
      activities.add(await _buildActivity(act));
    }
    _send({
      'op': 3,
      'd': {
        'since': 0,
        'activities': activities,
        'status': 'online',
        'afk': false,
      }
    });
  }

  Future<void> _clearPresenceBestEffort() async {
    if (status == DiscordStatus.connected) {
      _send({
        'op': 3,
        'd': {'since': 0, 'activities': [], 'status': 'online', 'afk': false}
      });
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }

  Future<Map<String, dynamic>> _buildActivity(MediaActivity a) async {
    String fill(String s) => s
        .replaceAll('{title}', a.title)
        .replaceAll('{episode}', a.episode.toString());

    final act = <String, dynamic>{
      'name': 'AniChan',
      'type': 3, // Watching
      'application_id': config.applicationId,
    };

    // details
    if (config.showTitle) act['details'] = a.title;

    // state
    if (config.customStatus.trim().isNotEmpty) {
      act['state'] = fill(config.customStatus.trim());
    } else if (config.showEpisode) {
      act['state'] = a.playing ? 'Episode ${a.episode}' : 'Paused - Episode ${a.episode}';
    } else if (!a.playing) {
      act['state'] = 'Paused';
    }

    // timestamps (only while playing)
    if (config.showTimestamp && a.playing) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final start = now - a.position.inMilliseconds;
      act['timestamps'] = {
        'start': start,
        if (a.duration > Duration.zero) 'end': start + a.duration.inMilliseconds,
      };
    }

    // cover art -> external asset
    if (config.showCoverArt && a.coverUrl != null) {
      final asset = await _resolveExternalAsset(a.coverUrl!);
      if (asset != null) {
        act['assets'] = {
          'large_image': asset,
          if (config.showTitle) 'large_text': a.title,
        };
      }
    }

    // buttons (max 2, label <= 32 chars)
    final labels = <String>[];
    final urls = <String>[];
    void addBtn(String l, String u) {
      final label = fill(l.trim());
      final url = fill(u.trim());
      if (label.isNotEmpty && Uri.tryParse(url)?.hasScheme == true) {
        labels.add(label.length > 32 ? label.substring(0, 32) : label);
        urls.add(url);
      }
    }

    addBtn(config.button1Label, config.button1Url);
    addBtn(config.button2Label, config.button2Url);
    if (labels.isNotEmpty) {
      act['buttons'] = labels;
      act['metadata'] = {'button_urls': urls};
    }
    return act;
  }

  /// Converts any https image URL to a Discord "mp:" external asset key.
  Future<String?> _resolveExternalAsset(String url) async {
    if (_assetCache.containsKey(url)) return _assetCache[url];
    if (config.applicationId.isEmpty) return null;
    try {
      final r = await _dio.post(
        '$_api/applications/${config.applicationId}/external-assets',
        data: {'urls': [url]},
        options: Options(headers: {
          'Authorization': config.token,
          'Content-Type': 'application/json',
        }),
      );
      final list = r.data as List;
      if (list.isNotEmpty) {
        final path = list.first['external_asset_path'] as String;
        final key = 'mp:$path';
        _assetCache[url] = key;
        return key;
      }
    } catch (e) {
      debugPrint('[DiscordRPC] external asset failed: $e');
    }
    return null;
  }

  // ----- lifecycle ----------------------------------------------------------

  void _onClosed() {
    final code = _ch?.closeCode;
    _heartbeat?.cancel();
    if (_userClosed) return;
    if (code == 4004) {
      // Authentication failed - bad token.
      _setStatus(DiscordStatus.authFailed);
      return;
    }
    if (code == 4007 || code == 4009) {
      _sessionId = null;
      _seq = null;
    }
    _scheduleReconnect();
  }

  void _forceReconnect() {
    _teardownSocket();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_userClosed || !config.enabled) return;
    _reconnectTimer?.cancel();
    _setStatus(DiscordStatus.connecting);
    final delay = Duration(seconds: min(60, 2 << min(_attempts, 5)));
    _attempts++;
    _reconnectTimer = Timer(delay, connect);
  }

  Future<void> _teardownSocket() async {
    _heartbeat?.cancel();
    await _sub?.cancel();
    _sub = null;
    try {
      await _ch?.sink.close(1000);
    } catch (_) {}
    _ch = null;
  }

  void _setStatus(DiscordStatus s) {
    if (status == s) return;
    status = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _userClosed = true;
    _reconnectTimer?.cancel();
    _teardownSocket();
    super.dispose();
  }
}

/// ---------------------------------------------------------------------------
/// Android foreground service: keeps the process (and the gateway socket)
/// alive while the app is backgrounded.
///
/// AndroidManifest.xml additions:
///   <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
///   <uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC"/>
///   <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
///   <uses-permission android:name="android.permission.WAKE_LOCK"/>
///   <uses-permission android:name="android.permission.INTERNET"/>
///   <service android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
///            android:foregroundServiceType="dataSync" android:exported="false"/>
/// ---------------------------------------------------------------------------
class DiscordBackground {
  static bool _inited = false;

  static void init() {
    if (_inited) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'anichan_rpc',
        channelName: 'AniChan Discord Presence',
        channelDescription: 'Keeps Discord Rich Presence connected.',
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _inited = true;
  }

  static Future<void> start() async {
    init();
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      notificationTitle: 'AniChan',
      notificationText: 'Discord Rich Presence active',
      callback: _startCallback,
    );
  }

  static Future<void> stop() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }
}

@pragma('vm:entry-point')
void _startCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveHandler());
}

class _KeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {}

  @override
  void onRepeatEvent(DateTime timestamp, SendPort? sendPort) {}

  @override
  Future<void> onDestroy(DateTime timestamp, SendPort? sendPort) async {}
}
