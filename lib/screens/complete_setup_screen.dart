import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/complete_setup_provider.dart';
import '../routing/fade_slide_page_route.dart';
import '../theme/app_theme.dart';
import '../widgets/primary_button.dart';
import 'login_screen.dart';

/// Manual-entry fallback for a technician's first-time setup link.
///
/// There's no real domain yet for deep linking the setup email/SMS straight
/// into the app, so the technician copies the token out of that link and
/// pastes it here instead.
class CompleteSetupScreen extends ConsumerStatefulWidget {
  const CompleteSetupScreen({super.key});

  @override
  ConsumerState<CompleteSetupScreen> createState() => _CompleteSetupScreenState();
}

class _CompleteSetupScreenState extends ConsumerState<CompleteSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _tokenController = TextEditingController();
  final _passwordController = TextEditingController();
  final _passwordFocusNode = FocusNode();

  bool _obscurePassword = true;

  @override
  void dispose() {
    _tokenController.dispose();
    _passwordController.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    try {
      await ref
          .read(completeSetupControllerProvider.notifier)
          .completeSetup(
            token: _tokenController.text.trim(),
            newPassword: _passwordController.text,
          );
    } catch (e, stackTrace) {
      debugPrint('SETUP ERROR: $e\n$stackTrace');
    }
  }

  void _onSuccess(BuildContext context) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Password set. You can now log in.')));
    Navigator.of(
      context,
    ).pushReplacement(FadeSlidePageRoute(builder: (_) => const LoginScreen()));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<bool>>(completeSetupControllerProvider, (previous, next) {
      next.when(
        data: (success) {
          if (!success) return;
          _onSuccess(context);
        },
        loading: () {},
        error: (error, stackTrace) {
          debugPrint('SETUP ERROR: $error\n$stackTrace');
        },
      );
    });

    final setupState = ref.watch(completeSetupControllerProvider);
    final isLoading = setupState.isLoading;
    final errorMessage = setupState.hasError
        ? (setupState.error is StateError
              ? (setupState.error as StateError).message
              : setupState.error.toString())
        : null;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppColors.screenGradient),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isTablet = constraints.maxWidth > 600;
              final horizontalPadding = isTablet ? constraints.maxWidth * 0.22 : 24.0;

              return SingleChildScrollView(
                padding: EdgeInsets.symmetric(horizontal: horizontalPadding, vertical: 32),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight - 64),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: _buildContent(context, isLoading, errorMessage),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, bool isLoading, String? errorMessage) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: RichText(
            text: TextSpan(
              style: Theme.of(context).textTheme.headlineMedium,
              children: const [
                TextSpan(text: 'Field', style: TextStyle(color: AppColors.textDark)),
                TextSpan(text: 'Loop', style: TextStyle(color: AppColors.primaryGreen)),
              ],
            ),
          ),
        ).animate().fadeIn(delay: 150.ms, duration: 400.ms),
        const SizedBox(height: 6),
        Center(
          child: Text(
            'Complete Account Setup',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(letterSpacing: 0.2, fontWeight: FontWeight.w500),
          ),
        ).animate().fadeIn(delay: 200.ms, duration: 400.ms),
        const SizedBox(height: 36),
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 24,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Enter your setup code', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  'Paste the code from your setup link and choose a password',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _tokenController,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  enabled: !isLoading,
                  onFieldSubmitted: (_) => _passwordFocusNode.requestFocus(),
                  decoration: const InputDecoration(
                    labelText: 'Setup code',
                    prefixIcon: Icon(Icons.vpn_key_outlined),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Enter your setup code';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _passwordController,
                  focusNode: _passwordFocusNode,
                  obscureText: _obscurePassword,
                  textInputAction: TextInputAction.done,
                  enabled: !isLoading,
                  onFieldSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: 'New password',
                    prefixIcon: const Icon(Icons.lock_outline_rounded),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) return 'Enter a new password';
                    if (value.length < 8) return 'Password must be at least 8 characters';
                    return null;
                  },
                ),
                const SizedBox(height: 20),
                if (errorMessage != null)
                  Container(
                        margin: const EdgeInsets.only(bottom: 16),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFDECEC),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFF8C9C9)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.error_outline_rounded,
                              color: AppColors.error,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                errorMessage,
                                style: const TextStyle(
                                  color: AppColors.error,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                      .animate()
                      .fadeIn(duration: 200.ms)
                      .slideY(begin: -0.15, end: 0, duration: 200.ms),
                PrimaryButton(label: 'Confirm', isLoading: isLoading, onPressed: _submit),
              ],
            ),
          ),
        ).animate().fadeIn(delay: 250.ms, duration: 400.ms).slideY(
          begin: 0.08,
          end: 0,
          duration: 400.ms,
          curve: Curves.easeOut,
        ),
        const SizedBox(height: 16),
        Center(
          child: TextButton(
            onPressed: isLoading
                ? null
                : () => Navigator.of(context).pop(),
            child: const Text('Back to log in'),
          ),
        ),
      ],
    );
  }
}
