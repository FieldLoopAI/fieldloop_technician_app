import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fielloop/models/job_photo.dart';
import 'package:fielloop/models/mock_job.dart';
import 'package:fielloop/models/mock_technician.dart';
import 'package:fielloop/providers/auth_provider.dart';
import 'package:fielloop/providers/job_runtime_provider.dart';
import 'package:fielloop/providers/jobs_provider.dart';
import 'package:fielloop/providers/offline_upload_queue_provider.dart';
import 'package:fielloop/screens/history_screen.dart';
import 'package:fielloop/screens/home_screen.dart';
import 'package:fielloop/screens/photo_capture_screen.dart';
import 'package:fielloop/screens/profile_screen.dart';
import 'package:fielloop/theme/app_theme.dart';
import 'package:fielloop/widgets/app_components.dart';

/// Renders the real screens at the device sizes the app ships on — small
/// and large phones, 7-8" tablets, iPads — in portrait and landscape, with
/// notch/home-indicator insets, at default and large accessibility text.
/// Any RenderFlex overflow fails the test.

class _Device {
  const _Device(this.name, this.width, this.height);
  final String name;
  final double width;
  final double height;

  bool get landscape => width > height;
  Size get size => Size(width, height);

  /// iPhone-style insets: notch/Dynamic Island + home indicator in
  /// portrait, notch on the sides in landscape.
  FakeViewPadding get insets => landscape
      ? const FakeViewPadding(left: 59, right: 59, bottom: 21)
      : const FakeViewPadding(top: 59, bottom: 34);
}

const _portrait = [
  _Device('small phone', 360, 740),
  _Device('large phone', 430, 932),
  _Device('7in tablet', 600, 960),
  _Device('iPad 11in', 834, 1194),
  _Device('iPad 13in', 1024, 1366),
];

final _devices = [
  for (final d in _portrait) ...[d, _Device('${d.name} landscape', d.height, d.width)],
];

const _textScales = [1.0, 1.3, 2.0];

final _technician = MockTechnician.fromMap({
  'id': 'tech-1',
  'full_name': 'Maximiliano Alexander Montgomery-Richardson',
  'role': 'Senior Lead Field Service Technician',
  'phone': '+1 (555) 010-9999',
  'email': 'maximiliano.montgomery-richardson@example-field-services.com',
  'certifications': ['EPA Section 608 Universal Certification', 'OSHA 30', 'NATE'],
});

MockJob _job(int i, String status, {int daysAgo = 0}) => MockJob.fromMap({
  'id': 'job-$i',
  'status': status,
  'scheduled_start': DateTime.now().subtract(Duration(days: daysAgo)).toUtc().toIso8601String(),
  'job_id_public': 'FL-2026-09-000$i-RESIDENTIAL',
  'service_address': '${1200 + i} Very Long Street Name Boulevard, Apartment 5B, Springfield, IL 62704',
  'trade_category': i.isEven ? 'Plumbing' : 'HVAC',
  'description': i == 1 ? '' : 'Replace the corroded shutoff valve under the kitchen sink and test every joint for leaks',
  'customers': {'household_name': 'The Montgomery-Richardson Household $i'},
});

final _todays = [for (var i = 1; i <= 3; i++) _job(i, i == 2 ? 'on_site' : 'scheduled')];
final _history = [for (var i = 4; i <= 8; i++) _job(i, 'complete', daysAgo: i ~/ 2)];

class _FakeAuth extends AuthController {
  @override
  FutureOr<MockTechnician?> build() => _technician;
}

Future<void> _pump(WidgetTester tester, _Device device, double textScale, Widget screen, {bool settle = true}) async {
  tester.view.physicalSize = device.size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = device.insets;
  tester.view.viewPadding = device.insets;
  addTearDown(tester.view.reset);

  final byId = {for (final j in [..._todays, ..._history]) j.id: j};
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(_FakeAuth.new),
        todaysJobsQueryProvider.overrideWith((ref) async => _todays),
        historyJobsQueryProvider.overrideWith((ref) async => _history),
        jobRuntimeProvider.overrideWith((ref, id) => JobRuntimeController(id, byId[id])),
        pendingUploadCountForJobProvider.overrideWith((ref, id) => 3),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: screen,
      ),
    ),
  );
  // An uploading thumbnail's spinner never settles; a fixed pump lets the
  // entrance animations finish instead.
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(seconds: 1));
  }
}

