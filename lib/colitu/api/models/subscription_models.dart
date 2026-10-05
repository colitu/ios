class BillingProduct {
  final String id;
  final String name;
  final String? description;
  final String? price;
  final String? period;

  const BillingProduct({
    required this.id,
    required this.name,
    this.description,
    this.price,
    this.period,
  });

  factory BillingProduct.fromJson(Map<String, dynamic> json) {
    return BillingProduct(
      id: '${json['id'] ?? json['productId'] ?? ''}',
      name: '${json['name'] ?? json['title'] ?? ''}',
      description: json['description'] as String?,
      price: json['price'] as String?,
      period: json['period'] as String?,
    );
  }
}

class BillingPlan {
  final int durationMonths;
  final int pricePerDeviceMinor;
  final int regularPricePerDeviceMinor;
  final int discountPercent;
  final int effectiveMonthlyMinor;
  final int savingPerDeviceMinor;
  final String? badge;

  const BillingPlan({
    required this.durationMonths,
    required this.pricePerDeviceMinor,
    required this.regularPricePerDeviceMinor,
    required this.discountPercent,
    required this.effectiveMonthlyMinor,
    required this.savingPerDeviceMinor,
    this.badge,
  });

  factory BillingPlan.fromJson(Map<String, dynamic> json) {
    final duration = _integer(json, 'duration_months');
    final price = _integer(json, 'price_per_device_minor');
    final regular = _integer(json, 'regular_price_per_device_minor');
    final discount = _integer(json, 'discount_percent');
    final monthly = _integer(json, 'effective_monthly_minor');
    final saving = _integer(json, 'saving_per_device_minor');
    final badge = json['badge'];
    if (duration < 1 ||
        price < 1 ||
        regular < price ||
        discount < 0 ||
        discount > 100 ||
        monthly < 1 ||
        saving != regular - price ||
        (badge != null && badge is! String)) {
      throw const FormatException('Invalid billing plan');
    }
    return BillingPlan(
      durationMonths: duration,
      pricePerDeviceMinor: price,
      regularPricePerDeviceMinor: regular,
      discountPercent: discount,
      effectiveMonthlyMinor: monthly,
      savingPerDeviceMinor: saving,
      badge: badge as String?,
    );
  }
}

class BillingMethod {
  final String key;
  final String displayName;
  final int commissionBps;
  final bool supportsOneTime;

  const BillingMethod({
    required this.key,
    required this.displayName,
    required this.commissionBps,
    required this.supportsOneTime,
  });

  factory BillingMethod.fromJson(Map<String, dynamic> json) {
    final key = json['key'];
    final displayName = json['display_name'];
    final enabled = json['enabled'];
    final supportsOneTime = json['supports_one_time'];
    final bps = _integer(json, 'commission_bps');
    if (key is! String ||
        key.isEmpty ||
        displayName is! String ||
        displayName.isEmpty ||
        enabled != true ||
        supportsOneTime is! bool ||
        bps < 0 ||
        bps >= 10000) {
      throw const FormatException('Invalid billing payment method');
    }
    return BillingMethod(
      key: key,
      displayName: displayName,
      commissionBps: bps,
      supportsOneTime: supportsOneTime,
    );
  }
}

class BillingQuote {
  final int regularMinor;
  final int packageMinor;
  final int commissionMinor;
  final int commissionBps;
  final int totalMinor;
  final int discountMinor;

  const BillingQuote({
    required this.regularMinor,
    required this.packageMinor,
    required this.commissionMinor,
    required this.commissionBps,
    required this.totalMinor,
    required this.discountMinor,
  });

  factory BillingQuote.fromJson(Map<String, dynamic> json) {
    final commission = json['commission'];
    if (commission is! Map<String, dynamic>) {
      throw const FormatException('Invalid billing quote commission');
    }
    final regular = _integer(json, 'regular_price_minor');
    final package = _integer(json, 'package_price_minor');
    final discount = _integer(json, 'discount_minor');
    final commissionMinor = _integer(commission, 'amount_minor');
    final commissionBps = _integer(commission, 'rate_bps');
    final total = _integer(json, 'customer_total_minor');
    if (regular < package ||
        package < 1 ||
        discount != regular - package ||
        commissionMinor < 0 ||
        commissionBps < 0 ||
        commissionBps >= 10000 ||
        total != package + commissionMinor) {
      throw const FormatException('Invalid billing quote');
    }
    return BillingQuote(
      regularMinor: regular,
      packageMinor: package,
      commissionMinor: commissionMinor,
      commissionBps: commissionBps,
      totalMinor: total,
      discountMinor: discount,
    );
  }
}

class BillingCheckout {
  final String orderId;
  final String redirectUrl;
  final String status;

  const BillingCheckout({
    required this.orderId,
    required this.redirectUrl,
    required this.status,
  });

  factory BillingCheckout.fromJson(Map<String, dynamic> json) {
    final orderId = json['order_id'];
    final redirectUrl = json['redirect_url'];
    final status = json['status'];
    if (orderId is! String ||
        orderId.isEmpty ||
        redirectUrl is! String ||
        redirectUrl.isEmpty ||
        status is! String ||
        status.isEmpty) {
      throw const FormatException('Invalid billing checkout');
    }
    return BillingCheckout(
      orderId: orderId,
      redirectUrl: redirectUrl,
      status: status,
    );
  }
}

int _integer(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is int) return value;
  throw FormatException('Invalid integer field: $key');
}
