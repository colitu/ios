class ColituUser {
  final String id;
  final String email;
  final String? name;
  final String? phone;
  final String? deviceName;
  final int deviceLimit;
  final bool emailVerified;
  final bool killSwitchEnabled;
  final String? subscriptionStatus;
  final String? plan;
  final DateTime? expiresAt;
  final ColituFreeQuota? freeQuota;
  final bool premiumAllowed;

  const ColituUser({
    required this.id,
    required this.email,
    this.name,
    this.phone,
    this.deviceName,
    this.deviceLimit = 1,
    this.emailVerified = false,
    this.killSwitchEnabled = false,
    this.subscriptionStatus,
    this.plan,
    this.expiresAt,
    this.freeQuota,
    this.premiumAllowed = false,
  });

  bool get hasActiveSubscription {
    final status = subscriptionStatus?.toUpperCase();
    return status == 'ACTIVE' ||
        status == 'TRIALING' ||
        status == 'TRIAL_ACTIVE';
  }

  bool get hasActiveEntitlement {
    final status = subscriptionStatus?.toUpperCase();
    return status == 'ACTIVE' ||
        status == 'TRIALING' ||
        status == 'TRIAL_ACTIVE';
  }

  bool get canUsePremiumServers => hasActiveSubscription && premiumAllowed;

  factory ColituUser.fromJson(Map<String, dynamic> json) {
    final userJson = json['user'];
    final source = userJson is Map<String, dynamic> ? userJson : json;
    final subscriptionJson = json['subscription'];
    final subscription = subscriptionJson is Map<String, dynamic>
        ? SubscriptionSnapshot.fromJson(subscriptionJson)
        : null;
    final freeQuotaJson = _map(
      source['freeQuota'] ??
          source['free_quota'] ??
          source['quota'] ??
          json['freeQuota'] ??
          json['free_quota'] ??
          json['quota'],
    );
    return ColituUser(
      id: '${source['id'] ?? source['uuid'] ?? ''}',
      email: '${source['email'] ?? ''}',
      name: source['name'] as String?,
      phone: source['phone'] as String?,
      deviceName:
          source['deviceName'] as String? ?? source['device_name'] as String?,
      deviceLimit: _intValue(
        source['deviceLimit'] ?? source['device_limit'],
        fallback: 1,
      ),
      emailVerified:
          source.containsKey('emailVerified') ||
              source.containsKey('email_verified') ||
              source.containsKey('verified')
          ? _bool(
              source['emailVerified'] ??
                  source['email_verified'] ??
                  source['verified'],
            )
          : true,
      killSwitchEnabled: _bool(
        source['killSwitchEnabled'] ?? source['kill_switch_enabled'],
      ),
      subscriptionStatus:
          source['subscriptionStatus'] as String? ??
          source['subscription_status'] as String? ??
          (subscription?.isActive == true ? 'ACTIVE' : null),
      plan:
          source['plan'] as String? ??
          source['planName'] as String? ??
          subscription?.productId,
      expiresAt:
          _date(source['expiresAt'] ?? source['expireAt']) ??
          subscription?.expiresAt,
      freeQuota:
          subscription?.freeQuota ??
          (freeQuotaJson == null
              ? null
              : ColituFreeQuota.fromJson(freeQuotaJson)),
      premiumAllowed:
          subscription?.premiumAllowed ??
          _bool(source['premiumAllowed'] ?? source['premium_allowed']),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'email': email,
    if (name != null) 'name': name,
    if (phone != null) 'phone': phone,
    if (deviceName != null) 'deviceName': deviceName,
    'deviceLimit': deviceLimit,
    'emailVerified': emailVerified,
    'killSwitchEnabled': killSwitchEnabled,
    if (subscriptionStatus != null) 'subscriptionStatus': subscriptionStatus,
    if (plan != null) 'plan': plan,
    if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
    'premiumAllowed': premiumAllowed,
  };

  ColituUser copyWithSubscription(SubscriptionSnapshot snapshot) {
    return ColituUser(
      id: id,
      email: email,
      name: name,
      phone: phone,
      deviceName: deviceName,
      deviceLimit: deviceLimit,
      emailVerified: emailVerified,
      killSwitchEnabled: killSwitchEnabled,
      subscriptionStatus: snapshot.status,
      plan: snapshot.planName ?? plan,
      expiresAt: snapshot.expiresAt ?? expiresAt,
      freeQuota: snapshot.freeQuota,
      premiumAllowed: snapshot.premiumAllowed,
    );
  }
}

class ColituDevice {
  final String id;
  final String name;
  final bool current;
  final String? platform;
  final DateTime? lastActiveAt;

  const ColituDevice({
    required this.id,
    required this.name,
    this.current = false,
    this.platform,
    this.lastActiveAt,
  });

  factory ColituDevice.fromJson(Map<String, dynamic> json) {
    return ColituDevice(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? 'Device'}',
      current: _bool(json['current']),
      platform: json['platform'] is String ? json['platform'] as String : null,
      lastActiveAt: _date(
        json['lastActiveAt'] ?? json['last_active_at'] ?? json['last_seen_at'],
      ),
    );
  }

  ColituDevice markCurrent(bool value) => ColituDevice(
    id: id,
    name: name,
    current: value,
    platform: platform,
    lastActiveAt: lastActiveAt,
  );
}

