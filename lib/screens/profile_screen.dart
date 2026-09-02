import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_provider.dart';
import '../providers/global_notification_service.dart';
import '../providers/global_voice_service_provider.dart';
import '../providers/visit_tracking_service.dart';
import '../routing/fade_slide_page_route.dart';
import '../theme/app_theme.dart';
import '../widgets/tap_scale.dart';
import 'login_screen.dart';
import 'permissions_setup_screen.dart';
import 'voice_settings_screen.dart';

/// Bottom-nav "Profile" tab.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text('Are you sure you want to log out?'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Log Out'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    if (!context.mounted) return;

    // Deferred to a post-frame callback rather than called synchronously
    // here: AuthController.logout() writes authControllerProvider's state
    // synchronously (before its signOut() network call even completes),
    // and this screen watches that provider — so calling it in the same
    // frame the confirmation AlertDialog's Navigator.pop() is still being
    // processed in rebuilds ProfileScreen out from under the dialog's own
    // removal, the same class of race that produced a `'_dependents.isEmpty'`
    // crash in the change-orders void-confirmation dialog
    // (`change_orders_screen.dart`'s `_showVoidDialog`). Same fix: let the
    // pop's own frame finish rendering first.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      ref.read(authControllerProvider.notifier).logout();
      ref.read(globalVoiceServiceProvider.notifier).stopForLogout();
      ref.read(globalNotificationServiceProvider).stopForLogout();
      ref.read(visitTrackingServiceProvider).stopForLogout();

      Navigator.of(
        context,
      ).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const LoginScreen()), (route) => false);
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final technician = ref.watch(authControllerProvider).value;
    if (technician == null) return const Scaffold(body: SizedBox.shrink());

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isTablet = constraints.maxWidth > 600;
            final horizontalPadding = isTablet ? constraints.maxWidth * 0.15 : 20.0;

            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(horizontalPadding, 24, horizontalPadding, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Column(
                      children: [
                        Container(
                          width: 88,
                          height: 88,
                          decoration: BoxDecoration(
                            gradient: AppColors.headerGradient,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.primaryGreen.withValues(alpha: 0.3),
                                blurRadius: 20,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            technician.initials,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 30,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          technician.fullName,
                          style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontSize: 22),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          technician.role,
                          style: const TextStyle(
                            color: AppColors.primaryGreenDark,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(technician.phone, style: Theme.of(context).textTheme.bodyMedium),
                      ],
                    ),
                  ).animate().fadeIn(duration: 350.ms).slideY(begin: -0.06, end: 0),
                  const SizedBox(height: 28),
                  _InfoCard(
                    children: [
                      _InfoRow(icon: Icons.mail_outline_rounded, label: 'Email', value: technician.email),
                      _InfoRow(icon: Icons.phone_outlined, label: 'Phone', value: technician.phone),
                      _InfoRow(icon: Icons.badge_outlined, label: 'Role', value: technician.role),
                    ],
                  ).animate().fadeIn(delay: 120.ms, duration: 350.ms),
                  const SizedBox(height: 16),
                  _InfoCard(
                    title: 'Certifications',
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: technician.certifications
                            .map(
                              (cert) => Chip(
                                label: Text(cert),
                                backgroundColor: AppColors.primaryGreen.withValues(alpha: 0.1),
                                labelStyle: const TextStyle(
                                  color: AppColors.primaryGreenDark,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12.5,
                                ),
                                side: BorderSide.none,
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                              ),
                            )
                            .toList(),
                      ),
                    ],
                  ).animate().fadeIn(delay: 180.ms, duration: 350.ms),
                  const SizedBox(height: 16),
                  _InfoCard(
                    title: 'Settings',
                    children: [
                      TapScale(
                        onTap: () => Navigator.of(context).push(
                          FadeSlidePageRoute(
                            builder: (_) => const PermissionsSetupScreen(isInitialSetup: false),
                          ),
                        ),
                        child: const _SettingsRow(
                          icon: Icons.shield_outlined,
                          label: 'Permissions',
                          subtitle: 'Camera, microphone & location',
                        ),
                      ),
                      TapScale(
                        onTap: () => Navigator.of(
                          context,
                        ).push(FadeSlidePageRoute(builder: (_) => const VoiceSettingsScreen())),
                        child: const _SettingsRow(
                          icon: Icons.record_voice_over_outlined,
                          label: 'Voice',
                          subtitle: 'Choose the spoken prompt voice',
                          ),
                        ),
                    ],
                  ).animate().fadeIn(delay: 210.ms, duration: 350.ms),
                  const SizedBox(height: 32),
                  OutlinedButton.icon(
                    onPressed: () => _confirmLogout(context, ref),
                    icon: const Icon(Icons.logout_rounded, color: AppColors.error),
                    label: const Text('Log Out'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.error,
                      side: const BorderSide(color: AppColors.error),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                  ).animate().fadeIn(delay: 240.ms, duration: 350.ms),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.children, this.title});

  final List<Widget> children;
  final String? title;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 16, offset: const Offset(0, 6)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(
              title!,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.neutralGrey,
                letterSpacing: 0.3,
              ),
            ),
            const SizedBox(height: 12),
          ],
          ...children,
        ],
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({required this.icon, required this.label, required this.subtitle});

  final IconData icon;
  final String label;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.primaryGreen.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: AppColors.primaryGreen),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textDark)),
                Text(subtitle, style: const TextStyle(fontSize: 12, color: AppColors.neutralGreyLight)),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, color: AppColors.neutralGreyLight),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.primaryGreen.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: AppColors.primaryGreen),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 12, color: AppColors.neutralGreyLight)),
                Text(
                  value,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.textDark),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
