import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fielloop/models/invoice_preview.dart';
import 'package:fielloop/models/job_estimate.dart';
import 'package:fielloop/widgets/manual_entry_form.dart';

void main() {
  group('positiveNumberValidator', () {
    final price = positiveNumberValidator('Price');
    final priceAllowZero = positiveNumberValidator('Price', allowZero: true);

    test('blank is required', () => expect(price(''), 'Price is required'));
    test('non-numeric is rejected', () => expect(price('abc'), 'Enter a valid number'));
    test('zero is rejected unless allowed', () {
      expect(price('0'), isNotNull);
      expect(priceAllowZero('0'), isNull);
    });
    test('negative is rejected', () => expect(price('-5'), isNotNull));
    test('positive passes', () => expect(price('12.50'), isNull));
  });

  group('EstimateLineItem JSON', () {
    test('a dictated item (no qty/price) round-trips with only description/amount', () {
      const item = EstimateLineItem(description: 'Replace valve', amount: 120);
      expect(item.toJson(), {'description': 'Replace valve', 'amount': 120.0});
    });

    test('a manual item keeps quantity/unit_price, amount stays the line total', () {
      const item = EstimateLineItem(description: 'Pipe', amount: 36, quantity: 3, unitPrice: 12);
      final json = item.toJson();
      expect(json['amount'], 36);
      expect(json['quantity'], 3);
      expect(json['unit_price'], 12);
      final back = EstimateLineItem.fromJson(json);
      expect(back.quantity, 3);
      expect(back.unitPrice, 12);
    });
  });

  group('InvoicePreview adjustments', () {
    Map<String, dynamic> previewJson({List<Map<String, dynamic>>? adjustments}) => {
      'estimate': {'id': 'e1', 'job_id': 'j1', 'line_items': [], 'total_amount': 100, 'status': 'approved'},
      'grossTotal': 90,
      'adjustments': ?adjustments,
    };

    test('parses signed adjustments and sums them', () {
      final preview = InvoicePreview.fromJson(
        previewJson(
          adjustments: [
            {'id': 'a1', 'job_id': 'j1', 'description': 'Trip fee', 'amount': 15},
            {'id': 'a2', 'job_id': 'j1', 'description': 'Loyalty discount', 'amount': -25},
          ],
        ),
      );
      expect(preview.adjustments, hasLength(2));
      expect(preview.adjustments.last.isDiscount, isTrue);
      expect(preview.adjustmentsTotal, -10);
    });

    test('a backend without adjustments parses as none', () {
      final preview = InvoicePreview.fromJson(previewJson());
      expect(preview.adjustments, isEmpty);
      expect(preview.adjustmentsTotal, 0);
    });
  });

  group('currency input formatting', () {
    final formatter = moneyInputFormatters.single;
    TextEditingValue type(String text) => formatter.formatEditUpdate(
      TextEditingValue.empty,
      TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length)),
    );

    test('groups thousands as you type', () => expect(type('1250.5').text, '1,250.5'));
    test('keeps at most two decimals', () => expect(type('12.345').text, isEmpty));
    test('rejects a minus sign', () => expect(type('-5').text, isEmpty));
    test('caret stays at the end', () => expect(type('1234567').selection.baseOffset, '1,234,567'.length));
    test('parseAmount ignores the grouping commas', () => expect(parseAmount('1,250.50'), 1250.5));
  });
}
