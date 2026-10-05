import 'package:colitu_vpn/colitu/api/api_client.dart';
import 'package:colitu_vpn/colitu/api/api_endpoint.dart';
import 'package:colitu_vpn/colitu/api/models/subscription_models.dart';
import 'package:colitu_vpn/colitu/api/models/user_models.dart';

class ColituSubscriptionService {
  ColituSubscriptionService({APIClient? client})
    : _client = client ?? APIClient();

  final APIClient _client;

  Future<List<BillingPlan>> catalog() {
    return _client.get(APIEndpoint.billingProducts, (json) {
      final root = (json as Map<String, dynamic>)['data'];
      if (root is! Map<String, dynamic> || root['plans'] is! List) {
        throw const FormatException('Invalid billing catalog');
      }
      return (root['plans'] as List)
          .whereType<Map<String, dynamic>>()
          .map(BillingPlan.fromJson)
          .toList();
    }, authenticated: false);
  }

  Future<List<BillingMethod>> paymentMethods() {
    return _client.get(APIEndpoint.billingPaymentMethods, (json) {
      final data = (json as Map<String, dynamic>)['data'];
      if (data is! List) {
        throw const FormatException('Invalid billing payment methods');
      }
      return data
          .whereType<Map<String, dynamic>>()
          .map(BillingMethod.fromJson)
          .where((method) => method.supportsOneTime)
          .toList();
    }, authenticated: false);
  }

  Future<BillingQuote> quote(int months, int devices, String method) {
    return _client.post(
      APIEndpoint.billingQuote,
      (json) {
        final data = (json as Map<String, dynamic>)['data'];
        if (data is! Map<String, dynamic>) {
          throw const FormatException('Invalid billing quote');
        }
        return BillingQuote.fromJson(data);
      },
      data: {
        'duration_months': months,
        'device_count': devices,
        'payment_method': method,
      },
      authenticated: false,
    );
  }

  Future<BillingCheckout> checkout(int months, int devices, String method) {
    return _client.post(
      APIEndpoint.billingCheckout,
      (json) {
        final data = (json as Map<String, dynamic>)['data'];
        if (data is! Map<String, dynamic>) {
          throw const FormatException('Invalid billing checkout');
        }
        return BillingCheckout.fromJson(data);
      },
      data: {
        'duration_months': months,
        'device_count': devices,
        'payment_method': method,
      },
    );
  }

  Future<String> orderStatus(String id) {
    return _client.get(
      '${APIEndpoint.billingOrders}/${Uri.encodeComponent(id)}',
      (json) {
        final data = (json as Map<String, dynamic>)['data'];
        if (data is! Map<String, dynamic>) {
          throw const FormatException('Invalid billing order');
        }
        return '${data['status']}';
      },
    );
  }

  Future<List<BillingProduct>> products() {
    return _client.get(APIEndpoint.billingProducts, (json) {
      final list = _listFromJson(json, 'products');
      return list
          .whereType<Map<String, dynamic>>()
          .map(BillingProduct.fromJson)
          .toList();
    });
  }

  Future<SubscriptionSnapshot> subscription() {
    return _client.get(
      APIEndpoint.subscription,
      (json) {
        final root = json as Map<String, dynamic>;
        final data = root['data'];
        return SubscriptionSnapshot.fromJson(
          data is Map<String, dynamic> ? data : root,
        );
      },
      queryParameters: {'_ts': DateTime.now().millisecondsSinceEpoch},
    );
  }
}

List<dynamic> _listFromJson(Object? json, String key) {
  if (json is List<dynamic>) {
    return json;
  }
  if (json is Map<String, dynamic>) {
    final value = json[key] ?? json['items'] ?? json['data'];
    if (value is List<dynamic>) {
      return value;
    }
  }
  return const [];
}
