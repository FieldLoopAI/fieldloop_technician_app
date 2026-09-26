import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../build_info.dart';
import '../providers/auth_provider.dart';
import '../providers/global_notification_service.dart';
import '../providers/global_voice_service_provider.dart';
import '../providers/visit_tracking_service.dart';
import '../routing/fade_slide_page_route.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../theme/design_tokens.dart';
import '../widgets/app_components.dart';
import 'gemini_live_test_screen.dart';
import 'login_screen.dart';
import 'permissions_setup_screen.dart';

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
            final horizontalPadding = responsiveGutter(constraints.maxWidth);

            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(horizontalPadding, AppSpacing.lg, horizontalPadding, AppSpacing.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ProfileHeader(
                    initials: technician.initials,
                    name: technician.fullName,
                    role: technician.role,
                    phone: technician.phone,
                  ).animate().fadeIn(duration: 250.ms).slideY(begin: -0.04, end: 0, duration: 250.ms),
                  const SizedBox(height: AppSpacing.lg),
                  const SectionHeader('Contact'),
                  SettingsGroup(
                    children: [
                      _InfoTile(icon: Icons.mail_outline_rounded, label: 'Email', value: technician.email),
                      _InfoTile(icon: Icons.phone_outlined, label: 'Phone', value: technician.phone),
                      _InfoTile(icon: Icons.badge_outlined, label: 'Role', value: technician.role),
                    ],
                  ).animate().fadeIn(delay: 60.ms, duration: 250.ms),
                  const SizedBox(height: AppSpacing.lg),
                  const SectionHeader('Certifications'),
                  AppCard(
                    child: technician.certifications.isEmpty
                        ? Text('No certifications on file', style: AppText.bodyMuted)
                        : Wrap(
                            spacing: AppSpacing.xs,
                            runSpacing: AppSpacing.xs,
                            children: [
                              for (final cert in technician.certifications) _CertificationChip(label: cert),
                            ],
                          ),
                  ).animate().fadeIn(delay: 100.ms, duration: 250.ms),
                  const SizedBox(height: AppSpacing.lg),
                  const SectionHeader('Settings'),
                  SettingsGroup(
                    children: [
                      SettingsTile(
                        icon: Icons.shield_outlined,
                        title: 'Permissions',
                        subtitle: 'Camera, microphone & location',
                        onTap: () => Navigator.of(context).push(
                          FadeSlidePageRoute(builder: (_) => const PermissionsSetupScreen(isInitialSetup: false)),
                        ),
                      ),
                    ],
                  ).animate().fadeIn(delay: 140.ms, duration: 250.ms),
                  // Developer-only tooling: compiled out of release builds so
                  // real technicians never see it. (kDebugMode is a
                  // compile-time constant — the tile and its route are
                  // tree-shaken from release builds.)
                  if (kDebugMode) ...[
                    const SizedBox(height: AppSpacing.lg),
                    const SectionHeader('Developer'),
                    SettingsGroup(
                      children: [
                        SettingsTile(
                          icon: Icons.bug_report_outlined,
                          title: 'Gemini Live Test',
                          subtitle: 'Debug builds only',
                          onTap: () => Navigator.of(
                            context,
                          ).push(FadeSlidePageRoute(builder: (_) => const GeminiLiveTestScreen())),
                        ),
                      ],
                    ).animate().fadeIn(delay: 160.ms, duration: 250.ms),
                  ],
                  const SizedBox(height: AppSpacing.xl),
                  const SectionHeader('Account'),
                  SettingsGroup(
                    children: [
                      SettingsTile(
                        icon: Icons.logout_rounded,
                        title: 'Log Out',
                        subtitle: 'Sign out of FieldLoop on this device',
                        destructive: true,
                        onTap: () => _confirmLogout(context, ref),
                      ),
                    ],
                  ).animate().fadeIn(delay: 180.ms, duration: 250.ms),
                  const SizedBox(height: AppSpacing.lg),
                  Center(child: Text('FieldLoop AI  ·  build $kBuildNumber', style: AppText.bodyMuted.copyWith(fontSize: 12))),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Avatar + name + role badge, with the phone as a muted secondary line only
/// when there actually is one (a "Not provided" line used to sit at the same
/// weight as the role).
class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.initials, required this.name, required this.role, required this.phone});

  final String initials;
  final String name;
  final String role;
  final String phone;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md + 4),
      child: Row(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: const BoxDecoration(
              gradient: AppColors.dashboardHeaderGradient,
              shape: BoxShape.circle,
              boxShadow: AppShadows.card,
            ),
            alignment: Alignment.center,
            child: Text(
              initials,
              style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: AppText.headline, maxLines: 2, overflow: TextOverflow.ellipsis),
                const SizedBox(height: AppSpacing.xs),
                if (isProvided(role))
                  StatusChip(tone: StatusTone.approved, label: role, icon: Icons.engineering_rounded)
                else
                  Text('Role not set', style: AppText.bodyMuted),
                if (isProvided(phone)) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    children: [
                      const Icon(Icons.phone_outlined, size: 14, color: AppColors.neutralGrey),
                      const SizedBox(width: AppSpacing.xxs),
                      Flexible(child: Text(phone, style: AppText.bodyMuted)),
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

/// Read-only row in the Contact group: small label over the value, with a
/// missing value shown muted/italic rather than as if it were data.
class _InfoTile extends StatelessWidget {
  const _InfoTile({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final provided = isProvided(value);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 64),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(color: AppColors.greenTint, borderRadius: BorderRadius.circular(AppRadius.md)),
              child: Icon(icon, size: 20, color: AppColors.primaryGreenDark),
            ),
            const SizedBox(width: AppSpacing.sm + 2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: AppText.bodyMuted.copyWith(fontSize: 12)),
                  const SizedBox(height: 2),
                  Text(
                    provided ? value : 'Not provided',
                    style: provided
                        ? AppText.body.copyWith(fontWeight: FontWeight.w600)
                        : AppText.bodyMuted.copyWith(fontStyle: FontStyle.italic),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CertificationChip extends StatelessWidget {
  const _CertificationChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.greenTint,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: AppColors.primaryGreen.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.verified_rounded, size: 15, color: AppColors.statusGreenText),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.statusGreenText, fontWeight: FontWeight.w700, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}
