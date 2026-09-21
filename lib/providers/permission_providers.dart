import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Camera + microphone are requested together the first time the technician
/// reaches either the Voice Assistant or Photo Capture screen (whichever
/// comes first) — see [cameraMicProvider].
class CameraMicState {
  const CameraMicState({
    this.camera = PermissionStatus.denied,
    this.microphone = PermissionStatus.denied,
    this.checked = false,
  });

  final PermissionStatus camera;
  final PermissionStatus microphone;

  /// False until the first live status check completes, so screens can
  /// avoid flashing a gate card before we actually know the real status.
  final bool checked;

  bool get cameraGranted => camera.isGranted;
  bool get micGranted => microphone.isGranted;
  bool get allGranted => cameraGranted && micGranted;

  CameraMicState copyWith({PermissionStatus? camera, PermissionStatus? microphone, bool? checked}) {
    return CameraMicState(
      camera: camera ?? this.camera,
      microphone: microphone ?? this.microphone,
      checked: checked ?? this.checked,
    );
  }
}

class CameraMicController extends StateNotifier<CameraMicState> {
  CameraMicController() : super(const CameraMicState()) {
    refresh();
  }

  Future<void> refresh() async {
    final camera = await Permission.camera.status;
    final microphone = await Permission.microphone.status;
    // The permission check is async — by the time it resolves, whatever
    // widget triggered this (or the app itself) may have gone away. Setting
    // state after that notifies listeners tied to an already-disposed
    // Element and crashes.
    if (!mounted) return;
    state = state.copyWith(camera: camera, microphone: microphone, checked: true);
  }

  /// Requests whichever of camera/microphone isn't granted yet. Safe to call
  /// repeatedly from a retry action.
  Future<void> request() async {
    final toRequest = <Permission>[
      if (!state.cameraGranted) Permission.camera,
      if (!state.micGranted) Permission.microphone,
    ];
    if (toRequest.isEmpty) return;
    final results = await toRequest.request();
    if (!mounted) return;
    state = state.copyWith(
      camera: results[Permission.camera] ?? state.camera,
      microphone: results[Permission.microphone] ?? state.microphone,
    );
  }
}

final cameraMicProvider = StateNotifierProvider<CameraMicController, CameraMicState>(
  (ref) => CameraMicController(),
);

/// True once the camera+mic "soft ask" has been actioned once, anywhere in
/// the app (Voice Assistant or Photo Capture, whichever is reached first) —
/// regardless of outcome. After that, screens fall back to their ongoing,
/// non-blocking presentation instead of showing the ask again.
final cameraMicAskShownProvider = StateProvider<bool>((ref) => false);

/// Copy for the camera+microphone ask/retry card, computed from whichever
/// of the two is still missing so the wording never mentions a permission
/// that's already granted (e.g. if Photo Capture already resolved camera,
/// Voice Assistant's card only talks about the microphone).
class CameraMicAskCopy {
  const CameraMicAskCopy({required this.icons, required this.title, required this.message});

  final List<IconData> icons;
  final String title;
  final String message;
}

CameraMicAskCopy cameraMicAskCopy(CameraMicState state) {
  final needsCamera = !state.cameraGranted;
  final needsMic = !state.micGranted;

  if (needsCamera && needsMic) {
    return const CameraMicAskCopy(
      icons: [Icons.mic_rounded, Icons.camera_alt_rounded],
      title: 'Camera & Microphone Access',
      message:
          'FieldLoop uses your microphone for hands-free voice commands and your '
          'camera to document job site photos — both are core to how technicians '
          'use the app on-site.',
    );
  }
  if (needsMic) {
    return const CameraMicAskCopy(
      icons: [Icons.mic_rounded],
      title: 'Microphone Access',
      message:
          'FieldLoop uses your microphone so you can control the app hands-free '
          'with voice commands while you work.',
    );
  }
  return const CameraMicAskCopy(
    icons: [Icons.camera_alt_rounded],
    title: 'Camera Access',
    message: 'FieldLoop uses your camera to document job site conditions and completed work.',
  );
}

/// Location is requested separately, the first time any job is opened in
/// the Job Detail screen — see [locationProvider].
class LocationState {
  const LocationState({
    this.whenInUse = PermissionStatus.denied,
    this.always = PermissionStatus.denied,
    this.checked = false,
  });

  final PermissionStatus whenInUse;
  final PermissionStatus always;
  final bool checked;

  bool get foregroundGranted => whenInUse.isGranted || always.isGranted;
  bool get backgroundGranted => always.isGranted;

  LocationState copyWith({PermissionStatus? whenInUse, PermissionStatus? always, bool? checked}) {
    return LocationState(
      whenInUse: whenInUse ?? this.whenInUse,
      always: always ?? this.always,
      checked: checked ?? this.checked,
    );
  }
}

class LocationController extends StateNotifier<LocationState> {
  LocationController() : super(const LocationState()) {
    refresh();
  }

  Future<void> refresh() async {
    final whenInUse = await Permission.locationWhenInUse.status;
    final always = await Permission.locationAlways.status;
    if (!mounted) return;
    state = state.copyWith(whenInUse: whenInUse, always: always, checked: true);
  }

  /// Foreground location — required for geofenced arrival detection to work
  /// at all while the app is open.
  Future<void> requestForeground() async {
    final result = await Permission.locationWhenInUse.request();
    if (!mounted) return;
    state = state.copyWith(whenInUse: result);
    // A foreground grant can sometimes also resolve background status
    // (platform/permission-combination dependent), so re-sync both.
    await refresh();
  }

