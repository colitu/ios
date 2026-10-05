import 'package:colitu_vpn/colitu/api/models/subscription_models.dart';
import 'package:colitu_vpn/colitu/api/models/user_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('decodes the live billing catalog plan contract', () {
    final plan = BillingPlan.fromJson({
      'duration_months': 12,
      'price_per_device_minor': 240000,
      'regular_price_per_device_minor': 300000,
      'discount_percent': 20,
      'effective_monthly_minor': 20000,
      'saving_per_device_minor': 60000,
      'badge': 'BEST_VALUE',
    });

    expect(plan.durationMonths, 12);
    expect(plan.discountPercent, 20);
    expect(plan.badge, 'BEST_VALUE');
  });

  test('decodes nested subscription plan and trial status', () {
    final snapshot = SubscriptionSnapshot.fromJson({
      'status': 'trialing',
      'plan': {'id': 'plan-1', 'name': 'Colitu Plus'},
      'current_period_end': '2026-09-15T12:00:00Z',
    });

    expect(snapshot.isActive, isTrue);
    expect(snapshot.productId, 'plan-1');
    expect(snapshot.planName, 'Colitu Plus');
    expect(snapshot.expiresAt, DateTime.utc(2026, 9, 15, 12));
  });
}
