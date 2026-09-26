import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../providers/permission_providers.dart';
import '../routing/fade_slide_page_route.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../widgets/primary_button.dart';
import 'root_shell.dart';

/// One-time (or revisitable) upfront permissions flow. On first login this
/// is shown before [RootShell] and, once finished, marks the local
/// "already shown" flag so it never appears again automatically — see
/// [hasCompletedPermissionsSetup] / [markPermissionsSetupComplete]. A
/// technician can also reopen it later from Profile (with
/// [isInitialSetup] false) to grant something they declined initially;
/// that path just pops back to Profile instead of touching the flag or
/// navigating to Home.
///
/// Denying any permission here never blocks progress — every screen keeps
/// its existing manual/fallback behavior (Job Detail, Voice Assistant,
/// Photo Capture are unchanged), this only moves *when* the OS prompts
/// first appear.
class PermissionsSetupScreen extends ConsumerStatefulWidget {
  const PermissionsSetupScreen({super.key, this.isInitialSetup = true});

  final bool isInitialSetup;

  @override
  ConsumerState<PermissionsSetupScreen> createState() => _PermissionsSetupScreenState();
}

class _PermissionsSetupScreenState extends ConsumerState<PermissionsSetupScreen> {
  bool _requestingPrimary = false;
  bool _primaryRequested = false;
  bool _requestingBackground = false;
  bool _backgroundRequested = false;

  /// Camera, then Microphone, then Location ("when in use") — in that
  /// order, per the requested flow. [CameraMicController.request] issues
  /// camera and microphone as a single list request, which the
  /// permission_handler plugin works through in list order.
  Future<void> _requestPrimary() async {
    if (_requestingPrimary) return;
    setState(() => _requestingPrimary = true);
    try {
      await ref.read(cameraMicProvider.notifier).request();
      await ref.read(locationProvider.notifier).requestForeground();
      await ref.read(notificationPermissionProvider.notifier).request();
    } catch (e, stackTrace) {
      debugPrint('PERMISSIONS SETUP ERROR (initial request): $e\n$stackTrace');
    } finally {
      if (mounted) {
        setState(() {
          _requestingPrimary = false;
          _primaryRequested = true;
        });
      }
    }
  }

  /// The "Always" upgrade, asked only after foreground location is already
  /// granted. Some Android versions won't offer "Always" in this second
  /// prompt either — that's surfaced to the technician afterward rather
  /// than treated as an error.
  Future<void> _requestBackground() async {
    if (_requestingBackground) return;
    setState(() => _requestingBackground = true);
    try {
      await ref.read(locationProvider.notifier).requestBackground();
    } catch (e, stackTrace) {
      debugPrint('PERMISSIONS SETUP ERROR (background location): $e\n$stackTrace');
    } finally {
      if (mounted) {
        setState(() {
          _requestingBackground = false;
          _backgroundRequested = true;
        });
      }
    }
  }

