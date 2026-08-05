import 'package:flutter_riverpod/flutter_riverpod.dart';

enum VoicePhase { listening, processing }

class VoiceSessionState {
  const VoiceSessionState({this.phase = VoicePhase.listening, this.transcript = ''});

  final VoicePhase phase;
  final String transcript;

  VoiceSessionState copyWith({VoicePhase? phase, String? transcript}) {
    return VoiceSessionState(phase: phase ?? this.phase, transcript: transcript ?? this.transcript);
  }
}

/// Drives the voice assistant screen's listening/processing UI. Each quick
/// action (tap or, eventually, real wake-word command) runs through
/// [runCommand] so the visual state machine and the transcript stay
/// consistent regardless of which input triggered it — the tap fallback and
/// the voice path are the same code path.
final voiceSessionProvider =
    StateNotifierProvider.autoDispose<VoiceSessionController, VoiceSessionState>(
      (ref) => VoiceSessionController(),
    );

class VoiceSessionController extends StateNotifier<VoiceSessionState> {
  VoiceSessionController() : super(const VoiceSessionState());

  Future<void> runCommand(String simulatedTranscript) async {
    state = state.copyWith(phase: VoicePhase.listening, transcript: simulatedTranscript);
    await Future.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    state = state.copyWith(phase: VoicePhase.processing);
    await Future.delayed(const Duration(milliseconds: 1100));
    if (!mounted) return;
    state = state.copyWith(phase: VoicePhase.listening);
  }
}
