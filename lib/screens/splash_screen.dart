import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers/auth_provider.dart';
import '../providers/local_notifications_service.dart';
import '../providers/permission_providers.dart';
import '../providers/session_storage.dart';
import '../routing/app_navigator_key.dart';
import 'job_detail_screen.dart';
import 'login_screen.dart';
import 'permissions_setup_screen.dart';
import 'root_shell.dart';

const _splashGreen = Color(0xFF0F9D58);

const _quotes = [
  'A little progress each day adds up to big results.',
  "Small acts of kindness can brighten someone's entire day.",
  'Happiness is not something ready-made — it comes from your own actions.',
  'The best way to find yourself is to lose yourself in the service of others.',
  'The Earth does not belong to us — we belong to the Earth.',
  'We do not inherit the earth from our ancestors, we borrow it from our children.',
  'Small changes today lead to a greener tomorrow.',
  'Good work done right is good for the planet too — fewer repeats, less waste.',
  'Building smarter, working greener, one job at a time.',
  'Take care of the world around you, and it will take care of you.',
];

/// Logical-pixel size the logo renders at here — matched exactly to the
/// native splash screen (`flutter_native_splash`) so there's no visible
/// resize/jump when Flutter takes over. Confirmed from the generated
/// assets: Android's drawable-mdpi/splash.png is 256x256px (mdpi = 1x, so
/// 256dp on screen) and iOS's LaunchImage.png is 256x256pt at @1x — both
/// centered full-bleed, which is why this is centered outside of SafeArea.
const _logoSize = 256.0;

/// First screen Flutter itself renders — right after the native splash
/// (`flutter_native_splash`, configured in pubspec.yaml) hands off. Shows a
/// branded green screen with a rotating quote for at least 3s while
/// [_resolveDestination] runs the session-validity check in the background,
/// then routes to [LoginScreen] or straight past it into [RootShell] — see
/// the three branches inside [_resolveDestination].
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

enum _Destination { login, home }

class _SplashScreenState extends ConsumerState<SplashScreen> {
  late final String _quote = _quotes[Random().nextInt(_quotes.length)];
  bool _quoteVisible = false;

  @override
  void initState() {
    super.initState();
    // Deferred a frame so `context` has a Navigator to push into by the time
    // navigation is ready — mirrors the post-frame pattern used for the
    // logout redirect in ProfileScreen.
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());

    // Logo is already on screen (continuing straight from the native
    // splash); the quote fades in a beat later so it reads as a deliberate
    // reveal rather than everything appearing at once.
    Future.delayed(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() => _quoteVisible = true);
    });
  }

  Future<void> _start() async {
    // Runs the session check and a 3s minimum-display timer side by side,
    // so a fast check still shows the quote for a comfortably readable
    // amount of time, but a slow check is never held up waiting on the
    // timer.
    final results = await Future.wait([
      _resolveDestination(),
      Future.delayed(const Duration(milliseconds: 3000)),
    ]);
    if (!mounted) return;

    if (results[0] == _Destination.login) {
      _goToLogin();
    } else {
      await _goToHome();
    }
  }

  Future<_Destination> _resolveDestination() async {
    final session = Supabase.instance.client.auth.currentSession;

    if (session == null) {
      debugPrint('SESSION GATE: no saved session — showing LoginScreen');
      return _Destination.login;
    }

    final lastLoginAt = await getLastLoginAt();
    final age = lastLoginAt == null ? null : DateTime.now().difference(lastLoginAt);
    final expired = age == null || age > sessionReloginInterval;

    if (expired) {
      debugPrint(
        'SESSION GATE: session exists but last login was ${lastLoginAt == null ? 'never recorded' : 'more than 3 days ago ($age)'} '
        '— forcing re-login',
      );
      await Supabase.instance.client.auth.signOut();
      await clearLastLoginAt();
      return _Destination.login;
    }

    debugPrint('SESSION GATE: session exists and last login was $age ago — restoring, skipping LoginScreen');
    // Real async gap above (getLastLoginAt() reads shared_preferences) — this
    // widget (and its `ref`) can be gone by the time it resolves, so re-check
    // immediately before the next `ref` touch, same as everywhere else in
    // this file that follows an await with a `ref`/context use.
    if (!mounted) return _Destination.login;
    final restored = await ref.read(authControllerProvider.notifier).restoreSession();
    // Session existed but the technician row lookup failed — restoreSession()
    // already signed out in this case, so fall back to a normal login.
    return restored ? _Destination.home : _Destination.login;
  }

  Future<void> _goToHome() async {
    final alreadySetUp = await hasCompletedPermissionsSetup();
    // Checked here rather than left to LocalNotificationsService's own tap
    // callback: that callback only fires for a notification tapped while
    // the app process was already alive. A tap that cold-launches the app
    // from fully terminated needs this separate, one-time check instead —
    // see LocalNotificationsService.consumeLaunchJobId's doc comment.
    final launchJobId = await LocalNotificationsService.instance.consumeLaunchJobId();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => alreadySetUp ? const RootShell() : const PermissionsSetupScreen(),
      ),
    );
    if (launchJobId != null) {
      debugPrint('SESSION GATE: cold-launched from a tapped notification for job $launchJobId — opening it');
      rootNavigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => JobDetailScreen(jobId: launchJobId)));
    }
  }

  void _goToLogin() {
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  @override
  Widget build(BuildContext context) {
    // Bottom-safe-area inset is added by hand rather than wrapping the whole
    // Stack in SafeArea, so the quote stays clear of a home indicator/nav
    // bar without nudging the logo — which sits outside SafeArea entirely,
    // full-bleed centered, to match the native splash's own centering.
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: _splashGreen,
      body: Stack(
        children: [
          const Align(
            alignment: Alignment.center,
            child: SizedBox(
              width: _logoSize,
              height: _logoSize,
              child: Image(image: AssetImage('assets/icon/icon_foreground.png')),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.fromLTRB(40, 0, 40, 64 + bottomInset),
              child: AnimatedOpacity(
                opacity: _quoteVisible ? 1 : 0,
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeIn,
                child: Text(
                  _quote,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                    color: Colors.white.withValues(alpha: 0.8),
                    height: 1.5,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
