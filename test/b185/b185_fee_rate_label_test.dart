import 'package:fielloop/models/invoice_payment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('B185 Platform Fee rate label', () {
    test('flag on: real rate, up to 2 decimals, trailing zeros trimmed', () {
      expect(platformFeeRatePercent(enabled: true, feeRate: 0.0195), '1.95');
      expect(platformFeeRatePercent(enabled: true, feeRate: 0.02), '2');
      expect(platformFeeRatePercent(enabled: true, feeRate: 0.025), '2.5');
    });

    test('flag off: the old 1-decimal text', () {
      expect(platformFeeRatePercent(enabled: false, feeRate: 0.0195), '1.9');
      expect(platformFeeRatePercent(enabled: false, feeRate: 0.02), '2.0');
      expect(platformFeeRatePercent(enabled: false, feeRate: 0.025), '2.5');
    });
  });
}
