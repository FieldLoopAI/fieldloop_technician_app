import 'package:flutter_test/flutter_test.dart';

import 'package:fielloop/models/mock_job.dart';

/// Regression for "Not provided" showing on every job card: the customer's
/// name lives on the related `customers` row (embedded by the job queries as
/// `customers(household_name)`), not on `jobs` itself.
void main() {
  Map<String, dynamic> row([Map<String, dynamic> extra = const {}]) => {
    'id': 'job-1',
    'status': 'scheduled',
    'scheduled_start': '2026-09-24T14:00:00Z',
    ...extra,
  };

  test('reads the name from the embedded customers row', () {
    final job = MockJob.fromMap(row({'customers': {'household_name': 'The Hendersons'}}));
    expect(job.customerName, 'The Hendersons');
    expect(job.hasCustomerName, isTrue);
  });

  test('a direct customer_name column still wins when present', () {
    final job = MockJob.fromMap(row({'customer_name': 'Dana Ruiz', 'customers': {'household_name': 'Ruiz Household'}}));
    expect(job.customerName, 'Dana Ruiz');
  });

  test('falls back to "Not provided" only when there genuinely is no name', () {
    for (final extra in [
      <String, dynamic>{},
      {'customers': null},
      {'customers': {'household_name': null}},
      {'customers': {'household_name': '   '}},
      {'customer_name': '', 'customers': {'household_name': ''}},
    ]) {
      final job = MockJob.fromMap(row(extra));
      expect(job.customerName, MockJob.notProvided, reason: '$extra');
      expect(job.hasCustomerName, isFalse, reason: '$extra');
    }
  });

  test('job code presence is detectable', () {
    expect(MockJob.fromMap(row({'job_id_public': 'FL-1042'})).hasJobCode, isTrue);
    expect(MockJob.fromMap(row()).hasJobCode, isFalse);
  });
}
