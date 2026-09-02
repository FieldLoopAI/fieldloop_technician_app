import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../routing/app_navigator_key.dart';
import '../routing/fade_slide_page_route.dart';
import '../screens/job_detail_screen.dart';

const _channelId = 'fieldloop_updates';
const _channelName = 'FieldLoop Updates';
const _channelDescription = 'New job assignments and estimate/change order approvals';

/// Thin wrapper around the ONE `FlutterLocalNotificationsPlugin` instance
/// for the app — a plain singleton (not a Riverpod provider) since nothing
/// ever watches its state reactively, the same reason `Supabase.instance`
/// is used directly rather than wrapped in a provider.
///
/// [initialize] is safe to call from `main()` before login (it only wires up
/// the Android notification channel and the tap callback — it does NOT
/// request the POST_NOTIFICATIONS/iOS alert permission itself; that's asked
/// via `permission_handler` in the Permissions Setup flow, same as
/// camera/mic/location, so there's only ever one system permission prompt).
/// [GlobalNotificationService] is what actually decides WHEN to call [show]
/// — this class only knows how to display one and route a tap back to the
/// right job.
class LocalNotificationsService {
  LocalNotificationsService._();

  static final LocalNotificationsService instance = LocalNotificationsService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  int _nextId = 0;

  /// Called once from `main()`, before login — see that file's comment.
  /// Deliberately swallows any error rather than letting it propagate out
  /// of `main()`: a platform where this fails to set up (e.g. web without a
  /// registered service worker, which this project doesn't ship one for)
  /// should just mean no system notifications, never a blocked app launch.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    try {
      debugPrint('NOTIFICATIONS: initializing local notifications plugin...');
      const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosSettings = DarwinInitializationSettings(
        // permission_handler's Permission.notification.request() (Permissions
        // Setup screen) is the one place that prompts — these stay false so
        // the plugin's own initialize() never triggers a second iOS prompt.
        requestAlertPermission: false,
        requestSoundPermission: false,
        requestBadgePermission: false,
      );
      await _plugin.initialize(
        settings: const InitializationSettings(android: androidSettings, iOS: iosSettings),
        onDidReceiveNotificationResponse: _onTap,
      );

      const channel = AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDescription,
        importance: Importance.high,
      );
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);

      debugPrint('NOTIFICATIONS: local notifications plugin initialized');
    } catch (e, stackTrace) {
      debugPrint('NOTIFICATIONS ERROR (initialize): $e\n$stackTrace');
    }
  }

  void _onTap(NotificationResponse response) {
    final jobId = response.payload;
    debugPrint('NOTIFICATIONS: notification tapped (payload=$jobId)');
    if (jobId == null || jobId.isEmpty) return;
    _openJob(jobId);
  }

  void _openJob(String jobId) {
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) {
      debugPrint('NOTIFICATIONS: no root navigator available yet, cannot open job $jobId from tap');
      return;
    }
    navigator.push(FadeSlidePageRoute(builder: (_) => JobDetailScreen(jobId: jobId)));
  }

  /// Whether this app process was cold-started by tapping a notification —
  /// checked once at startup (see `SplashScreen`) so a tap from a fully
  /// terminated app state still opens the right job, not just Home.
  /// Returns null in every other case (a plain launch, or a launch that
  /// wasn't from a notification at all).
  Future<String?> consumeLaunchJobId() async {
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details == null || !details.didNotificationLaunchApp) return null;
      final jobId = details.notificationResponse?.payload;
      debugPrint('NOTIFICATIONS: app was cold-launched from a tapped notification (payload=$jobId)');
      return jobId;
    } catch (e, stackTrace) {
      debugPrint('NOTIFICATIONS ERROR (consumeLaunchJobId): $e\n$stackTrace');
      return null;
    }
  }

  Future<void> show({required String title, required String jobId}) async {
    try {
      final id = _nextId++;
      debugPrint('NOTIFICATIONS: showing notification $id for job $jobId — "$title"');
      await _plugin.show(
        id: id,
        title: title,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDescription,
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        payload: jobId,
      );
    } catch (e, stackTrace) {
      debugPrint('NOTIFICATIONS ERROR (show): $e\n$stackTrace');
    }
  }
}