void main() {
  for (final device in _devices) {
    for (final scale in _textScales) {
      final label = '${device.name} ${device.width.toInt()}x${device.height.toInt()} @${scale}x';

      testWidgets('Home fits — $label', (tester) async {
        await _pump(tester, device, scale, const HomeScreen());
        expect(tester.takeException(), isNull);

        // On a landscape phone at large text the header fills the first
        // screen; the cards are below it.
        await tester.scrollUntilVisible(
          find.text('The Montgomery-Richardson Household 2'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(tester.takeException(), isNull);

        // Two cards side by side only once there's room; one column below.
        final first = tester.getTopLeft(find.text('The Montgomery-Richardson Household 1'));
        final second = tester.getTopLeft(find.text('The Montgomery-Richardson Household 2'));
        if (device.width >= 840) {
          expect(first.dy, second.dy, reason: 'expanded width shows two columns');
        } else {
          expect(second.dy, greaterThan(first.dy), reason: 'compact/medium width shows one column');
        }
        // Content is capped, never stretched edge to edge on a tablet.
        final card = tester.getSize(find.byType(AppCard).first);
        expect(card.width, lessThanOrEqualTo(720));
      });

      testWidgets('History fits — $label', (tester) async {
        await _pump(tester, device, scale, const HistoryScreen());
        expect(tester.takeException(), isNull);
        expect(find.text('Job History'), findsOneWidget);
      });

      testWidgets('Profile fits — $label', (tester) async {
        await _pump(tester, device, scale, const ProfileScreen());
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(SettingsGroup).first).width, lessThanOrEqualTo(720));
      });

      testWidgets('Camera fills the screen — $label', (tester) async {
        var captures = 0;
        var finishes = 0;
        const previewKey = Key('preview');
        final photos = [
          for (var i = 0; i < 12; i++)
            JobPhoto(
              id: 'p$i',
              status: JobPhotoStatus.values[i % JobPhotoStatus.values.length],
              timestamp: DateTime(2026, 9, 25, 9, i),
            ),
        ];
        await _pump(
          tester,
          device,
          scale,
          Scaffold(
            backgroundColor: Colors.black,
            body: CaptureLayout(
              title: 'Add Photos',
              subtitle: 'FL-2026-09-0001-RESIDENTIAL-EXTRA-LONG-ID',
              preview: const ColoredBox(key: previewKey, color: Colors.blueGrey),
              permissionGate: null,
              flash: false,
              busy: false,
              cameraReady: true,
              showVoiceIndicator: false,
              error: 'Could not start the camera: CameraException(cameraPermission, a long platform message)',
              onDismissError: () {},
              jobId: 'job-1',
              photos: photos,
              photosLoading: false,
              onCapture: () => captures++,
              onFinish: () => finishes++,
              onClose: () {},
            ),
          ),
          settle: false,
        );
        expect(tester.takeException(), isNull);

        // Edge to edge: the preview is the full screen, under the insets.
        expect(tester.getSize(find.byKey(previewKey)), device.size);

        // Controls stay inside the safe area and still work.
        final shutter = tester.getRect(find.byIcon(Icons.camera_alt_rounded));
        final safe = Rect.fromLTRB(
          device.insets.left,
          device.insets.top,
          device.width - device.insets.right,
          device.height - device.insets.bottom,
        );
        expect(safe.contains(shutter.center), isTrue, reason: 'shutter $shutter outside safe area $safe');
        await tester.tap(find.byIcon(Icons.camera_alt_rounded));
        await tester.tap(find.textContaining('No More'));
        expect(captures, 1);
        expect(finishes, 1);
        expect(find.text('Captured photos (12)'), findsOneWidget);
      });
    }
  }

  testWidgets('Camera with nothing captured shows a hint, not a panel', (tester) async {
    await _pump(
      tester,
      _portrait.first,
      1.0,
      Scaffold(
        body: CaptureLayout(
          title: 'Add Photos',
          subtitle: 'FL-1',
          preview: const ColoredBox(color: Colors.blueGrey),
          permissionGate: null,
          flash: false,
          busy: false,
          cameraReady: false,
          showVoiceIndicator: false,
          error: null,
          onDismissError: () {},
          jobId: 'job-1',
          photos: const [],
          photosLoading: false,
          onCapture: () => fail('shutter must be disabled until the camera is ready'),
          onFinish: () {},
          onClose: () {},
        ),
      ),
    );
    expect(find.text('No photos yet — tap the shutter to capture one'), findsOneWidget);
    expect(find.textContaining('Captured photos'), findsNothing);
    await tester.tap(find.byIcon(Icons.camera_alt_rounded));
    expect(tester.takeException(), isNull);
  });

  for (final device in [_portrait.first, _Device('small phone landscape', 740, 360)]) {
    testWidgets('Camera permission gate fits — ${device.name} @2.0x', (tester) async {
      await _pump(
        tester,
        device,
        2.0,
        Scaffold(
          body: CaptureLayout(
            title: 'Add Photos',
            subtitle: 'FL-1',
            preview: null,
            permissionGate: const Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('FieldLoop needs camera access to take job site photos.'),
              ),
            ),
            flash: false,
            busy: false,
            cameraReady: false,
            showVoiceIndicator: false,
            error: null,
            onDismissError: () {},
            jobId: 'job-1',
            photos: const [],
            photosLoading: false,
            onCapture: () {},
            onFinish: () {},
            onClose: () {},
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      // No shutter without camera permission, but the way out stays.
      expect(find.byIcon(Icons.camera_alt_rounded), findsNothing);
      expect(find.textContaining('No More'), findsOneWidget);
    });
  }

  testWidgets('LabelValueRow never overflows with a big total at 2x text', (tester) async {
    await _pump(
      tester,
      _portrait.first,
      2.0,
      const Scaffold(
        body: Padding(
          padding: EdgeInsets.all(36),
          child: LabelValueRow(
            label: Text('Approved additional work', style: TextStyle(fontSize: 17)),
            value: Text(r'$123,456.78', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900)),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
