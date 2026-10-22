/// Build 185 — keeps the microphone off while the homeowner holds the
/// tablet on the Stripe Checkout page.
///
/// Uses ONLY the existing voice-scope pair: `GlobalVoiceService.exitJobScope`
/// (ends the live Gemini session, stops the wake-word recognizer, releases
/// Bluetooth SCO — and with the scope inactive, backgrounding the app ends
/// any session too, see `onAppLifecycleChanged`) and `enterJobScope` (the
/// same call Job Detail makes to start listening, which itself respects
/// mute). No new voice behavior, no spoken line.
///
/// [hold] always stops voice. [release] gives the mic back only if the job
/// was voice-eligible when held (an active-status job — exactly Job
/// Detail's own rule) AND still is: a completed, read-only job stays silent.
class CheckoutVoiceHold {
  CheckoutVoiceHold({required this.stopVoice, required this.resumeVoice, required this.log});

  final void Function() stopVoice;
  final Future<void> Function() resumeVoice;
  final void Function(String message) log;

  bool _held = false;
  bool _resumeOnRelease = false;

  bool get isHeld => _held;

  void hold({required String jobId, required bool voiceEligible}) {
    if (_held) return;
    _held = true;
    _resumeOnRelease = voiceEligible;
    log('PAYMENT VOICE HOLD: held for checkout job=$jobId voiceEligible=$voiceEligible');
    stopVoice();
  }

  Future<void> release({required String jobId, required String reason, required bool stillEligible}) async {
    if (!_held) return;
    _held = false;
    final resume = _resumeOnRelease && stillEligible;
    _resumeOnRelease = false;
    log('PAYMENT VOICE HOLD: released job=$jobId reason=$reason resumeVoice=$resume');
    if (resume) await resumeVoice();
  }
}