class ColituFreeQuota {
  final int limitBytes;
  final int usedBytes;
  final int remainingBytes;
  final DateTime? resetAt;

  const ColituFreeQuota({
    required this.limitBytes,
    required this.usedBytes,
    required this.remainingBytes,
    this.resetAt,
  });

  double get usedRatio {
    if (limitBytes <= 0) {
      return 0;
    }
    return (usedBytes / limitBytes).clamp(0, 1).toDouble();
  }

  int get remainingMegabytes => (remainingBytes / 1048576).floor();

  factory ColituFreeQuota.fromJson(Map<String, dynamic> json) {
    final limit = _intValue(
      json['limitBytes'] ??
          json['limit_bytes'] ??
          json['dailyLimitBytes'] ??
          json['daily_limit_bytes'],
      fallback: 209715200,
    );
    final used = _intValue(
      json['usedBytes'] ??
          json['used_bytes'] ??
          json['usageBytes'] ??
          json['usage_bytes'] ??
          json['dataUsedBytes'] ??
          json['data_used_bytes'],
      fallback: 0,
    );
    final remaining = _intValue(
      json['remainingBytes'] ??
          json['remaining_bytes'] ??
          json['leftBytes'] ??
          json['left_bytes'],
      fallback: limit - used,
    );
    return ColituFreeQuota(
      limitBytes: limit,
      usedBytes: used,
      remainingBytes: remaining.clamp(0, limit).toInt(),
      resetAt: _date(json['resetAt'] ?? json['reset_at']),
    );
  }
}

class SubscriptionSnapshot {
  final String status;
  final String? productId;
  final String? planName;
  final DateTime? expiresAt;
  final ColituFreeQuota? freeQuota;
  final bool premiumAllowed;

  const SubscriptionSnapshot({
    required this.status,
    this.productId,
    this.planName,
    this.expiresAt,
    this.freeQuota,
    this.premiumAllowed = false,
  });

  bool get isActive {
    final normalized = status.toUpperCase();
    return normalized == 'ACTIVE' ||
        normalized == 'TRIALING' ||
        normalized == 'TRIAL_ACTIVE';
  }

  factory SubscriptionSnapshot.fromJson(Map<String, dynamic> json) {
    final planJson = _map(json['plan']);
    final freeQuotaJson = _map(
      json['freeQuota'] ?? json['free_quota'] ?? json['quota'],
    );
    return SubscriptionSnapshot(
      status: json['active'] == true
          ? 'ACTIVE'
          : '${json['status'] ?? json['subscriptionStatus'] ?? 'UNKNOWN'}',
      productId:
          json['productId'] as String? ??
          json['product_id'] as String? ??
          planJson?['id'] as String?,
      planName:
          json['planName'] as String? ??
          json['plan_name'] as String? ??
          (json['plan'] is String ? json['plan'] as String : null) ??
          planJson?['name'] as String? ??
          json['tier'] as String?,
      expiresAt: _date(
        json['expiresAt'] ??
            json['expireAt'] ??
            json['current_period_end'],
      ),
      freeQuota: freeQuotaJson == null
          ? null
          : ColituFreeQuota.fromJson(freeQuotaJson),
      premiumAllowed: _bool(json['premiumAllowed'] ?? json['premium_allowed']),
    );
  }
}

DateTime? _date(Object? value) {
  if (value is String && value.isNotEmpty) {
    return DateTime.tryParse(value);
  }
  return null;
}

Map<String, dynamic>? _map(Object? value) {
  return value is Map<String, dynamic> ? value : null;
}

int _intValue(Object? value, {required int fallback}) {
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value) ?? fallback;
  }
  return fallback;
}

bool _bool(Object? value) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  if (value is String) {
    final normalized = value.toLowerCase().trim();
    return normalized == 'true' || normalized == '1' || normalized == 'yes';
  }
  return false;
}
