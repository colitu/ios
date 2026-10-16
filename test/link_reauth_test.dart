import 'package:colitu_vpn/colitu/api/api_error.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_errors.dart';
import 'package:colitu_vpn/colitu/l10n/colitu_loc.dart';
import 'package:colitu_vpn/colitu/services/auth_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ColituLoc.I.setLanguage('en', persist: false);
  });

  test('lookup answer carries reauth, countries and the mismatch flag', () {
    final r = LinkRequest.fromJson({
      'code': 'ABCD2345',
      'device_name': 'TV',
      'platform': 'android',
      'country': 'DE',
      'approver_country': 'TR',
      'country_mismatch': true,
      'reauth': 'mfa',
    });
    expect(r.country, 'DE');
    expect(r.approverCountry, 'TR');
    expect(r.countryMismatch, isTrue);
    expect(r.reauth, 'mfa');
    expect(LinkRequest.fromJson({'reauth': 'password'}).reauth, 'password');
  });

  test('an older panel keeps today\'s behaviour', () {
    final r = LinkRequest.fromJson({'code': 'ABCD2345', 'device_name': 'TV', 'platform': 'android'});
    expect(r.reauth, isNull);
    expect(r.approverCountry, isNull);
    expect(r.countryMismatch, isFalse);
    expect(LinkRequest.fromJson({'reauth': 'fingerprint'}).reauth, isNull);
  });

  test('approve sends the proof the lookup named, deny sends none', () {
    expect(linkDecisionBody('ABCD2345', approve: true, reauth: 'password', proof: 'secret'), {'code': 'ABCD2345', 'password': 'secret'});
    expect(linkDecisionBody('ABCD2345', approve: true, reauth: 'mfa', proof: ' 123456 '), {'code': 'ABCD2345', 'mfa_code': '123456'});
    expect(linkDecisionBody('ABCD2345', approve: true), {'code': 'ABCD2345'});
    expect(linkDecisionBody('ABCD2345', approve: false, reauth: 'mfa', proof: '123456'), {'code': 'ABCD2345'});
  });

  test('reauth errors have their own messages and are not a session end', () {
    final loc = ColituLoc.I;
    const cases = {
      'REAUTH_REQUIRED': 'link.err.reauthRequired',
      'REAUTH_INVALID_PASSWORD': 'link.err.password',
      'REAUTH_INVALID_CODE': 'link.err.code',
      'REAUTH_RATE_LIMITED': 'link.err.rate',
      'MFA_UNAVAILABLE': 'mfa.err.unavailable',
    };
    cases.forEach((backend, key) {
      final error = APIException(APIErrorCode.subscriptionInactive, 'x', statusCode: 403, backendCode: backend);
      expect(error.terminalAuthFailure, isFalse);
      expect(colituErrorMessage(error), loc[key], reason: backend);
    });
  });
}
