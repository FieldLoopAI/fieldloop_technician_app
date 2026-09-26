import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fielloop/models/mock_job.dart';
import 'package:fielloop/providers/job_runtime_provider.dart';
import 'package:fielloop/widgets/app_components.dart';
import 'package:fielloop/widgets/job_card.dart';
import 'package:fielloop/widgets/status_pill.dart';

MockJob _job({String? customer, String address = '1234 Very Long Street Name, Apt 5B, Springfield, IL 62704'}) =>
    MockJob.fromMap({
      'id': 'job-x',
      'status': 'on_site',
      'scheduled_start': '2026-09-24T14:30:00Z',
      'job_id_public': 'FL-1042',
      'service_address': address,
      'trade_category': 'Plumbing',
      'description': 'Replace the corroded shutoff valve under the kitchen sink and test for leaks',
      if (customer != null) 'customers': {'household_name': customer},
    });

Future<void> _pump(WidgetTester tester, Widget child, MockJob job) async {
  tester.view.physicalSize = const Size(320, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [jobRuntimeProvider.overrideWith((ref, id) => JobRuntimeController(id, job))],
      child: MaterialApp(
        home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('job card shows the real customer name and fits a narrow phone', (tester) async {
    final job = _job(customer: 'The Montgomery-Richardson Household');
    var taps = 0;
    await _pump(tester, JobCard(job: job, index: 0, onTap: () => taps++), job);
    expect(find.text('The Montgomery-Richardson Household'), findsOneWidget);
    expect(find.text('Customer not on file'), findsNothing);
    await tester.tap(find.text('View Job'));
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('job card shows a muted fallback when there is genuinely no name', (tester) async {
    final job = _job();
    await _pump(tester, JobCard(job: job, index: 0, onTap: () {}), job);
    expect(find.text('Customer not on file'), findsOneWidget);
    expect(find.text('Not provided'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('completed variant renders its Details action', (tester) async {
    final job = _job(customer: 'Dana Ruiz');
    await _pump(tester, JobCard(job: job, index: 0, variant: JobCardVariant.completed, onTap: () {}), job);
    expect(find.text('Details'), findsOneWidget);
    expect(find.text('View Job'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('status pills and settings tiles lay out', (tester) async {
    final job = _job(customer: 'X');
    await _pump(
      tester,
      Column(
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final s in ['scheduled', 'en_route', 'on_site', 'complete', 'invoiced', 'paid', 'closed'])
                StatusPill(status: s),
            ],
          ),
          SettingsGroup(
            children: [
              SettingsTile(icon: Icons.shield_outlined, title: 'Permissions', subtitle: 'Camera, microphone & location', onTap: () {}),
              SettingsTile(icon: Icons.logout_rounded, title: 'Log Out', destructive: true, onTap: () {}),
            ],
          ),
        ],
      ),
      job,
    );
    expect(find.text('En Route'), findsOneWidget);
    expect(find.text('Log Out'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('isProvided treats the model fallback as missing', () {
    expect(isProvided('Not provided'), isFalse);
    expect(isProvided('  '), isFalse);
    expect(isProvided(null), isFalse);
    expect(isProvided('555-0100'), isTrue);
  });
}
