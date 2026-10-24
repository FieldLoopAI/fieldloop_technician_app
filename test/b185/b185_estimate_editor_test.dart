import 'package:fielloop/models/change_order.dart';
import 'package:fielloop/models/invoice_payment.dart';
import 'package:fielloop/models/job_estimate.dart';
import 'package:fielloop/models/mock_job.dart';
import 'package:fielloop/providers/global_voice_service_provider.dart';
import 'package:fielloop/providers/invoice_provider.dart';
import 'package:fielloop/providers/job_change_orders_provider.dart';
import 'package:fielloop/providers/job_estimate_provider.dart';
import 'package:fielloop/providers/jobs_provider.dart';
import 'package:fielloop/screens/estimate_screen.dart';
import 'package:fielloop/screens/job_detail_screen.dart';
import 'package:fielloop/widgets/primary_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Estimate screens: which row is shown (voided rows skipped, a declined
/// estimate replaced by a newer draft), "Create a new estimate" after a
/// decline, the draft editor's checks, cents rounding, quantity/unit price,
/// the send confirmation, the unsaved-changes warning and the locked state.

const _jobId = 'job-1';

class _FakeVoice extends GlobalVoiceService {
  _FakeVoice(super.ref);

  @override
  Future<void> speak(String text) async {}

  @override
  void exitJobScope() {}

  @override
  Future<void> enterJobScope() async {}
}

JobEstimate _estimate(
  String id,
  String status, {
  bool voided = false,
  List<Map<String, dynamic>>? lines,
  num total = 100,
}) => JobEstimate.fromJson({
  'id': id,
  'job_id': _jobId,
  'status': status,
  'total_amount': total,
  'line_items':
      lines ??
      [
        {'description': 'Work', 'amount': total},
      ],
  'voided_at': voided ? '2026-10-20T10:00:00Z' : null,
  'void_reason': voided ? 'Scope changed' : null,
});

/// A draft with a 3 × $50 line (typed on the manual form) and a $80 line
/// with no quantity (dictated).
JobEstimate _draft() => _estimate(
  'est-1',
  'draft',
  total: 230,
  lines: [
    {'description': 'Valve', 'amount': 150, 'quantity': 3, 'unit_price': 50},
    {'description': 'Labor', 'amount': 80},
  ],
);

class _FakeEstimate extends StateNotifier<AsyncValue<JobEstimate?>> implements JobEstimateController {
  _FakeEstimate(JobEstimate? estimate) : super(AsyncData(estimate));

  final saves = <({List<EstimateLineItem> items, double total})>[];
  var sends = 0;

  @override
  Future<void> saveLineItems({
    required String estimateId,
    required List<EstimateLineItem> lineItems,
    required double totalAmount,
  }) async {
    saves.add((items: lineItems, total: totalAmount));
    state = AsyncData(state.value!.copyWith(lineItems: lineItems, totalAmount: totalAmount));
  }

  @override
  Future<String> sendToCustomer(String estimateId, {void Function(String status)? onStatus}) async {
    sends++;
    state = AsyncData(state.value!.copyWith(status: 'sent'));
    return 'Pat';
  }

  @override
  Future<void> refresh() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeChangeOrders extends StateNotifier<AsyncValue<List<ChangeOrder>>> implements JobChangeOrdersController {
  _FakeChangeOrders() : super(const AsyncData([]));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LatestInvoicePayment _latest(String paymentStatus) => LatestInvoicePayment.fromResponse({
  'invoice': {'id': 'inv-1', 'invoice_number': 'INV-1', 'payment_status': paymentStatus, 'paid_at': null, 'total': 100},
})!;

/// Opens [EstimateScreen] from a host route (so back navigation can be
/// tested) with [estimate] as the job's shown estimate.
Future<_FakeEstimate> _pumpScreen(WidgetTester tester, JobEstimate? estimate, {String paymentStatus = 'unpaid'}) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fake = _FakeEstimate(estimate);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        globalVoiceServiceProvider.overrideWith(_FakeVoice.new),
        jobByIdProvider.overrideWith((ref, id) => null),
        latestInvoicePaymentProvider.overrideWith((ref, jobId) => Future.value(_latest(paymentStatus))),
        jobEstimateProvider.overrideWith((ref, jobId) => fake),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: (_) => const EstimateScreen(jobId: _jobId))),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await _settle(tester);
  return fake;
}