  /// The optional "Always" upgrade — required for geofencing to keep working
  /// when the app isn't in the foreground. Android requires foreground
  /// location to already be granted before this can succeed, and both
  /// platforms expect this to be asked as a separate, later step rather than
  /// bundled with the foreground request.
  Future<void> requestBackground() async {
    final result = await Permission.locationAlways.request();
    if (!mounted) return;
    state = state.copyWith(always: result);
    await refresh();
  }
}

final locationProvider = StateNotifierProvider<LocationController, LocationState>(
  (ref) => LocationController(),
);

/// True once the location "soft ask" has been actioned once, the first time
/// any job is opened in Job Detail — regardless of outcome. After that, the
/// arrival card falls back to its ongoing, non-blocking presentation
/// instead of showing the ask again on every job opened.
final locationAskShownProvider = StateProvider<bool>((ref) => false);

/// True once the technician has dismissed the "enable background location"
/// nudge on the Job Detail screen for this app session — avoids re-nagging
/// on every job opened after they've said "not now" once.
final locationAlwaysNudgeDismissedProvider = StateProvider<bool>((ref) => false);

/// System notification permission (POST_NOTIFICATIONS on Android 13+; the
/// alert/sound/badge prompt on iOS) — requested alongside camera/mic/
/// location in the Permissions Setup flow, via the same `permission_handler`
/// package as those, so there's one consistent place technicians see every
/// system prompt rather than a separate ask the first time a notification
/// would fire. See `local_notifications_service.dart`/
/// `global_notification_service.dart` for what actually uses this once
/// granted.
class NotificationPermissionState {
  const NotificationPermissionState({this.status = PermissionStatus.denied, this.checked = false});

  final PermissionStatus status;
  final bool checked;

  bool get granted => status.isGranted;

  NotificationPermissionState copyWith({PermissionStatus? status, bool? checked}) {
    return NotificationPermissionState(status: status ?? this.status, checked: checked ?? this.checked);
  }
}

class NotificationPermissionController extends StateNotifier<NotificationPermissionState> {
  NotificationPermissionController() : super(const NotificationPermissionState()) {
    refresh();
  }

  Future<void> refresh() async {
    final status = await Permission.notification.status;
    if (!mounted) return;
    state = state.copyWith(status: status, checked: true);
  }

  Future<void> request() async {
    final result = await Permission.notification.request();
    if (!mounted) return;
    state = state.copyWith(status: result);
  }
}

final notificationPermissionProvider =
    StateNotifierProvider<NotificationPermissionController, NotificationPermissionState>(
      (ref) => NotificationPermissionController(),
    );

/// Bluetooth (SCO audio routing) permission — deliberately NOT part of the
/// upfront Permissions Setup flow above, since most technicians don't carry
/// a Bluetooth headset and asking everyone for it up front would just be
/// noise. Instead [GlobalVoiceService._maybeRouteBluetoothSco] requests
/// this lazily, the first time voice listening starts while a Bluetooth
/// audio device is actually detected connected — this class just gives
/// that a status/request pattern consistent with the others above.
class BluetoothPermissionState {
  const BluetoothPermissionState({this.status = PermissionStatus.denied, this.checked = false});

  final PermissionStatus status;
  final bool checked;

  bool get granted => status.isGranted;

  BluetoothPermissionState copyWith({PermissionStatus? status, bool? checked}) {
    return BluetoothPermissionState(status: status ?? this.status, checked: checked ?? this.checked);
  }
}

class BluetoothPermissionController extends StateNotifier<BluetoothPermissionState> {
  BluetoothPermissionController() : super(const BluetoothPermissionState()) {
    refresh();
  }

  Future<void> refresh() async {
    final status = await Permission.bluetoothConnect.status;
    if (!mounted) return;
    state = state.copyWith(status: status, checked: true);
  }

  Future<void> request() async {
    final result = await Permission.bluetoothConnect.request();
    if (!mounted) return;
    state = state.copyWith(status: result);
  }
}

final bluetoothPermissionProvider = StateNotifierProvider<BluetoothPermissionController, BluetoothPermissionState>(
  (ref) => BluetoothPermissionController(),
);

const _bluetoothPermissionAskedKey = 'bluetooth_permission_asked';

/// Whether [GlobalVoiceService._maybeRouteBluetoothSco] has already
/// prompted for Bluetooth permission once (regardless of outcome) — so a
/// technician who denies it isn't re-prompted on every subsequent
/// listen() restart, or every time they reopen a job. Separate from
/// [Permission.bluetoothConnect]'s own granted/denied/permanentlyDenied
/// status: this flag is about "have we asked," not "what did they say."
Future<bool> hasAskedBluetoothPermission() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_bluetoothPermissionAskedKey) ?? false;
}

Future<void> markBluetoothPermissionAsked() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_bluetoothPermissionAskedKey, true);
}

const _permissionsSetupCompleteKey = 'permissions_setup_completed';

/// Whether this device has already been through the one-time upfront
/// Permissions Setup screen shown right after a technician's first login.
/// Persisted locally so it never repeats once completed; revisiting it
/// later from Profile doesn't touch this flag.
Future<bool> hasCompletedPermissionsSetup() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_permissionsSetupCompleteKey) ?? false;
}

Future<void> markPermissionsSetupComplete() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_permissionsSetupCompleteKey, true);
}
