import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fielloop/app.dart';

void main() {
  testWidgets('Login screen renders the FieldLoop wordmark and login form', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: FieldLoopApp()));
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('Technician Portal'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Email'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Password'), findsOneWidget);
    expect(find.text('Log In'), findsOneWidget);
  });

  testWidgets('Logging in with any credentials reaches the bottom nav home tab', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: FieldLoopApp()));
    await tester.pump(const Duration(seconds: 2));

    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'jane.doe@example.com');
    await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'anything');
    await tester.tap(find.text('Log In'));

    // Mock login has a simulated delay before resolving.
    await tester.pump(const Duration(milliseconds: 950));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);
    // MOCK DATA - the mock login always signs in as the single sample
    // technician (Jordan Reyes) regardless of the email entered.
    expect(find.textContaining('Hi, Jordan'), findsOneWidget);
  });
}
