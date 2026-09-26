import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fielloop/models/job_history_entry.dart';
import 'package:fielloop/theme/design_tokens.dart';
import 'package:fielloop/widgets/approval_status_pill.dart';
import 'package:fielloop/widgets/empty_state_actions.dart';
import 'package:fielloop/widgets/job_history_feed_timeline.dart';
import 'package:fielloop/widgets/manual_entry_form.dart';

/// Layout smoke tests for the shared design-system widgets at a narrow
/// phone width (320dp) — any RenderFlex overflow fails the test.
Future<void> pumpNarrow(WidgetTester tester, Widget child, {Widget? bottomBar}) async {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        bottomNavigationBar: bottomBar,
        body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('empty state with its action fits a narrow phone', (tester) async {
    await pumpNarrow(
      tester,
      EmptyStateActions(
        icon: Icons.post_add_rounded,
        title: 'No change orders yet',
        hint: 'Add extra work found on site. The customer is texted to approve it before it counts toward the total.',
        actionLabel: 'Add Change Order',
        onAction: () {},
      ),
    );
    expect(find.text('Add Change Order'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('every approval status renders its pill', (tester) async {
    await pumpNarrow(
      tester,
      const Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          ApprovalStatusPill(status: 'pending'),
          ApprovalStatusPill(status: 'approved'),
          ApprovalStatusPill(status: 'declined'),
          ApprovalStatusPill(status: 'approved', voided: true),
        ],
      ),
    );
    for (final label in ['Pending approval', 'Approved', 'Declined', 'Voided']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('sticky bar: Save disabled when invalid, enabled when valid', (tester) async {
    var saved = false;
    await pumpNarrow(
      tester,
      const SizedBox(height: 10),
      bottomBar: StickyActionBar(
        saveLabel: 'Save & Request Approval',
        onSave: null,
        onCancel: () {},
        summary: const Row(children: [Text('Additional cost'), Spacer(), Text(r'$0.00')]),
      ),
    );
    await tester.tap(find.text('Save & Request Approval'));
    expect(saved, isFalse);

    await pumpNarrow(
      tester,
      const SizedBox(height: 10),
      bottomBar: StickyActionBar(saveLabel: 'Save Estimate', onSave: () => saved = true, onCancel: () {}),
    );
    await tester.tap(find.text('Save Estimate'));
    expect(saved, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('timeline renders photo, voided and plain entries', (tester) async {
    final now = DateTime(2026, 9, 24, 14, 5);
    await pumpNarrow(
      tester,
      JobHistoryFeedTimeline(
        onTapPhoto: (_) {},
        entries: [
          JobHistoryEntry(type: 'photo', description: 'Photo captured', timestamp: now, s3ObjectKey: 'k1'),
          JobHistoryEntry(
            type: 'change_order',
            description: 'Change order: replace a corroded shutoff valve under the sink',
            timestamp: now,
            voidedAt: now,
            voidReason: 'Duplicate',
          ),
          JobHistoryEntry(type: 'gps_arrive', description: 'Arrived on site', timestamp: now),
        ],
      ),
    );
    expect(find.text('Photo captured'), findsOneWidget);
    expect(find.text('Voided'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('status tones keep distinct colors', () {
    final colors = StatusTone.values.map((t) => t.foreground).toSet();
    expect(colors, hasLength(StatusTone.values.length));
  });
}
