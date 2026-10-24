import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Key-value store behind Colitu Passport, the Dart twin of Android's
/// MMKV "COLITU_PASSPORT_V2". Reads and writes are synchronous (the rules run
/// in one go per minute); [PrefsPassportStore] saves to the app's
/// preferences in the background. Everything stays on this device.
class PassportStore {
  PassportStore([Map<String, Object>? data]) : _data = data ?? {};

  final Map<String, Object> _data;

  int getInt(String key, [int fallback = 0]) {
    final value = _data[key];
    return value is int ? value : fallback;
  }

  String? getString(String key) {
    final value = _data[key];
    return value is String ? value : null;
  }

  bool getBool(String key, [bool fallback = false]) {
    final value = _data[key];
    return value is bool ? value : fallback;
  }

  bool contains(String key) => _data.containsKey(key);

  void setInt(String key, int value) => _put(key, value);

  void setString(String key, String value) => _put(key, value);

  void setBool(String key, bool value) => _put(key, value);

  void remove(String key) {
    if (_data.remove(key) != null) changed();
  }

  void clear() {
    _data.clear();
    changed();
  }

  void _put(String key, Object value) {
    if (_data[key] == value) return;
    _data[key] = value;
    changed();
  }

  /// A copy of everything, for saving.
  Map<String, Object> snapshot() => Map.of(_data);

  /// Called after every change; the preferences store saves from here.
  void changed() {}
}

/// [PassportStore] kept as one JSON value in the app preferences.
class PrefsPassportStore extends PassportStore {
  PrefsPassportStore._(super.data);

  static const prefsKey = 'colitu_passport_v2';

  static Future<PrefsPassportStore> load() async {
    final data = <String, Object>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw != null) {
        final json = jsonDecode(raw);
        if (json is Map<String, dynamic>) {
          json.forEach((key, value) {
            if (value is int || value is String || value is bool) data[key] = value as Object;
          });
        }
      }
    } catch (_) {
      // A broken value starts an empty passport rather than a crash.
    }
    return PrefsPassportStore._(data);
  }

  var _scheduled = false;

  @override
  void changed() {
    if (_scheduled) return;
    _scheduled = true;
    // One save per burst of changes (a tick writes a dozen keys).
    scheduleMicrotask(() async {
      _scheduled = false;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(prefsKey, jsonEncode(snapshot()));
      } catch (_) {}
    });
  }
}