  Future<void> _finish() async {
    if (widget.isInitialSetup) {
      await markPermissionsSetupComplete();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(FadeSlidePageRoute(builder: (_) => const RootShell()));
    } else {
      if (!mounted) return;
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cameraMic = ref.watch(cameraMicProvider);
    final location = ref.watch(locationProvider);
    final notifications = ref.watch(notificationPermissionProvider);

    final showBackgroundCard = _primaryRequested && location.foregroundGranted && !location.backgroundGranted;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Permissions Setup'),
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textDark,
        elevation: 0,
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontalPadding = responsiveGutter(constraints.maxWidth, min: 20);

            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(horizontalPadding, 20, horizontalPadding, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    "Let's get set up",
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppColors.textDark),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'FieldLoop works best with a few permissions granted up front. '
                    "You can still use the app if you say no to any of these — you'll "
                    'just use manual controls instead.',
                    style: TextStyle(fontSize: 13.5, color: AppColors.neutralGrey, height: 1.45),
                  ),
                  const SizedBox(height: 22),
                  _PermissionExplainerCard(
                    icon: Icons.camera_alt_rounded,
                    title: 'Camera',
                    message: 'Used to document job site conditions and completed work with photos.',
                    status: _primaryRequested
                        ? _statusFor(granted: cameraMic.cameraGranted, deniedNote: 'Photos disabled — enable later from Profile.')
                        : null,
                  ),
                  const SizedBox(height: 12),
                  _PermissionExplainerCard(
                    icon: Icons.mic_rounded,
                    title: 'Microphone',
                    message: 'Used for hands-free voice commands and dictating job notes.',
                    status: _primaryRequested
                        ? _statusFor(granted: cameraMic.micGranted, deniedNote: 'Voice commands disabled — use tap controls instead.')
                        : null,
                  ),
                  const SizedBox(height: 12),
                  _PermissionExplainerCard(
                    icon: Icons.location_on_rounded,
                    title: 'Location',
                    message: 'Used to automatically detect arrival at a job site, so labor time is tracked accurately.',
                    status: _primaryRequested
                        ? _statusFor(
                            granted: location.foregroundGranted,
                            deniedNote: "Automatic arrival detection disabled — use manual \"I've Arrived\" instead.",
                          )
                        : null,
                  ),
                  const SizedBox(height: 12),
                  _PermissionExplainerCard(
                    icon: Icons.notifications_active_rounded,
                    title: 'Notifications',
                    message: 'Used to alert you about new job assignments and customer approvals, even when the app is closed.',
                    status: _primaryRequested
                        ? _statusFor(
                            granted: notifications.granted,
                            deniedNote: "You won't be notified about new jobs or approvals — check the app to see updates instead.",
                          )
                        : null,
                  ),
                  const SizedBox(height: 22),
                  if (!_primaryRequested)
                    PrimaryButton(
                      label: 'Allow Permissions',
                      icon: Icons.check_circle_outline_rounded,
                      isLoading: _requestingPrimary,
                      onPressed: _requestingPrimary ? null : _requestPrimary,
                    ),
                  if (showBackgroundCard) ...[
                    _BackgroundLocationCard(
                      requesting: _requestingBackground,
                      requested: _backgroundRequested,
                      alwaysGranted: location.backgroundGranted,
                      permanentlyDenied: location.always.isPermanentlyDenied,
                      onRequest: _requestBackground,
                    ).animate().fadeIn(duration: 300.ms).slideY(begin: 0.05, end: 0),
                    const SizedBox(height: 18),
                  ],
                  if (_primaryRequested) ...[
                    if (!showBackgroundCard) const SizedBox(height: 4),
                    PrimaryButton(
                      label: widget.isInitialSetup ? 'Continue to Home' : 'Done',
                      icon: Icons.arrow_forward_rounded,
                      onPressed: _finish,
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  _PermissionCardStatus _statusFor({required bool granted, required String deniedNote}) {
    return granted
        ? const _PermissionCardStatus(
            icon: Icons.check_circle_rounded,
            color: AppColors.primaryGreenDark,
            text: 'Granted',
          )
        : _PermissionCardStatus(icon: Icons.info_outline_rounded, color: AppColors.amber, text: deniedNote);
  }
}

class _PermissionCardStatus {
  const _PermissionCardStatus({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;
}

class _PermissionExplainerCard extends StatelessWidget {
  const _PermissionExplainerCard({
    required this.icon,
    required this.title,
    required this.message,
    this.status,
  });

  final IconData icon;
  final String title;
  final String message;
  final _PermissionCardStatus? status;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 14, offset: const Offset(0, 6)),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.primaryGreen.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: AppColors.primaryGreen, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textDark)),
                const SizedBox(height: 4),
                Text(message, style: const TextStyle(fontSize: 13, color: AppColors.neutralGrey, height: 1.4)),
                if (status != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(status!.icon, size: 15, color: status!.color),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          status!.text,
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: status!.color),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BackgroundLocationCard extends StatelessWidget {
  const _BackgroundLocationCard({
    required this.requesting,
    required this.requested,
    required this.alwaysGranted,
    required this.permanentlyDenied,
    required this.onRequest,
  });

  final bool requesting;
  final bool requested;
  final bool alwaysGranted;
  final bool permanentlyDenied;
  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.primaryGreen.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.primaryGreen.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.my_location_rounded, color: AppColors.primaryGreenDark, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'One more step for background arrival detection',
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: AppColors.textDark),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            alwaysGranted
                ? 'Background location is enabled — arrival detection will keep working even when FieldLoop isn\'t open.'
                : 'Automatic arrival detection needs to keep working even when the app '
                      "isn't open. Your device may only offer \"Allow all the time\" from "
                      "Settings rather than in this prompt.",
            style: const TextStyle(fontSize: 13, color: AppColors.neutralGrey, height: 1.4),
          ),
          if (alwaysGranted) ...[
            const SizedBox(height: 10),
            const Row(
              children: [
                Icon(Icons.check_circle_rounded, size: 15, color: AppColors.primaryGreenDark),
                SizedBox(width: 6),
                Text('Granted', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.primaryGreenDark)),
              ],
            ),
          ] else ...[
            const SizedBox(height: 14),
            if (!requested)
              PrimaryButton(
                label: 'Enable Background Location',
                icon: Icons.location_on_rounded,
                isLoading: requesting,
                onPressed: requesting ? null : onRequest,
              )
            else ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.amber.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.amber.withValues(alpha: 0.3)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline_rounded, color: AppColors.amber, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "Automatic arrival detection will use the manual \"I've Arrived\" "
                        'fallback until background location is enabled'
                        '${permanentlyDenied ? ' in Settings' : ''}.',
                        style: const TextStyle(fontSize: 12.5, color: AppColors.textDark, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: openAppSettings,
                icon: const Icon(Icons.settings_outlined, size: 18),
                label: const Text('Open Settings'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primaryGreenDark,
                  side: const BorderSide(color: AppColors.primaryGreen),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