const _send = 'Looks good, send to customer';
const _save = 'Save changes without sending';

bool _sendEnabled(WidgetTester tester) => tester.widget<PrimaryButton>(find.byType(PrimaryButton)).onPressed != null;

bool _saveEnabled(WidgetTester tester) => tester
    .widget<ButtonStyleButton>(
      find.ancestor(of: find.text(_save), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)),
    )
    .enabled;

Finder _field(String text) => find.widgetWithText(TextField, text);

Future<void> _enter(WidgetTester tester, String current, String next) async {
  await tester.enterText(_field(current), next);
  await tester.pump();
}

Future<void> _tapSave(WidgetTester tester) async {
  await tester.tap(find.text(_save));
  await _settle(tester);
}

/// The selection rule before this change: newest sent/approved/declined row,
/// else the newest row; voided rows included.
JobEstimate? _previousRule(List<JobEstimate> newestFirst) {
  if (newestFirst.isEmpty) return null;
  final decided = newestFirst.where((e) => {'sent', 'approved', 'declined'}.contains(e.status));
  return decided.isNotEmpty ? decided.first : newestFirst.first;
}

void main() {
  group('selectDisplayedEstimate', () {
    test('a voided row is ignored; only voided rows means no estimate', () {
      expect(selectDisplayedEstimate([_estimate('a', 'approved', voided: true)]), isNull);
      expect(selectDisplayedEstimate(const []), isNull);
    });

    test('after a void, the newer estimate is shown', () {
      final shown = selectDisplayedEstimate([_estimate('new', 'draft'), _estimate('old', 'approved', voided: true)]);
      expect(shown?.id, 'new');
      final sent = selectDisplayedEstimate([_estimate('new', 'sent'), _estimate('old', 'approved', voided: true)]);
      expect(sent?.id, 'new');
    });

    test('after a decline, a newer draft replaces it; without one the declined row stays', () {
      expect(selectDisplayedEstimate([_estimate('new', 'draft'), _estimate('old', 'declined')])?.id, 'new');
      expect(selectDisplayedEstimate([_estimate('d', 'declined'), _estimate('older', 'draft')])?.id, 'd');
    });

    test('an approved estimate still wins over a newer draft (voice prefetch still sees it approved)', () {
      final shown = selectDisplayedEstimate([_estimate('new', 'draft'), _estimate('old', 'approved')]);
      expect(shown?.id, 'old');
      expect(shown?.isApproved, isTrue);
    });

    test('unchanged from the previous rule whenever no row is voided and no draft follows a decline', () {
      const statuses = ['draft', 'sent', 'approved', 'declined'];
      var compared = 0;
      void check(List<String> sequence) {
        final rows = [for (var i = 0; i < sequence.length; i++) _estimate('r$i', sequence[i])];
        final before = _previousRule(rows);
        if (before != null && before.isDeclined && rows.first.id != before.id) return;
        compared++;
        expect(selectDisplayedEstimate(rows)?.id, before?.id, reason: sequence.join(','));
      }

      for (final a in statuses) {
        check([a]);
        for (final b in statuses) {
          check([a, b]);
          for (final c in statuses) {
            check([a, b, c]);
          }
        }
      }
      expect(compared, greaterThan(60));
    });
  });

  group('declined estimate', () {
    testWidgets('Estimate screen offers Create a new estimate, which opens the manual form', (tester) async {
      await _pumpScreen(tester, _estimate('d', 'declined'));
      expect(find.text('Declined'), findsOneWidget);
      await tester.tap(find.text('Create a new estimate'));
      await _settle(tester);
      expect(find.text('New Estimate'), findsOneWidget);
    });

    testWidgets('paid: Create a new estimate is disabled with the lock message', (tester) async {
      await _pumpScreen(tester, _estimate('d', 'declined'), paymentStatus: 'paid');
      final button = tester.widget<ButtonStyleButton>(
        find.ancestor(
          of: find.text('Create a new estimate'),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        ),
      );
      expect(button.enabled, isFalse);
      expect(find.text(kPaymentLockedMessage), findsOneWidget);
    });

    testWidgets('approved and sent estimates do not offer it', (tester) async {
      await _pumpScreen(tester, _estimate('a', 'approved'));
      expect(find.text('Create a new estimate'), findsNothing);
    });

    testWidgets('Job Details Estimate tab offers Create a new estimate for a declined estimate', (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final job = MockJob(
        id: _jobId,
        jobIdPublic: 'FL-1',
        customerName: 'Test Customer',
        serviceAddress: '1 Main St',
        description: 'Leak',
        tradeCategory: 'plumbing',
        status: JobStatus.onSite,
        scheduledStart: DateTime(2026, 10, 24, 9),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            latestInvoicePaymentProvider.overrideWith((ref, jobId) => Future.value(_latest('unpaid'))),
            jobByIdProvider.overrideWith((ref, id) => null),
            jobEstimateProvider.overrideWith((ref, jobId) => _FakeEstimate(_estimate('d', 'declined'))),
            jobChangeOrdersProvider.overrideWith((ref, jobId) => _FakeChangeOrders()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: jobDetailMoneyTabForTesting(job: job, changeOrders: false, voiceEligible: true),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Create a new estimate'), findsOneWidget);
      expect(find.text('View Full Estimate'), findsOneWidget);
    });
  });

  group('draft editor checks', () {
    testWidgets('an amount without a description is not dropped: message shown, buttons disabled', (tester) async {
      final fake = await _pumpScreen(tester, _draft());
      expect(_sendEnabled(tester), isTrue);
      await _enter(tester, 'Labor', '');
      expect(find.text('Add a description for every line.'), findsOneWidget);
      expect(_sendEnabled(tester), isFalse);
      expect(_saveEnabled(tester), isFalse);
      expect(fake.saves, isEmpty);
    });

    testWidgets('a description without an amount shows its message', (tester) async {
      await _pumpScreen(tester, _draft());
      await _enter(tester, '80.00', '');
      expect(find.text('Add an amount for every line.'), findsOneWidget);
      expect(_sendEnabled(tester), isFalse);
    });

    testWidgets('negative, zero, NaN, Infinity and \$1,000,000+ amounts are refused', (tester) async {
      await _pumpScreen(tester, _draft());
      const message = 'Each line amount must be more than \$0.00 and less than \$1,000,000.00.';
      var current = '80.00';
      for (final bad in ['-5', '0', 'NaN', 'Infinity', '1000000', '1e9']) {
        await _enter(tester, current, bad);
        current = bad;
        expect(find.text(message), findsOneWidget, reason: bad);
        expect(_sendEnabled(tester), isFalse, reason: bad);
        expect(_saveEnabled(tester), isFalse, reason: bad);
      }
      await _enter(tester, current, '999999.99');
      expect(find.text(message), findsNothing);
      expect(_sendEnabled(tester), isTrue);
    });

    testWidgets('removing every line shows the at-least-one-line message', (tester) async {
      await _pumpScreen(tester, _draft());
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byTooltip('Remove line item').first);
        await tester.pump();
      }
      expect(find.text('Add at least one line item before saving.'), findsOneWidget);
      expect(_sendEnabled(tester), isFalse);
    });

    testWidgets('a fully blank added row is skipped, not an error', (tester) async {
      final fake = await _pumpScreen(tester, _draft());
      await tester.tap(find.text('Add line item'));
      await tester.pump();
      expect(_saveEnabled(tester), isTrue);
      await _tapSave(tester);
      expect(fake.saves.single.items.length, 2);
    });

    testWidgets('amounts and the total are rounded to cents before saving', (tester) async {
      final fake = await _pumpScreen(tester, _draft());
      await _enter(tester, '80.00', '19.999');
      await _enter(tester, '150.00', '0.333');
      await _tapSave(tester);
      final saved = fake.saves.single;
      expect(saved.items.map((i) => i.amount), [0.33, 20.0]);
      expect(saved.total, 20.33);
    });

    testWidgets('the remove target is at least 48dp', (tester) async {
      await _pumpScreen(tester, _draft());
      final size = tester.getSize(find.byTooltip('Remove line item').first);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    });
  });

  group('quantity and unit price', () {
    testWidgets('an unchanged amount keeps its quantity and unit price, with the hint shown', (tester) async {
      final fake = await _pumpScreen(tester, _draft());
      expect(find.text('3 × \$50.00'), findsOneWidget);
      await _enter(tester, 'Valve', 'Brass valve');
      await _tapSave(tester);
      final valve = fake.saves.single.items.first;
      expect(valve.description, 'Brass valve');
      expect(valve.amount, 150);
      expect(valve.quantity, 3);
      expect(valve.unitPrice, 50);
      // The dictated line had no quantity and keeps none.
      expect(fake.saves.single.items[1].quantity, isNull);
    });

    testWidgets('an edited amount saves as 1 × the new amount, and the hint goes away', (tester) async {
      final fake = await _pumpScreen(tester, _draft());
      await _enter(tester, '150.00', '160');
      expect(find.text('3 × \$50.00'), findsNothing);
      await _tapSave(tester);
      final valve = fake.saves.single.items.first;
      expect(valve.amount, 160);
      expect(valve.quantity, 1);
      expect(valve.unitPrice, 160);
    });

    testWidgets('the read-only finalized view shows the hint too', (tester) async {
      await _pumpScreen(
        tester,
        _estimate(
          's',
          'sent',
          lines: [
            {'description': 'Valve', 'amount': 150, 'quantity': 3, 'unit_price': 50},
          ],
        ),
      );
      expect(find.text('3 × \$50.00'), findsOneWidget);
    });
  });

  group('send confirmation', () {
    testWidgets('Cancel sends nothing; Send saves then sends', (tester) async {
      final fake = await _pumpScreen(tester, _draft());
      await tester.tap(find.text(_send));
      await _settle(tester);
      expect(find.text('Send this estimate of \$230.00 to the customer?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await _settle(tester);
      expect(fake.saves, isEmpty);
      expect(fake.sends, 0);

      await tester.tap(find.text(_send));
      await _settle(tester);
      await tester.tap(find.text('Send'));
      await tester.pump();
      await tester.pump();
      expect(fake.saves.length, 1);
      expect(fake.sends, 1);
      await tester.pump(const Duration(seconds: 2));
      await _settle(tester);
      expect(find.text('Sent — awaiting customer'), findsOneWidget);
    });
  });

  group('unsaved changes', () {
    testWidgets('leaving with edits asks first; Keep editing stays, Discard leaves', (tester) async {
      await _pumpScreen(tester, _draft());
      await _enter(tester, 'Labor', 'Labour');
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(find.text('Discard your changes?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await _settle(tester);
      expect(find.text('Itemized Estimate'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await _settle(tester);
      await tester.tap(find.text('Discard'));
      await _settle(tester);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('no warning without edits, or once the edits are saved', (tester) async {
      await _pumpScreen(tester, _draft());
      await _enter(tester, 'Labor', 'Labour');
      await _tapSave(tester);
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(find.text('Discard your changes?'), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });
  });

  group('locked draft editor', () {
    testWidgets('paid: fields are read-only, remove and actions disabled, message shown', (tester) async {
      await _pumpScreen(tester, _draft(), paymentStatus: 'paid');
      expect(find.text(kPaymentLockedMessage), findsOneWidget);
      await tester.tap(_field('Labor'), warnIfMissed: false);
      await tester.pump();
      final editable = tester.state<EditableTextState>(
        find.descendant(of: _field('Labor'), matching: find.byType(EditableText)),
      );
      expect(editable.widget.focusNode.hasFocus, isFalse);
      final removes = tester.widgetList<IconButton>(
        find.ancestor(of: find.byIcon(Icons.close_rounded), matching: find.byType(IconButton)),
      );
      expect(removes.every((b) => b.onPressed == null), isTrue);
      expect(_sendEnabled(tester), isFalse);
      expect(_saveEnabled(tester), isFalse);
    });

    testWidgets('unpaid: the same field takes focus', (tester) async {
      await _pumpScreen(tester, _draft());
      await tester.tap(_field('Labor'));
      await tester.pump();
      final editable = tester.state<EditableTextState>(
        find.descendant(of: _field('Labor'), matching: find.byType(EditableText)),
      );
      expect(editable.widget.focusNode.hasFocus, isTrue);
    });
  });
}

/// EstimateScreen's voice indicator animates forever, so pumpAndSettle
/// never settles: pump through route/dialog transitions instead.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}
